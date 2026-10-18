# <Title>: spec for R-xxxx to R-yyyy

Written by `/plan` on <date>. Status: proposed | approved | built.

**The request, in the owner's words:** one paragraph. What is wrong, or what is wanted, and why.

## Goal

One or two sentences a worker can hold in mind. What vmlab does when this is done.

## Non-goals

What this deliberately does not do, so that no worker widens it.

## Engines and the matrix

Which profiles this touches and how the capability matrix changes, if at all. A new feature gets a
row in Appendix A and B of REQUIREMENTS.md and an entry in `Capabilities.swift` (constraint C7). A
claim about an engine that has not been confirmed on this host is a probe, not an assumption: name
the probe and the fallback.

## Shared surfaces

Types in `VMLabCore`, the `Backend` or `RunningVM` protocols, the `vm.json` schema version, a tool
schema in `VMLabMCP`, an error code, a test helper, a script: anything more than one item touches.
Say which item changes each, and that it goes first.

## Work items

Independent where possible; each small enough for one worker session. Size S is an hour's work or
less in a few files; M and L are more. An item names the files it will touch, acceptance bullets a
test can check, the tests that prove it (the definition of done), whether it needs integration tests
(real guests) and which image, and what it depends on.

### W1 — <title> (R-xxxx, size S, depends on: nothing)

Files: `Sources/VMLabCore/Foo.swift`, `Tests/UnitTests/Core/FooTests.swift`, `docs/ARCHITECTURE.md`

Acceptance:
- ...
- ...

Verify: `swift test --filter FooTests`; `scripts/check.sh`.

### W2 — <title> (R-yyyy, size M, depends on: W1)

...

## Open questions and decisions

Decisions the owner made during planning, with the alternative rejected. Questions left open, and
what a worker should do if it meets one (the default: build the smaller reading, say so in the PR).
