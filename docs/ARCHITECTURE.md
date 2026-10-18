# Architecture

vmlab is one Swift package. A model talks MCP over stdio to `vmlab serve`; the MCP layer and the CLI
are thin adapters over `VMLabCore`, which chooses an engine for each guest and drives it through the
`Backend` protocol. State lives on disk under `VMLAB_HOME` (Appendix F), so guests outlive the server.
Constraint C3 is enforced by `Tests/UnitTests/BoundariesTests.swift`: Core imports no engine and no
MCP module, and `VMLabMCP` and `vmlab` import no backend module; `vmlab` reaches the engines only
through `VMLabEngines`.

## Targets

**`VMLabCore`** (library). The engine-free model: the feature catalogue, the four profiles, the
capability matrix (`Capabilities.swift`, the authority by C7), the selector, the VM store and
`vm.json` records, the `Backend` protocol and the backend registry, and `VMLabError` with the Appendix
D codes. `Features.swift` holds the Appendix A catalogue (`Feature`, with `kind` and `summary`) and the
`Requirements` request (`GuestSpec`, `ResourceSpec`, `NetworkSpec`, `BootSpec`), which refuses a
self-contradictory request at decode time with `invalid_request`; `Errors.swift` holds `ErrorCode`,
`VMLabError` and `JSONValue` for error `data`. It owns the per-VM event log (`EventLog`, one `VMEvent` JSON object per line of
`events.jsonl`, appended with `O_APPEND` so the server and runner processes never interleave) and
a `VMEvent` may carry structured `data`. `PanicDetector` (R-304) hangs on a `SerialChannel`'s line observer,
matches each line against `PanicSignature.table` and appends a `panic` event (the line, its `pattern`,
`offset` and `end`), capped with one suppression notice; `EventLog.recordQMPEvent(_:data:)` is the hook the
QEMU backend calls for QMP events (`GUEST_PANICKED` becomes `panic`, `RESET` `lifecycle`, others ignored),
and `EventLog.latestPanic()` reads the newest. Also process-wide logging (`VMLabLogging`: swift-log to stderr at the `VMLAB_LOG` level, default `info`).
`CodeSignature` reads `codesign` output so `vmlab doctor` can say whether the runner is entitled. `Profile` names the four profiles with their Appendix B tiers. `HostProbe` gathers `HostFacts` (Appendix E fast facts) through an injectable `CommandRunning` and merges the slow probes persisted in `VMLAB_HOME/host-facts.json` (`SlowProbes`), resetting to `unknown` any probe recorded under another macOS or QEMU version; `ProbeResult.countsAsYes` is how selection reads a probe (unknown counts as no). `SlowProbeRunner.swift` is the slow probe registry: an item that owns a probe (`SlowProbe.owner`: R-307, R-309, R-608, R-702) conforms a `SlowProbeRunner` and calls `SlowProbeRunners.register`; `SlowProbeRegistry.runAll` runs them one at a time, persists each `yes` or `no` to `host-facts.json`, and reports a probe with no runner as `not_implemented`, left as it was. `docs/FEATURES.md` reads that file, so recording probes on the development host means running `scripts/gen-docs.sh`.
`Images.swift` holds the Appendix H catalogue (`ImageCatalogue.builtin`, decoded from JSON into `CatalogImage`) and `ImageStore`, an actor over `VMLAB_HOME/images/<name>/` that pulls (URLSession through an injectable `ImageDownloading`, checksum from the published `SHA512SUMS`/`SHA256SUMS`, qcow2 to raw with `qemu-img` through `CommandRunning`), lists and removes images and records `image.json` (`PulledImage`); a re-pull whose file still matches the published checksum is a no-op. `ImageStore.defaultHome()` resolves `VMLAB_HOME`.
`KernelImages.swift` adds direct-kernel-boot files to the store (R-305): `extractKernel` copies the newest `vmlinuz-*` with its initrd, `System.map` and `config` out of a pulled image's `/boot` into `images/<name>/kernel/` (recorded under the `files` keys `kernel`, `initrd`, `systemMap`, `config`, plus `kernelVersion`), and `registerKernel` records a host kernel (and initrd), as a `format: kernel` image when no disk is pulled under that name. `Ext4.swift` (`Ext4Volume`) reads GPT partitions and ext4 (extents, block maps, linear and hashed directories, symlinks) read-only, because macOS has no ext4 driver for `hdiutil` to mount; an image without `disk.raw` is converted to a temporary raw file first. Debian's `System.map` is a stub that points at the `-dbg` package.
`CloudInit` builds the NoCloud seed both engines attach: from a plain `CloudInitConfig` (hostname, user, SSH key, packages, optional `GUIStack`, `SegmentNIC`, `GuestMount`s, `ConsoleDevice`, extra user-data merged last as a MIME part) it emits `user-data`, `meta-data` and `network-config` with a small hand-written YAML emitter (every string double-quoted; no YAML library, C5) and runs `hdiutil makehybrid` to make the `cidata` ISO. `FeatureDocs` renders `docs/FEATURES.md` from the matrix. It depends on swift-log only.
`Store.swift` holds the VM store: `VMRecord` (the `vm.json` of `vms/<id>/`, with `VMState`, `VMRuntime` endpoints, `CheckpointRef`s, the resolved `[Feature]` and the optional creating `Plan`), and `Store`, which lists, loads, creates (IDs `vm-` plus six base32 characters, unique names defaulting to the ID), updates and removes records under `VMLAB_HOME` (`Store.defaultHome`). Writes go through a temp file and `rename(2)` under a per-VM `flock` on `locks/<id>.lock` (names under `locks/store.lock`, always taken after a VM lock), so two server processes never corrupt or lose an update; `StoreMigrations` upgrades older `schemaVersion`s step by step, with one fixture per released version in `Tests/Fixtures/store/`. `Store.runningGuests()` is the counter `HostProbe.runningGuests` and the budgets read. `Tests/StoreHelper` builds `vmlab-store-helper`, a test-only executable (no product) that `StoreTests` spawns as the second writer.

`Lifecycle.swift` holds the lifecycle state machine: `Lifecycle.table` maps each `VMState` and `LifecycleAction` (start, stop, kill, pause, resume, reset, destroy, checkpoint_stop) to a `LifecycleTarget` (a state or `destroyed`); `Lifecycle.transition` throws `wrong_state` with `state` and `legalActions` for any other pair. It also holds reattach: `Store.reconcile(probe:)` checks each record's `runtime.pid` with an injectable `LivenessProbe` (default `kill(pid, 0)` plus a connect to the control or QMP unix socket), marks a live, answering engine `running`, and a gone or silent one `stopped` (`broken` when no `Store.diskCandidates` file exists, `suspended` kept), clearing `runtime` and logging a `lifecycle` event per change. The server calls it at start.
`Serial.swift` holds `SerialChannel`, an actor over a guest's serial unix stream socket (QEMU's `-serial unix:`, or the `vmlab-vz` bridge, R-602), engine-neutral so both backends share it. `start(connectTimeout:)` connects (retrying while the socket is absent or refusing) and a reader thread feeds bytes in order to the actor, which appends them to `<vm>/serial.log` (`O_APPEND`, never truncated, rotated to `serial.log.1` past 64 MB) and a 4 MB `ByteRing` addressed by absolute byte offsets from the channel's first byte. `read(since:maxBytes:)` and `read(tail:)` return `SerialRead` (`text`, `start`, `offset`, `truncated` when bytes fell out of the ring or were cut); `write(_:)` sends UTF-8 and returns the end offset; `wait(for:since:timeout:)` matches a Swift `Regex` against output at or after `since` (default: the current end) and returns `SerialMatch` (`match`, `start`, `offset` after it), or `timeout`, `guest_unreachable` when the socket closes, `invalid_request` for a bad pattern. `setLineObserver` receives every completed `SerialLine` with its offsets (R-304's panic table hangs there). The socket descriptor is closed exactly once, by the reader, under the lock writes take.
`Backend.swift` holds the engine seam (R-105): `protocol Backend` (its `profile`; `create(_:plan:)`, `start` returning the `VMRuntime`, `stop`, `kill`, `pause`, `resume`, `reset` (default kill then start), `destroy`, and `attach(_:)` returning a `RunningVM`), every call taking the current `VMRecord` and throwing `VMLabError`. `protocol RunningVM` exposes the raw channel handles a backend provides (`serial: SerialChannel?`, `display: DisplayEndpoint?` (VNC unix socket or host:port, `Auth` none or a password file, `hostSide`), `gdb: GDBEndpoint?` (host, port; parses `tcp:` runtime strings), `introspection: (any Introspection)?`, `exec: any ExecChannel`, `checkpoints: any CheckpointProvider`; the three protocols are minimal for R-311, R-400/R-401 and R-307/R-800 to extend), and callers reach them only through `channel(_:)` with a typed `Channel` key (`.serial`, `.display`, `.gdb`, `.introspection`, `.exec`, `.checkpoints`), which throws `capability_missing` (`feature`, `profile`, `channel`, `anyOf`, the `vm_plan` hint) unless the VM's granted features include one that grants the channel, and `guest_unreachable` when it was granted but the engine has not brought it up. `BackendRegistry` (a `Mutex`-guarded map from profile to backend) and its process-wide `Backends.shared`/`Backends.register(_:)` are how `vmlab` wires the engines. `VMManager.swift` is the actor that drives a VM through `Lifecycle`, `Store` and its `Backend`: `create(_:plan:)` stores the record (profile, features, resources from the plan) and has the backend create it, removing everything on failure or cancellation; `perform(_:on:)` checks the transition, calls the backend, re-checks the state under the VM's lock and records the target state and runtime (destroy kills a live guest, destroys and removes the directory), logging a `lifecycle` event or an `error` event; actions on one VM are serialized in-process; `attach(_:)` needs a running or paused VM. `Tests/UnitTests/Support/FakeBackend.swift` is the backend tests drive it with.
`Capabilities` is the Appendix B matrix: `Capabilities.entry(feature, on: profile)` gives the unresolved cell (`Availability.yes`, `.no(reason)` or `.conditional(Condition)`, where a `Condition` names a fast fact such as `root` or a `SlowProbe`, plus the note and the item that verifies a `?`), and `capabilities(of:host:allowUnverified:)` resolves every cell to yes or no against `HostFacts` (an `unknown` probe is no unless `allowUnverified`); `unverifiedProbes` says which probes a plan reports as unverified, and `supports(_:on:)` is the guest OS and arch filter.
`Selector.swift` is Appendix I: `select(_:host:running:allowUnverified:)` (also `ProfileSelector.select`, which takes `ResourceLimits`) normalises a `Requirements` (features implied by `network` and `boot` become required, Appendix G resources filled in), filters the four profiles by guest and by every required feature, applies the dynamic limits to the survivors in rank order and returns a `Plan` (profile, resolved resources, `features` = required plus every `yes`, `preferredDenied`, `unverified`, notes, a startup estimate) or an `Unsatisfiable` (per-feature `eliminated` with reasons, minimal drop `suggestions` up to size 3 and at most five, the `unverified` probes in the way, or the `limit` error) whose `error` is the Appendix D refusal. `Limits.swift` holds `ResourceLimits` (reserve 4 GB, two macOS guests, four parallel starts; `defaultResources(for:)`, `checkMacOSGuests`, `checkMemory`, which R-107 reuses before a start) and `Inventory`, the live guests (profile, OS, memory) built from `VMRecord`s or `Store.inventory()`. `StartGate.swift` (R-107) is admission to a start: the `StartGating` protocol (`admit(_:running:host:)` returns a `StartPermit`, `release(_:)`, `withStart`) and `StartGate`, the in-process actor (`StartGate.shared`) that holds a FIFO semaphore of `parallelStarts` slots and, once a slot is held, runs `ResourceLimits.check` against the running inventory plus the guests of starts already admitted (deduplicated by id), so concurrent starts cannot overrun the memory or macOS budget. R-1100 makes it cross-process by conforming another type to `StartGating`.
`CloudInit` builds the NoCloud seed both engines attach: from a plain `CloudInitConfig` (hostname, user, SSH key, packages, optional `GUIStack`, `SegmentNIC`, `GuestMount`s, `ConsoleDevice`, extra user-data merged last as a MIME part) it emits `user-data`, `meta-data` and `network-config` with a small hand-written YAML emitter (every string double-quoted; no YAML library, C5) and runs `hdiutil makehybrid` to make the `cidata` ISO. `FeatureDocs` renders `docs/FEATURES.md` from the matrix, with a last column from the slow probes in `VMLAB_HOME/host-facts.json`. It depends on swift-log only.

**`VMLabQEMU`** (library). The QEMU backend: launching and supervising `qemu-system-aarch64`, the QMP
client, the GDB stub endpoint, and qcow2 internal snapshots. The serial channel itself is Core's
`SerialChannel`, shared with VZ.
`QEMUInstallation` finds the binaries and Homebrew's edk2 firmware (`<prefix>/share/qemu`).
`QEMULayout` names a guest's files in its VM directory (Appendix F) and refuses socket paths that do
not fit `sockaddr_un` (103 bytes), so tests use a short `/tmp/vmlab-test-*` home. `QEMUCommandLine`
builds the argument array from a `VMRecord`, `Plan` and `QEMULaunchOptions`: `virt` (arm64) or
`q35` (x86_64) with `hvf`/`host` or `tcg`/`max`, edk2 pflash code plus `efi-vars.bin`, a
`disk.qcow2` overlay and `seed.iso` on virtio-blk, user-mode virtio-net with loopback `hostfwd`s and
a MAC derived from the id, `ramfb` (a linear GOP framebuffer that cloud kernels without DRM keep
showing; `virtio-gpu-pci` went dark under Debian's cloud kernel), USB and virtio-input keyboard
and tablet, QMP/serial/VNC unix sockets, `-gdb` when granted, `-pidfile`, `-daemonize`, and always
`-S`. `BootSpec` picks the firmware arguments (R-305): `disk` edk2 pflash, `firmware` a custom pflash
image or `-bios` ROM, `kernel` `-kernel/-initrd/-append/-dtb` with no firmware, `binary`
`-device loader,...,cpu-num=0` with no firmware; `QEMUBackend` takes `VMRecord.boot`, fills a
missing kernel from the image (extracting it on first use) and attaches no disk to a kernel-only
image. `QMPClient` (an actor over a `QMPTransport`; `UnixQMPTransport` reads on its own thread) does
the greeting and `qmp_capabilities`, matches replies to `vmlab-<n>` ids (QMP errors become
`engine_error`, silence `timeout`, a closed socket `guest_unreachable`) and broadcasts events to
every `events()` stream; reconnecting is `connect(socketPath:)` again once the previous client has
gone (QEMU greets one client at a time). `QEMUMachine` prepares the overlay, EFI vars and seed,
daemonizes QEMU (output to `qemu.log`), connects QMP and the `SerialChannel` while the CPU is
halted, then sends `cont` unless `haltAtStart`; `attach` reconnects from the pid file, `powerdown`
sends `system_powerdown` and waits for the process to exit, `kill` sends `quit` then `SIGKILL`.
`QEMUBackend` is the `Backend` for `qemu-hvf` and `qemu-tcg`: it keeps a `QEMUMachine` per running
guest (reattaching after a server restart), builds the seed when R-400's `id_ed25519.pub` exists,
and hands out `QEMURunningVM` (serial, VNC display, GDB, QMP `query-*` introspection; exec and
checkpoints answer `guest_unreachable` until R-400 and R-307).

**`VMLabVZ`** (library). The Virtualization.framework backend, seen from the server; it never
imports Virtualization (`BoundariesTests`), which is loaded only in `vmlab-vz`. `ControlProtocol.swift`
is the control-socket codec both ends share: one JSON object per line, `ControlRequest` (`command`:
`status`, `pause`, `resume`, `stop` (the guest's `requestStop`), `kill`, `save`/`restore` with an
absolute `path`, `exit`) and `ControlResponse` (`ok`, `state` as `RunnerState`, `pid`, or an Appendix
D `error`), `ControlCodec` (refuses bad lines with `invalid_request`) and `LineBuffer` (64 KB line
cap). `UnixStream` holds the blocking unix-socket calls. `VZControlClient` opens one connection per
request (off the cooperative pool, per-command timeouts) and maps no answer to `guest_unreachable`
and a late one to `timeout`. `RunnerConfig.swift` has `VZRunnerPaths` (`<vm>/control.sock`,
`vz.pid`, `vz.log`, `vz-config.json`) and `VZRunnerConfig`, the plain machine description the
runner builds from (`linuxEFI(record:vmDirectory:)`: CPUs, memory, `efi-vars.bin`, `disk.raw`, NAT,
console to `console.log`; R-601 extends it). `VZRunnerLauncher` checks the runner's entitlement
(`host_missing_tool` with `signingHint`), writes the config and starts `vmlab-vz run <vm>` with
`Process` (own process group, stdin `/dev/null`, output appended to `vz.log`), then waits for
`status` to say `running` (or `stopped` with `hold`); a runner that dies first reports its error as
a `vmlab-vz-error: <json>` line in `vz.log`. `VMLabVZ.attach(socketPath:)` / `attach(runtime:)`
reconnect by socket path alone. `VZBackend` (profile `vz-linux`) conforms to Core's `Backend`:
create clones the pulled raw image to `<vm>/disk.raw`, start launches, stop/kill wait for the runner
to exit; `VZRunningVM` offers no serial, display or checkpoint channel yet (R-602, R-503, R-605).

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
Each tool of Appendix C is a `ToolSpec` (name, model-facing description, JSON Schema 2020-12
input as Core's `JSONValue`, documented output shape, the Appendix D codes it raises) in
`Tools/<Tool>Tool.swift`, built with the `Schema` helpers in `Tools/ToolSpec.swift`, which also
hold the shared `requirements` schema; `ToolCatalog.all` lists them in Appendix C order. `ToolDocs`
renders `docs/TOOLS.md` from the schemas. `Handlers/` is the behaviour the MCP server and the CLI share: a
`ToolHandler` (its `spec`, and `call(_: ToolArguments, context: ToolContext) async throws(VMLabError)
-> ToolResult`) per built tool, registered in `ToolHandlers.all`; `ToolHandlers.call(name,
arguments:context:)` checks the JSON arguments against the schema's top level (object, no unknown
field, required fields present; `ToolArguments` has typed accessors) and runs the handler, and
`ToolHandlers.specs` is what `tools/list` offers. `ToolContext` holds the `Store`, the `HostProbe`,
the `ResourceLimits`, the `BackendRegistry` with one `VMManager` over it, the `ImageStore` and the
`StartGating` gate of one `VMLAB_HOME`, plus the call's `progress` and `heartbeat` interval. A `ToolResult` is the Appendix C result object (always with
`warnings`) plus image blocks; `ToolRendering` turns results and `VMLabError`s into JSON (the MCP text)
or a terminal line. Built so far: `host_facts`, `host_doctor` (checks with `detail` and `fix`, the runner and its
entitlement, the probes with owner and date; `probe: true` runs `SlowProbeRunners.shared`),
`vm_plan` (an unsatisfiable request is a result with `satisfiable: false`, never an error),
`vm_list`, `vm_inspect` (the record, the creating `Plan` that `VMManager.create` stores in
`VMRecord.plan`, features, endpoints, the last 20 events, the latest `panic` event or null),
`vm_logs` (events rendered one per line, tails of `serial.log` and `provision.log`; `all` is each
source in turn, prefixed), `vm_create` (plan, pull the image if missing, `VMManager.create`, then
start unless `autostart: false`; all or nothing: a cancelled or failed call destroys the VM),
`vm_lifecycle` (start/stop/kill/pause/resume/reset/destroy; clone waits for R-803) and `images`
(list/pull/remove). Long calls (R-205) go through `Handlers/LongOperation.swift`: an image pull and
a start under `StartGate.withStart`, each wrapped in `ToolProgress.during`, which reports a step
when the work begins and a heartbeat every `ToolContext.heartbeat` (5 s) until it ends; a
cancelled task becomes `timeout` with `data.cancelled: true`. `VMLabMCP.version` is the package version.
`Server/MCPServer.swift` is the server (`VMLabServer.run(context:input:output:)`, used by
`vmlab serve`): it reconciles the store, then serves the SDK's `StdioTransport` until stdin closes.
`initialize` (server `vmlab`, the package version) and `ping` are the SDK's; `tools/list` sends
`ToolHandlers.specs`; `tools/call` runs `ToolHandlers.call` and answers `content: [text(JSON)]`
plus one `image` block per `ToolResult.images`, a `VMLabError` as `isError: true` with the
Appendix D object as the text, and an unknown tool as JSON-RPC error -32602. When the call carries
`_meta.progressToken`, `ToolContext.progress` (a `ToolProgress`) sends `notifications/progress`
with it; otherwise it is `.none`. `notifications/cancelled` is handled by the SDK, which cancels
the Swift task of the named request; the `tools/call` handler then throws `CancellationError`, so
no response is sent for it.

**`vmlab`** (executable). The CLI on swift-argument-parser: every MCP tool as a subcommand with
`--json` output, `vmlab serve` for the MCP server, `vmlab doctor`, and the hidden `vmlab gen-docs`
that `scripts/gen-docs.sh` uses. A tool subcommand conforms to `ToolCommand` (`Sources/vmlab/ToolCommand.swift`):
it turns its flags into the tool's JSON arguments and calls the same `ToolHandlers.call` as
`tools/call`, printing the result object with `--json` or a short human rendering; a `VMLabError` goes
to stderr (the Appendix D object with `--json`) with exit status 1; a long call's progress messages
go to stderr. Built: `facts`, `doctor`, `plan`, `create` (the `plan` flags plus `--name`,
`--no-start`), `list`, `inspect`, `logs`, `start`, `stop`, `kill`, `pause`, `resume`, `reset`,
`destroy`, `images pull|list|remove`, `serve`, `--version`. It bootstraps logging and hands off to Core and `VMLabMCP`.

**`VMLabEngines`** (library). The engine wiring, and the only module that imports both Core and the
backends for that purpose: `Engines.registerAll(store:into:)` registers `QEMUBackend` for `qemu-hvf`
and `qemu-tcg` and `VZBackend` for `vz-linux` in `Backends.shared` (or a given `BackendRegistry`).
`vmlab` calls it once in `main`, before any command runs, so `serve` and every tool subcommand can
create and start guests. `vz-macos` joins `Engines.profiles` when `VZBackend` runs macOS guests.
`BoundariesTests` checks that it imports only Core, QEMU and VZ and that no library imports it.

**`vmlab-vz`** (executable). The VZ runner: one process per Virtualization.framework guest, so a
guest outlives the server. `vmlab-vz run <vm-dir> [--hold]` writes `vz.pid`, builds the machine from
`vz-config.json` (`ConfigurationBuilder`: generic platform, `VZEFIBootLoader` with its variable
store, virtio-blk raw disks, NAT virtio-net, virtio console to a file, entropy; a missing entitlement
at `validate()` is `host_missing_tool`), owns the `VZVirtualMachine` on the main queue (`Runner`) and
serves `control.sock` (`ControlServer`: an accept thread and one thread per connection, each request
handed to the main queue). It ignores SIGHUP, treats SIGTERM/SIGINT as `exit`, logs `lifecycle`
events to `events.jsonl`, and once the guest has run and stops it removes its socket and pid file and
exits. It is the only binary that needs `com.apple.security.virtualization`; `scripts/sign.sh`
ad-hoc signs it with `Sources/vmlab-vz/vmlab-vz.entitlements` after every build.

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
