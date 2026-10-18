// The adversarial review a change gets before its pull request: Codex (the OpenAI CLI, installed on
// this machine) reads the branch's diff against origin/main as a hostile reviewer, in a read-only
// sandbox, and reports findings by severity. The worker fixes every P1 and P2 it confirms, runs
// this once more, and merges only when the verdict is CLEAN. Commit first: it reads the commits.
// The second run on a branch is narrow: it reads only the commits made since the first, to say
// whether each earlier finding is resolved and whether the fixes broke anything. A branch gets
// those two runs and no third.
// When the branch has an open pull request, CodeRabbit (a GitHub app) is asked to read it too, once
// with the first run and once more with the second, to read the fixes. Its open comments and
// its verdict (approved or changes requested) are printed under the Codex findings so both are
// read together. A rate limit or silence is reported; the exit code stays the Codex verdict's.
//   node scripts/review.mjs                  this branch against origin/main
//   node scripts/review.mjs --base <ref>     another base
//   node scripts/review.mjs --full           read the whole branch again, whatever was reviewed before
// The full report goes to <git common dir>/private/reviews/ (never tracked); the verdict and the
// findings are printed. Exit 0 when CLEAN, 1 when there are P1 or P2 findings, 2 when it could not run.
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }).trim();
const top = git('rev-parse', '--show-toplevel');
const common = resolve(git('rev-parse', '--git-common-dir'));
const baseAt = process.argv.indexOf('--base');
const base = baseAt > 0 ? (process.argv[baseAt + 1] ?? 'origin/main') : 'origin/main';
const branch = git('branch', '--show-current') || 'detached';
const head = git('rev-parse', '--short', 'HEAD');

if (git('status', '--porcelain')) {
  console.error('review: commit your work first; the review reads the commits on this branch, not the working tree');
  process.exit(2);
}
const stat = git('diff', '--stat', `${base}...HEAD`);
if (!stat) {
  console.log(`review: no changes between ${base} and HEAD`);
  process.exit(0);
}
const codex = spawnSync('codex', ['--version'], { encoding: 'utf8' });
if (codex.error) {
  console.error('review: the codex command is not installed or not on PATH');
  process.exit(2);
}

// CodeRabbit. Its automatic reviews are off (.coderabbit.yaml); it reads a pull request when a
// comment asks, and approves it or requests changes. It is asked at most twice, in step with the
// two Codex runs: once for the whole pull request, and once for the fix commits. The asking
// comments are the record of how often it has been asked.
const BOT = /^coderabbitai/;
const ASK = '@coderabbitai review';
const WAIT_FOR_SIGN = 3 * 60 * 1000;
const WAIT_FOR_REVIEW = 10 * 60 * 1000;
const gh = (...args) => spawnSync('gh', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
const ghJson = (...args) => {
  const out = gh(...args);
  return out.status === 0 ? JSON.parse(out.stdout) : null;
};
// One JSON object per line, from `gh api --paginate --jq`.
const ghLines = (path, jq) => {
  const out = gh('api', '--paginate', path, '--jq', jq);
  if (out.status !== 0) return [];
  return out.stdout.split('\n').filter(Boolean).map((line) => JSON.parse(line));
};
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function rabbitActivity(pr, since) {
  const after = (at) => !since || Date.parse(at) >= since;
  const comments = ghLines(`repos/{owner}/{repo}/issues/${pr.number}/comments`, '.[] | {login: .user.login, body, at: .updated_at}');
  const reviews = ghLines(`repos/{owner}/{repo}/pulls/${pr.number}/reviews`, '.[] | {login: .user.login, at: .submitted_at, state}');
  const statuses = ghLines(`repos/{owner}/{repo}/commits/${pr.headRefOid}/statuses`, '.[] | {context, state, description, at: .updated_at}');
  const fromBot = comments.filter((c) => BOT.test(c.login) && after(c.at));
  // With automatic reviews off, every push gets a "review skipped" status; that is not a review.
  const status = statuses.find((s) => /coderabbit/i.test(s.context) && !/skipped/i.test(s.description ?? '') && after(s.at));
  const verdicts = reviews.filter((r) => BOT.test(r.login) && (r.state === 'APPROVED' || r.state === 'CHANGES_REQUESTED'));
  return {
    asks: comments.filter((c) => !BOT.test(c.login) && c.body.includes(ASK)).length,
    verdict: verdicts.at(-1)?.state,
    reviewed: reviews.some((r) => BOT.test(r.login) && after(r.at)),
    // Its notice, not any mention: its summary of a change about rate limits uses the words too.
    limited: fromBot.find((c) => /rate limit exceeded/i.test(c.body)),
    finished: status !== undefined && status.state !== 'pending',
    sign: fromBot.length > 0 || status !== undefined,
  };
}

// Before Codex starts, so the two read at the same time. Returns what rabbitReport needs.
function rabbitAsk(second) {
  const pr = ghJson('pr', 'view', '--json', 'number,url,state,headRefOid,headRefName,isCrossRepository');
  if (!pr || pr.state !== 'OPEN') {
    return { skip: 'no open pull request for this branch; push and open it before the review so CodeRabbit reads it too' };
  }
  const now = rabbitActivity(pr, 0);
  // The second ask is made even after an approval: that approval was of the commits before the fixes.
  const due = now.asks === 0 || (second && now.asks === 1);
  if (!due) return { pr, since: 0 };
  // A worker that commits its fixes and runs the review without pushing would leave CodeRabbit's
  // verdict on the commits before them, so the branch is pushed here, to the pull request's own
  // branch, and GitHub given time to see it.
  const tip = git('rev-parse', 'HEAD');
  if (pr.headRefOid !== tip) {
    if (pr.isCrossRepository) return { pr, since: 0, note: 'the pull request is behind this branch and comes from a fork, so CodeRabbit was not asked; push first' };
    const pushed = spawnSync('git', ['push', '--quiet', 'origin', `HEAD:refs/heads/${pr.headRefName}`], { encoding: 'utf8' });
    for (let tries = 0; pushed.status === 0 && pr.headRefOid !== tip && tries < 10; tries++) {
      sleep(3 * 1000);
      pr.headRefOid = ghJson('pr', 'view', '--json', 'headRefOid')?.headRefOid ?? pr.headRefOid;
    }
    if (pr.headRefOid !== tip) {
      return { pr, since: 0, note: `the pull request is behind this branch and the push did not bring it up (${pushed.stderr?.trim() || 'GitHub has not seen it'}), so CodeRabbit was not asked` };
    }
    console.log('review: pushed this branch so the pull request holds what is being reviewed');
  }
  const since = Date.now() - 60 * 1000;
  const asked = gh('pr', 'comment', String(pr.number), '--body', ASK);
  if (asked.status !== 0) return { pr, since: 0, note: `could not ask for a review: ${asked.stderr.trim()}` };
  console.log(`review: asked CodeRabbit to read ${pr.url}`);
  return { pr, since, started: Date.now() };
}

function rabbitWait({ pr, since, started }) {
  for (;;) {
    const seen = rabbitActivity(pr, since);
    if (seen.limited) return `rate limited, so it did not read this pull request: ${seen.limited.body.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200)}`;
    if (seen.reviewed || seen.finished) return '';
    const waited = Date.now() - started;
    if (!seen.sign && waited > WAIT_FOR_SIGN) return 'no answer; is the app installed on the repository?';
    if (waited > WAIT_FOR_REVIEW) return 'still reading after ten minutes; not waiting for it';
    sleep(20 * 1000);
  }
}

function rabbitReport(asked) {
  console.log('\n## CodeRabbit');
  if (asked.skip) return console.log(`review: CodeRabbit: ${asked.skip}`);
  if (asked.note) console.log(`review: CodeRabbit: ${asked.note}`);
  if (asked.started) {
    const problem = rabbitWait(asked);
    if (problem) return console.log(`review: CodeRabbit: ${problem}`);
  }
  const repo = ghJson('repo', 'view', '--json', 'owner,name');
  const query = `query($owner: String!, $name: String!, $number: Int!, $endCursor: String) { repository(owner: $owner, name: $name) {
    pullRequest(number: $number) { reviewThreads(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor }
      nodes { isResolved isOutdated path line originalLine comments(first: 1) { nodes { author { login } body } } } } } } }`;
  const threads = repo && gh('api', 'graphql', '--paginate', '-f', `query=${query}`, '-f', `owner=${repo.owner.login}`, '-f', `name=${repo.name}`,
    '-F', `number=${asked.pr.number}`, '--jq', '.data.repository.pullRequest.reviewThreads.nodes[]');
  if (!threads || threads.status !== 0) return console.log('review: CodeRabbit: could not read the pull request comments');
  // An unresolved thread whose lines have since changed stays listed: the change may not be a fix.
  const open = threads.stdout.split('\n').filter(Boolean).map((line) => JSON.parse(line))
    .filter((t) => !t.isResolved && BOT.test(t.comments.nodes[0]?.author?.login ?? ''));
  for (const thread of open) {
    const body = thread.comments.nodes[0].body
      .replace(/<details>[\s\S]*?<\/details>/g, '')
      .replace(/<!--[\s\S]*?-->/g, '')
      .replace(/\n\s*\n+/g, '\n')
      .trim()
      .slice(0, 1200);
    const where = thread.isOutdated ? `${thread.originalLine ?? '?'} (lines changed since)` : (thread.line ?? '?');
    console.log(`- ${thread.path}:${where} — ${body.replace(/\n/g, '\n  ')}`);
  }
  console.log(open.length
    ? `review: CodeRabbit: ${open.length} open comment(s); confirm each against the code as you would a Codex finding`
    : 'review: CodeRabbit: no open comments');
  const verdict = rabbitActivity(asked.pr, 0).verdict;
  console.log(`review: CodeRabbit: ${verdict === 'APPROVED' ? 'APPROVED' : verdict === 'CHANGES_REQUESTED' ? 'CHANGES REQUESTED' : 'has not read this pull request to a verdict'}`);
  if (verdict === 'CHANGES_REQUESTED' && !asked.started) console.log('review: CodeRabbit: that verdict is from before this run; it was not asked again');
}

const dir = join(common, 'private', 'reviews');
mkdirSync(dir, { recursive: true });
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const slug = branch.replace(/[^\w.-]/g, '_');
const report = join(dir, `${slug}-${head}-${stamp}.md`);
const verdict = `${report}.last.md`;

// Earlier reviews of this branch against the same base that reached a verdict, oldest first: the
// commit each one read (still on the branch) and what it found.
function earlierReviews() {
  const onBranch = new Set(git('rev-list', `${base}..HEAD`).split('\n'));
  const tip = git('rev-parse', 'HEAD');
  const name = new RegExp(`^${slug.replace(/[.]/g, '\\.')}-([0-9a-f]{7,40})-\\d{4}-\\d\\d-\\d\\dT[\\dZ-]+\\.md\\.last\\.md$`);
  const found = [];
  for (const file of readdirSync(dir).sort()) {
    const sha = name.exec(file)?.[1];
    if (!sha) continue;
    let commit;
    try {
      commit = git('rev-parse', '--verify', '--quiet', `${sha}^{commit}`);
    } catch {
      continue;
    }
    if (!onBranch.has(commit)) continue;
    let text;
    try {
      // The full report's first line names the base that run compared against.
      if (!readFileSync(join(dir, file.slice(0, -'.last.md'.length)), 'utf8').startsWith(`# Review of ${branch} (${sha}) against ${base}\n`)) continue;
      text = readFileSync(join(dir, file), 'utf8');
    } catch {
      continue;
    }
    if (!/^## Verdict: /m.test(text)) continue;
    found.push({ commit, short: sha, atTip: commit === tip, findings: text.match(/^- \[P[123]\].*$/gm) ?? [] });
  }
  return found;
}
const earlier = process.argv.includes('--full') ? [] : earlierReviews();
if (earlier.length >= 2) {
  console.error('review: this branch has had its two reviews; leave what is open under Open findings in the pull request (--full reads the whole branch again)');
  process.exit(2);
}
if (earlier.some((r) => r.atTip)) {
  console.error('review: this commit has already been reviewed; commit your fixes before reviewing again');
  process.exit(2);
}
const last = earlier.at(-1);

const answerForm = `Answer in exactly this form and nothing else after it:

## Verdict: CLEAN
or
## Verdict: FINDINGS

### Findings
- [P1] path/to/file.ts:LINE — one-line claim. Scenario: the input or state that triggers it and what goes wrong. Fix: the smallest change that would resolve it.
- [P2] ...
- [P3] ...
(P1: wrong behaviour, crash or data loss on a reachable path. P2: a reachable edge case, or a test that does
not prove its claim. P3: minor. Omit the section when the verdict is CLEAN.)

### Checked
- one line per area you inspected and found sound`;

const about = `You are a hostile code reviewer for this repository, vmlab: an MCP server in Swift 6 that gives a language
model virtual machines on an Apple Silicon Mac over Virtualization.framework or QEMU (engine-free core under
Sources/VMLabCore, backends under Sources/VMLabQEMU and Sources/VMLabVZ, protocol clients under Sources/VMLabRFB
and Sources/VMLabGDB, the MCP layer under Sources/VMLabMCP, executables under Sources/vmlab*, tests under Tests/).`;

const narrowPrompt = last && `${about}
This branch was reviewed at commit ${last.short}. That review found:

${last.findings.join('\n') || '(nothing)'}

The author has committed since then. Review only those commits (run: git diff ${last.short}..HEAD, and
git log ${last.short}..HEAD for the intent). Do not run the test suites or edit files; reason from the code.
- For each earlier finding, decide whether these commits resolve it. Report it again, at its severity, only
  if the scenario it describes still goes wrong.
- Look for anything these commits themselves break: wrong behaviour for some input or state, an edge case
  the fix does not handle, or a test that does not prove what its name claims.
Code these commits did not touch has had its review: do not report new problems there unless one of these
commits is what makes them reachable. Ignore style, naming and formatting. Do not report hypothetical
problems you cannot tie to a concrete input or state.

${answerForm}`;

const prompt = narrowPrompt || `${about}
Review the changes on this branch against ${base} (run: git diff ${base}...HEAD, and git log ${base}..HEAD for
the intent). Read as much surrounding code as you need to judge them: callers, the Backend protocol and
types in Sources/VMLabCore, the constraints in REQUIREMENTS.md section 0, the appendices the item cites,
docs/ARCHITECTURE.md, and the tests. Do not run the test suites or edit files; reason from the code. Look for:
- behaviour that is wrong for some input or state (crashes, data races, leaked processes or sockets, a guest
  left running or a VM directory left inconsistent, vm.json schema breaks, model-facing errors without an
  Appendix D code);
- edge cases the change does not handle that its callers can reach;
- tests that do not prove what their names claim, or that pass for the wrong reason;
- breaks of the constraints: private Apple API, root, an undeclared dependency, an engine or MCP import in
  VMLabCore, a shell string built from model input, the matrix in Capabilities.swift and REQUIREMENTS.md
  Appendix B disagreeing.
Ignore style, naming and formatting. Do not report hypothetical problems you cannot tie to a concrete
input or state.

${answerForm}`;

console.log(last
  ? `review: ${branch} (${head}), second run: only the commits since ${last.short}; files:\n${git('diff', '--stat', `${last.short}..HEAD`)}\n`
  : `review: ${branch} (${head}) against ${base}; files:\n${stat}\n`);
const rabbit = rabbitAsk(Boolean(last));
const run = spawnSync('codex', ['exec', '--sandbox', 'read-only', '--cd', top, '--color', 'never', '--output-last-message', verdict, prompt], {
  encoding: 'utf8',
  maxBuffer: 256 * 1024 * 1024,
  timeout: 20 * 60 * 1000,
});
writeFileSync(report, `# Review of ${branch} (${head}) against ${base}\n\n${run.stdout ?? ''}\n\n## stderr\n\n${run.stderr ?? ''}\n`);
if (run.status !== 0) {
  console.error(`review: codex exited with ${run.status ?? run.signal}; full output in ${report}`);
  process.exit(2);
}
let answer = '';
try {
  answer = readFileSync(verdict, 'utf8').trim();
} catch {
  console.error(`review: codex wrote no final message; full output in ${report}`);
  process.exit(2);
}
console.log(answer);
console.log(`\nreview: full report in ${report}`);
rabbitReport(rabbit);
const findings = (answer.match(/^- \[(P[123])\]/gm) ?? []).map((line) => line.slice(3, 5));
const blocking = findings.filter((p) => p !== 'P3').length;
if (/^## Verdict: CLEAN/m.test(answer) && blocking === 0) {
  console.log('review: CLEAN');
  process.exit(0);
}
console.log(`review: ${blocking} finding(s) at P1/P2 to fix (${findings.length} in all)`);
process.exit(1);
