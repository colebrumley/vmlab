---
name: retro
description: Review how the codified workflow is working: read every instruction the owner typed since the last retro, find the ones that recur or that the process should have made unnecessary, and change CLAUDE.md, the skills, the scripts or the hooks so they are not needed again. Run it every ten or so merged pull requests, or when the owner asks.
---

# Retro

The workflow in this repository is meant to be reviewed, not only followed. `node scripts/retro.mjs` prints what
the owner had to say by hand to every session on this repository since the last retro, with a tally of
short messages typed more than once.

1. Run `node scripts/retro.mjs` and read all of it.
2. Look for, and list with counts:
   - an instruction given in more than one session ("open a PR", "clean up", "turn X on");
   - a step the owner did by hand that a worker or a script could have done (merging, cleanup,
     pasting a review, moving work to a worktree, updating from main);
   - a place a session asked a question the process should have answered, stalled, or was corrected;
   - a rule that had to be repeated in a hand-off prompt (it belongs in CLAUDE.md).
3. For each, decide where the fix belongs: the Worker protocol or a rule in CLAUDE.md; a skill under
   `.claude/skills/`; a script under `scripts/`; a hook in `.claude/settings.json`; an app setting
   (`ccd_settings`). Prefer a mechanical fix (hook, script) over a sentence.
4. Report before changing anything: a table of the patterns with their counts and causes, the
   change you propose for each and where it goes, and the choices that are the owner's (a gate
   loosened, a stop removed, anything touching the main checkout) with the trade-off and your
   lean. Wait for the owner's answer. Then make the agreed changes in one pull request titled
   `Workflow: <what changed>`, following the Worker protocol.
5. Keep CLAUDE.md short: when you add a rule, look for one it makes redundant.
6. Run `node scripts/retro.mjs --mark`.
