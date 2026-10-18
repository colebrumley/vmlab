// Refuses, before it runs, a shell command that would break the worktree rule (CLAUDE.md, rule 1):
// commits, branch switches, stashes and test runs happen in a worktree of your own, never in the
// main checkout, once any worktree exists under .claude/worktrees/.
// Registered as a PreToolUse hook on Bash in .claude/settings.json; the hook's JSON arrives on stdin.
// Exit 2 (with the reason on stderr) refuses the command; exit 0 lets it run.
//   echo '{"tool_input":{"command":"git commit"},"cwd":"."}' | node scripts/guard.mjs
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';

const git = (cwd, ...args) => {
  try {
    return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
};
const real = (path) => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};
const toplevel = (cwd) => real(git(cwd, 'rev-parse', '--show-toplevel'));
const commonDir = (cwd) => {
  const dir = git(cwd, 'rev-parse', '--git-common-dir');
  return dir ? real(resolve(cwd, dir)) : '';
};

/** Commands that commit, switch branches, stash, or run a suite: worktree only. */
const CHANGES_TREE =
  /\bgit\s+(?:-C\s+\S+\s+)?(?:commit|checkout|switch|stash)\b|\bswift\s+test\b|(?:^|[\s/])scripts\/check\.sh\b/;

const unquote = (m) => m?.[2] ?? m?.[3] ?? m?.[4];
const at = (cwd, target) => (isAbsolute(target) ? target : resolve(cwd, target.replace(/^~/, process.env['HOME'] ?? '~')));

/**
 * The simple commands the shell will run one after another, each with the directory it acts in:
 * a `cd` moves every later one, git's `-C` moves only its own.
 */
function steps(command, cwd) {
  const out = [];
  let current = cwd;
  for (const step of command.split(/\s*(?:&&|\|\||;|\||\n)\s*/).filter(Boolean)) {
    const cd = /^cd\s+("([^"]+)"|'([^']+)'|(\S+))\s*$/.exec(step);
    if (cd) {
      current = at(current, unquote(cd));
      continue;
    }
    const dashC = /\bgit\s+-C\s+("([^"]+)"|'([^']+)'|(\S+))/.exec(step);
    out.push({ step, dir: unquote(dashC) ? at(current, unquote(dashC)) : current });
  }
  return out;
}

let input;
try {
  input = JSON.parse(readFileSync(0, 'utf8'));
} catch {
  process.exit(0);
}
const command = String(input?.tool_input?.command ?? '');
const cwd = String(input?.cwd ?? process.cwd());
if (!command) process.exit(0);

const changing = steps(command, cwd).find(({ step, dir }) => {
  if (!CHANGES_TREE.test(step)) return false;
  const top = toplevel(dir);
  return top && top === dirname(commonDir(dir)) && existsSync(join(top, '.claude', 'worktrees'));
});
if (changing) {
  console.error(
    `${toplevel(changing.dir)} is the main checkout. Commits, branch switches, stashes and test runs happen in a worktree of your own under .claude/worktrees/ (CLAUDE.md, rule 1). ` +
      `If this session already has one, run the command from there; otherwise make one: git fetch origin && git worktree add .claude/worktrees/<name> -b <name> origin/main. ` +
      `The owner may run this from a terminal.`,
  );
  process.exit(2);
}
