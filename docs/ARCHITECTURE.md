# Architecture

vmlab is one Swift package. A model talks MCP over stdio to `vmlab serve`; the MCP layer and the CLI
are thin adapters over `VMLabCore`, which chooses an engine for each guest and drives it through the
`Backend` protocol. State lives on disk under `VMLAB_HOME` (Appendix F), so guests outlive the server.
Constraint C3 is enforced by `Tests/UnitTests/BoundariesTests.swift`: Core imports no engine and no
MCP module, and `VMLabMCP` and `vmlab` import no backend module.

## Targets

**`VMLabCore`** (library). The engine-free model: the feature catalogue, the four profiles, the
capability matrix (`Capabilities.swift`, the authority by C7), the selector, the VM store and
`vm.json` records, the `Backend` protocol and the backend registry, and `VMLabError` with the Appendix
D codes. `Features.swift` holds the Appendix A catalogue (`Feature`, with `kind` and `summary`) and the
`Requirements` request (`GuestSpec`, `ResourceSpec`, `NetworkSpec`, `BootSpec`), which refuses a
self-contradictory request at decode time with `invalid_request`; `Errors.swift` holds `ErrorCode`,
`VMLabError` and `JSONValue` for error `data`. It owns the per-VM event log (`EventLog`, one `VMEvent` JSON object per line of
`events.jsonl`, appended with `O_APPEND` so the server and runner processes never interleave) and
process-wide logging (`VMLabLogging`: swift-log to stderr at the `VMLAB_LOG` level, default `info`).
`CodeSignature` reads `codesign` output so `vmlab doctor` can say whether the runner is entitled. `Profile` names the four profiles with their Appendix B tiers. `HostProbe` gathers `HostFacts` (Appendix E fast facts) through an injectable `CommandRunning` and merges the slow probes persisted in `VMLAB_HOME/host-facts.json` (`SlowProbes`), resetting to `unknown` any probe recorded under another macOS or QEMU version; `ProbeResult.countsAsYes` is how selection reads a probe (unknown counts as no).
`FeatureDocs` renders `docs/FEATURES.md` from the matrix. It depends on swift-log only.

**`VMLabQEMU`** (library). The QEMU backend: launching and supervising `qemu-system-aarch64`, the QMP
client, the serial channel, the GDB stub endpoint, and qcow2 internal snapshots.

**`VMLabVZ`** (library). The Virtualization.framework backend, seen from the server: the client of a
`vmlab-vz` runner's control socket, and the integration with Tart for macOS images and clones. The
framework itself is loaded only in `vmlab-vz`.

**`VMLabRFB`** (library). A VNC (RFB) client: framebuffer updates to PNG, pointer and key events. It
gives both engines a screen to look at and click on. `RFBClient` (an actor) speaks RFB 3.8 over an
`RFBTransport`: `SocketTransport` for a unix or TCP socket, `ReplayTransport` for recorded fixture
streams. It negotiates security None or VNC Authentication (`VNCAuth`, DES via CommonCrypto), sets
32-bit BGRX, requests Raw, CopyRect and DesktopSize, and a background loop of incremental update
requests keeps a `Framebuffer` current; `snapshot()` returns a `CGImage` and `Framebuffer.pngData`
encodes PNG with ImageIO. Input (`RFBInput.swift`, `Keysym.swift`): `pointer(x:y:buttons:)` with a
`PointerButtons` mask, `key(_:down:)`, `press(_:)` for a `KeyChord` parsed from `cmd+shift+4`-style
text (`cmd` is `Super_L`), and `type(_:gap:)`, which strikes each character with Shift where a US
layout needs it, 10 ms apart. Screenshots (`ScreenshotEncoder.swift`, `ScreenshotCache.swift`):
`ScreenshotEncoder` crops a `Framebuffer` to a `PixelRect` region, scales its long edge to `maxEdge`
(default 1280, never upscaling) and encodes PNG or JPEG with a quality; `ScreenshotCache`, one per VM
held by its owner, keeps the last 20 frames LZFSE-compressed under ids so a later capture with
`diffFrom` returns only the changed bounding box (`Framebuffer.changedRect`) at the full frame's
scale, or `unchanged: true`. Failures are `RFBError` (`invalidScreenshotRequest` is
`invalid_request`), which callers map to Appendix D codes.

**`VMLabGDB`** (library). A GDB remote serial protocol client: registers, memory, breakpoints,
watchpoints and stepping over a guest's GDB stub. `GDBPacket`/`GDBPacketDecoder` frame packets
(checksums, acks, escapes, run-length encoding); `GDBCommand` builds payloads; `GDBClient` is an
actor in all-stop mode over a `GDBTransport` (`GDBTCPTransport` for QEMU's `-gdb tcp:...`) that
serialises commands, acks replies, resends on `-`, and turns stop replies into `StopReason`.
`RegisterMap` comes from `qXfer:features:read` (`target.xml` and its `xi:include`s) or a built-in
arm64/x86_64 layout. Errors are the module's own `GDBError`; the debug tool maps them to Appendix D.

**`VMLabMCP`** (library). The MCP server on the official Swift SDK: tool schemas (Appendix C),
handlers that call Core, rendering of `VMLabError` as structured refusals, and the stdio transport.
`ToolDocs` renders `docs/TOOLS.md` from the schemas.

**`vmlab`** (executable). The CLI on swift-argument-parser: every MCP tool as a subcommand with
`--json` output, `vmlab serve` for the MCP server, `vmlab doctor`, and the hidden `vmlab gen-docs`
that `scripts/gen-docs.sh` uses. It bootstraps logging and hands off to Core and `VMLabMCP`.

**`vmlab-vz`** (executable). The VZ runner: one process per Virtualization.framework guest, so a
guest outlives the server, driven over `control.sock` in the VM directory. It is the only binary
that needs `com.apple.security.virtualization`; `scripts/sign.sh` ad-hoc signs it with
`Sources/vmlab-vz/vmlab-vz.entitlements` after every build.

**`VMLabSwitch`** (library). The segment switch with no engine and no Core dependency.
`SwitchCore` is the forwarding logic on integer ports: a learning MAC table with aging, flooding of
broadcast, multicast and unknown destinations, and counters (`SwitchStats`) for frames over 1600
bytes, malformed frames and congested ports. `SwitchServer` puts it on sockets in
`$VMLAB_HOME/segments/<name>/` (`SegmentPaths`): every sender to the unix datagram `switch.sock`
becomes a port with its own datagram socket connected back to the sender's bound path (how QEMU's
`-netdev dgram` attaches), `attach(fd:)` adds a port on one end of a `socketpair` (for VZ, R-901),
a port whose peer is gone is removed on the next send, and a connection to `stats.sock` receives
the counters as one JSON line. One thread runs a `poll` loop; there is no host connectivity
through the switch.

**`vmlab-switch`** (executable). `vmlab-switch <name>`: one process per segment running
`SwitchServer`, with no root and no `vmnet` (C2). It writes `switch.pid`, refuses to start beside a
live switch for the same segment, and removes its sockets on SIGTERM or SIGINT.

**`UnitTests`** (Swift Testing). Fast tests with no engines; file paths mirror `Sources/`, and
fixtures come from `Tests/Fixtures/` through `#filePath`.

**`IntegrationTests`** (Swift Testing). Tests that boot real guests through QEMU or Tart and need
pulled images; each skips itself unless `VMLAB_INTEGRATION=1`.

## Scripts

`scripts/check.sh` (format lint, build, unit tests, sign, generated docs current), `build.sh`,
`sign.sh`, `bootstrap.sh` (Homebrew: qemu, tart), `gen-docs.sh`, and the process scripts
`board.mjs`, `tidy.mjs`, `review.mjs`, `retro.mjs` and `guard.mjs` (the worktree-rule hook)
described in CLAUDE.md.
