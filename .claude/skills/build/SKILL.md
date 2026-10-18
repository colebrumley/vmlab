---
name: build
description: Dispatch the work items of a spec under docs/specs/ to workers at Opus 5.5 and medium effort, each in its own worktree, every item as an in-process subagent, then tidy up when they have merged. Use after /plan once the spec is on origin/main.
argument-hint: <docs/specs/slug.md> [only these items: R-xxxx R-yyyy]
---

# Build

Read the spec once. Run `node scripts/board.mjs`: an item another worktree has claimed is not yours to
dispatch. Order the items by their dependencies. An item whose dependency has not merged waits.

## Dispatch each item that is ready

Every worker gets the same prompt, built from the spec; nothing else is pasted in, because the process
is the Worker protocol in CLAUDE.md and every session reads that file:

```
Repo: vmlab (this repository). Follow the Worker protocol in CLAUDE.md exactly: it is the whole
process, including the pull request, the two reviews of it and the merge after them.

Item: R-xxxx <title> — docs/specs/<slug>.md, item Wn. Read the whole spec once; build only this item.

<the item's section of the spec, verbatim: files, acceptance, Verify, dependencies>
<the spec's "Shared surfaces" and "Open questions and decisions" sections, verbatim>
```

Every item, whatever its size, goes to the `Agent` tool: `subagent_type: general-purpose`,
`model: opus`, `effort: medium`, `isolation: worktree`, `run_in_background: true`, the prompt above.
Launch every ready item in the same message so they run at once. The owner chose this model and
effort, and subagents over task chips, for building; neither is a judgment call.

## While they run

When a subagent reports, read its last paragraph: the pull request address, whether it merged, and
anything left open. If it merged, dispatch the items that were waiting on it. If it left findings or
a question, relay them to the owner in one or two sentences and move on; do not fix a worker's branch
yourself.

## When everything is in

Run `node scripts/tidy.mjs`. Report in one paragraph: each item with its pull request and whether it merged,
the items still open and why, and anything a worker found that the spec did not foresee. If the spec
is fully built, change its status line to `built` in a last small pull request.
