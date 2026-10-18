---
name: bughunt
description: Find real bugs in the core, a backend, a protocol client or the MCP layer, each with a concrete reproduction, write them up as a spec of size-S items, and dispatch the fixes with /build. Run it on Opus 5.5 at medium effort, not on the planning model. Use when the owner asks for a bug hunt or a sweep of an area.
argument-hint: [area, such as Sources/VMLabQEMU/QMPClient.swift or "checkpoints"]
---

# Bug hunt

1. Pick the area: the one given, or the module least recently touched by a bug fix
   (`git log --format=%s -- Sources | grep -c Fix` per file is a fair guide). Read it with its
   callers, the appendices it implements in REQUIREMENTS.md, `docs/ARCHITECTURE.md` and its tests.
2. Hunt for what is reachable and wrong: a tool call that crashes the server instead of returning an
   Appendix D error, a guest process or socket leaked when something fails halfway, a `vm.json` left
   inconsistent, a data race across actors, the matrix and a backend disagreeing on what a profile
   can do, a test that passes for the wrong reason. `/critique --depth
   quick <file>` is a good opening move. Confirm each bug with a failing test or a written-out sequence of
   tool calls; a suspicion is not a finding.
3. Write `docs/specs/bugs-<area>-<date>.md` from the template: one size-S item per confirmed bug, each
   with the reproduction as the test to write, the root cause, and the smallest fix. Add the backlog
   lines, commit, push, merge the spec, post a board note.
4. Run `/build` on it. Report the bugs found, the ones fixed and merged, and any left open.
