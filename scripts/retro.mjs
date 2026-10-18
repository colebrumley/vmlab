// What the owner had to type by hand: every message a person sent to a Claude Code session on this
// repository (main checkout and worktrees alike) since the last retro, for the /retro skill to read
// for instructions that recur, steps still done by hand, and places a session stalled.
//   node scripts/retro.mjs              messages since the last retro (everything, the first time)
//   node scripts/retro.mjs --all        everything
//   node scripts/retro.mjs --mark       record now as the last retro
// The stamp lives beside the board in the shared git directory, so it is never tracked.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const common = resolve(git('rev-parse', '--git-common-dir'));
const main = process.env['RETRO_MAIN'] ?? dirname(common);
const projects = process.env['RETRO_PROJECTS'] ?? join(homedir(), '.claude', 'projects');
const stampFile = join(process.env['BOARD_DIR'] ?? join(common, 'board'), 'retro.json');
const all = process.argv.includes('--all');

/** Instructions the process is meant to make unnecessary; a message may count towards several. */
const INTENTS = [
  ['merge', /\bmerged?\b/i],
  ['open a PR', /\b(open|create)\b.*\b(pr|pull request)\b|\bpush\b.*\b(pr|pull request)\b/i],
  ['address PR feedback', /\b(review|address|respond to)\b.*\b(feedback|review|comments?)\b|\bpr feedback\b/i],
  ['clean up worktree or branch', /\bclean ?up\b|\bdelete\b.*\bbranch/i],
  ['turn Auto-fix on', /\bauto ?-?fix\b/i],
  ['use a worktree', /\bwork ?tree\b/i],
  ['update from main', /\b(update|rebase|merge)\b.*\b(from|with|onto) main\b|\bfix (the )?conflicts\b/i],
  ['release the claim', /\brelease\b.*\bclaim\b/i],
  ['commit or push', /\b(commit|push) (it|this|the changes)\b/i],
  ['hand-off preamble', /^Repo: /],
];

if (process.argv.includes('--mark')) {
  mkdirSync(dirname(stampFile), { recursive: true });
  writeFileSync(stampFile, JSON.stringify({ at: new Date().toISOString() }, null, 2));
  console.log(`retro: marked ${stampFile}`);
  process.exit(0);
}
const since = !all && existsSync(stampFile) ? JSON.parse(readFileSync(stampFile, 'utf8')).at : '';

// ~/.claude/projects keys a folder by the session's working directory with every "/" and "." as "-":
// the main checkout, and its worktrees under .claude/worktrees/ (a sibling folder such as
// vmlab-tools shares the prefix but is another repository).
const prefix = main.replace(/[/.]/g, '-');
const dirs = existsSync(projects) ? readdirSync(projects).filter((name) => name === prefix || name.startsWith(`${prefix}--claude-worktrees-`)) : [];

/** Text a person typed, or the automatic things that stand in for it, which are left out. */
function typed(entry) {
  if (entry.type !== 'user' || entry.isMeta || !entry.message) return '';
  const content = entry.message.content;
  let text = typeof content === 'string' ? content : Array.isArray(content) ? content.filter((p) => p.type === 'text').map((p) => p.text).join('\n') : '';
  text = text.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '').trim();
  if (!text) return '';
  if (/^<(command-name|local-command|task-notification|ci-monitor-event|bash-input|create-pr-command)/.test(text)) return '';
  if (/^\[Request interrupted/.test(text) || /^This session is being continued from a previous conversation/.test(text)) return '';
  return text;
}

const sessions = [];
for (const dir of dirs) {
  for (const file of readdirSync(join(projects, dir)).filter((name) => name.endsWith('.jsonl'))) {
    const messages = [];
    for (const line of readFileSync(join(projects, dir, file), 'utf8').split('\n')) {
      let entry;
      try {
        entry = JSON.parse(line);
      } catch {
        continue;
      }
      const text = typed(entry);
      if (!text || (since && entry.timestamp <= since)) continue;
      messages.push({ at: entry.timestamp, text });
    }
    if (messages.length > 0) sessions.push({ where: dir.slice(prefix.length) || '(main checkout)', id: file.slice(0, 8), messages });
  }
}
sessions.sort((a, b) => a.messages[0].at.localeCompare(b.messages[0].at));

const tally = new Map(INTENTS.map(([name]) => [name, 0]));
for (const session of sessions) {
  console.log(`\n## ${session.where} / ${session.id}  (${session.messages.length} messages from ${session.messages[0].at.slice(0, 16)})`);
  for (const { at, text } of session.messages) {
    console.log(`\n[${at.slice(11, 16)}]${/^Repo: /.test(text) ? ' [hand-off prompt]' : ''} ${text}`);
    for (const [name, re] of INTENTS) if (re.test(text)) tally.set(name, tally.get(name) + 1);
  }
}
const repeated = [...tally].filter(([, n]) => n > 0).sort((a, b) => b[1] - a[1]);
console.log(`\n## Instructions the process should make unnecessary${since ? ` (since ${since})` : ''}`);
for (const [name, n] of repeated) console.log(`  ${String(n).padStart(3)}  ${name}`);
if (repeated.length === 0) console.log('  none');
console.log(`\nretro: ${sessions.length} session(s), ${sessions.reduce((n, s) => n + s.messages.length, 0)} message(s)${since ? ` since ${since}` : ''}. Run with --mark when the retro is done.`);
