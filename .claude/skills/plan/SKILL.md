---
name: plan
description: Turn a bug report, a problem description or a feature idea into a spec under docs/specs/ with work items that /build dispatches to workers. The planning seat; run it at high effort. Use at the start of any new piece of work on this repository.
argument-hint: <the bug, problem or feature, in a sentence or a pasted report>
---

# Plan

You are planning, not building. The output is `docs/specs/<slug>.md` (from `docs/specs/TEMPLATE.md`),
one backlog line per work item in `REQUIREMENTS.md`, and a merged pull request holding both. Workers at
a cheaper model then build each item from the spec alone, so the spec must stand on its own.

## 1. Place

Work in a worktree of your own (CLAUDE.md, rule 1); the guard hook refuses commits anywhere else. Run
`node scripts/board.mjs` and read the notes: someone may be in the files you are about to plan around.

## 2. Understand before writing

- **Bug** (vmlab does something it should not): find the code path, name the test file and what the
  failing assertion would say, and state the root cause. Usually one item of size S.
- **Problem** (a felt gap, a tool the model misuses, a guest that will not boot, a refusal that does
  not say what to change): read the modules involved (`docs/ARCHITECTURE.md`), the constraints in
  REQUIREMENTS.md §0, the appendices they implement (A to I), and the tests that pin them, then decide
  what change answers it.
- **Feature**: the same reading, plus the engine question. Which profiles in the matrix
  (`Capabilities.swift`, Appendix B) can provide it, through which public API or QEMU option. A claim
  about an engine not yet confirmed on this host is a `[VERIFY]` probe with a named fallback, not an
  assumption.

Read the request as incomplete until the code says otherwise:

- "Simple", "just" and "easy" mark what was left out. Find the part being skipped over.
- Where two reasonable builds would both satisfy the words, that is a fork: name both, do not pick
  silently.
- A word that could mean two things ("snapshot", "the network", "the screen") gets pinned to the
  type, tool or feature it means in this code.
- A change to what vmlab already does has a cost in what exists: VM directories made before it (the
  `vm.json` schema version, constraint C4), guests running across a server restart, tool schemas a
  model has learned, tests and fixtures that pin the old behaviour. Say what happens to each.

Settle what reading can settle. Where a fork that changes what gets built is left, ask the owner
now, in one `AskUserQuestion` call with at most three questions, each with a recommended option.
Lead with the one most likely to make a worker build the wrong thing. Do not interview beyond that:
a fork you settled yourself goes in the spec as the planner's choice, apart from the owner's
decisions, with the alternative rejected.

A fork that changes what the model sees (a tool's input shape, an error code's meaning, a feature
name) is always the owner's, never the planner's choice. So is anything that would bend a constraint
in §0.

## 3. Write the spec

Copy `docs/specs/TEMPLATE.md` to `docs/specs/<slug>.md` and fill every section. Work items:

- independent of one another wherever the code allows; a shared surface (a type in `VMLabCore`, the
  `Backend` protocol, the `vm.json` schema version, a tool schema, an error code, a test helper) is changed by one item that goes first;
- each small enough for one worker session: S (an hour or less, a few files), M or L (more); every
  size is built by a subagent, so split an L that one session could not finish;
- each names its files, acceptance bullets a test can check, the tests that are its definition of done,
  and what it depends on. Write the acceptance as what the model or the CLI
  sees, not as code.

Allocate R-numbers after the highest in `REQUIREMENTS.md` and add one line per item under
`## Phase 12 — Planned work`:
`- [ ] **R-xxxx <title>** — docs/specs/<slug>.md, item W1, size S.`
The worker ticks that line in its own pull request; nobody else edits it.

For a spec of size L or with more than four items, run `/critique --depth quick docs/specs/<slug>.md`
and fold in what it finds.

## 4. Hand it over

Show the owner the goal, the item list with sizes, and the decisions and open questions, in a short
message. On their go: commit as `R-xxxx..R-yyyy: plan <slug>`, push, open the pull request, merge it
(a spec needs no review pass), post a board note naming the spec and the shared surfaces, then run
`/build docs/specs/<slug>.md`. If the owner changes the plan, change the spec first.
