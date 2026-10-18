// The board: what every session working on this repo can see, whichever worktree it is in.
// It lives in the repository's shared git directory, so it is common to all worktrees and is
// never committed. A claim says "this worktree is doing this requirement"; a note tells the
// others something they need to know.
//
//   node scripts/board.mjs                         who is doing what, and the latest notes
//   node scripts/board.mjs claim R-804 "words"    take a requirement; fails if another worktree has it
//   node scripts/board.mjs release R-804          give it up (when merged, blocked or abandoned)
//   node scripts/board.mjs note "words"           tell the others
//   node scripts/board.mjs log 50                 more of the notes
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const dir = process.env['BOARD_DIR'] ?? join(resolve(git('rev-parse', '--git-common-dir')), 'board');
const claims = join(dir, 'claims');
const log = join(dir, 'log.jsonl');
mkdirSync(claims, { recursive: true });

const me = { worktree: process.env['BOARD_WORKTREE'] ?? git('rev-parse', '--show-toplevel'), branch: git('branch', '--show-current') || 'detached' };
const [command = 'status', ...rest] = process.argv.slice(2).filter((arg) => arg !== '--force');
const force = process.argv.includes('--force');

const fail = (message) => {
  console.error(message);
  process.exit(1);
};
const fileOf = (id) => (/^[\w.-]+$/.test(id ?? '') ? join(claims, `${id}.json`) : fail('name what you are claiming, as in R-804'));
const read = (file) => JSON.parse(readFileSync(file, 'utf8'));
/** A claim whose worktree is gone holds nothing. */
const stale = (claim) => !existsSync(claim.worktree);
const ago = (iso) => {
  const minutes = Math.round((Date.now() - Date.parse(iso)) / 60000);
  return minutes < 90 ? `${minutes} min ago` : minutes < 48 * 60 ? `${Math.round(minutes / 60)} h ago` : `${Math.round(minutes / 1440)} d ago`;
};
/**
 * Do `work` while holding the requirement's lock. Looking at who owns a claim and then changing it
 * are two steps; without the lock two sessions could both find the same lapsed claim and both take
 * it. Making a directory is the lock: only one caller can. A lock left by a session that died is
 * broken after ten seconds; the work under it takes milliseconds.
 */
function locked(id, work) {
  const lock = join(claims, `${id}.lock`);
  for (let tries = 0; ; tries++) {
    try {
      mkdirSync(lock);
      break;
    } catch {
      if (tries > 600) fail(`${id} is locked by another session; try again`);
      try {
        if (Date.now() - statSync(lock).mtimeMs > 10_000) rmdirSync(lock);
      } catch {
        // released meanwhile
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
    }
  }
  try {
    return work();
  } finally {
    rmdirSync(lock);
  }
}
const say = (text) => appendFileSync(log, `${JSON.stringify({ at: new Date().toISOString(), branch: me.branch, text })}\n`);
const notes = (count) => {
  const lines = existsSync(log) ? readFileSync(log, 'utf8').split('\n').filter(Boolean).slice(-count) : [];
  for (const line of lines) {
    const note = JSON.parse(line);
    console.log(`  ${ago(note.at).padEnd(11)} ${note.branch}: ${note.text}`);
  }
  if (lines.length === 0) console.log('  nothing yet');
};

if (command === 'claim') {
  const [id, ...words] = rest;
  const file = fileOf(id);
  // a claim made from the main checkout would never lapse, and would not be the claimant's to release
  if (!process.env['BOARD_WORKTREE'] && git('rev-parse', '--absolute-git-dir') === resolve(git('rev-parse', '--git-common-dir'))) fail('claim from a worktree of your own, not from the main checkout (see CLAUDE.md)');
  const mine = { id, ...me, what: words.join(' '), at: new Date().toISOString() };
  const refusal = locked(id, () => {
    const held = existsSync(file) ? read(file) : undefined;
    if (held && held.worktree !== me.worktree && !stale(held) && !force) return `${id} is taken by ${held.branch} (${held.worktree}), ${ago(held.at)}${held.what ? `: ${held.what}` : ''}`;
    writeFileSync(file, JSON.stringify(mine, null, 2));
    return undefined;
  });
  if (refusal) fail(refusal);
  say(`claimed ${id}${mine.what ? `: ${mine.what}` : ''}`);
  console.log(`${id} is yours`);
} else if (command === 'release') {
  const [id, ...words] = rest;
  const file = fileOf(id);
  const refusal = locked(id, () => {
    if (!existsSync(file)) return `${id} is not claimed`;
    const held = read(file);
    if (held.worktree !== me.worktree && !stale(held) && !force) return `${id} belongs to ${held.branch} (${held.worktree})`;
    rmSync(file);
    return undefined;
  });
  if (refusal) fail(refusal);
  say(`released ${id}${words.length > 0 ? `: ${words.join(' ')}` : ''}`);
  console.log(`${id} released`);
} else if (command === 'note') {
  if (rest.length === 0) fail('say something, as in: node scripts/board.mjs note "main now has vm.json schemaVersion 2"');
  say(rest.join(' '));
} else if (command === 'log') {
  notes(Number(rest[0] ?? 50));
} else if (command === 'status') {
  const all = readdirSync(claims).filter((name) => name.endsWith('.json')).map((name) => read(join(claims, name)));
  console.log('Claims');
  for (const claim of all.sort((a, b) => a.id.localeCompare(b.id, 'en', { numeric: true }))) {
    const flag = stale(claim) ? ' [worktree gone: free to claim]' : claim.worktree === me.worktree ? ' [yours]' : '';
    console.log(`  ${claim.id.padEnd(8)} ${claim.branch}, ${ago(claim.at)}${flag}${claim.what ? `: ${claim.what}` : ''}`);
  }
  if (all.length === 0) console.log('  none');
  console.log('Notes');
  notes(15);
} else fail(`unknown command ${command}: use claim, release, note, log or nothing`);
