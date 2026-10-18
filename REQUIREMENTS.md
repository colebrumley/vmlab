# vmlab — Requirements Backlog

vmlab gives a language model virtual machines on an Apple Silicon Mac, over MCP, with every channel
a person at the keyboard has and several they do not: a screen to look at and click on, a shell, a
serial console, a debugger on the guest CPU, snapshots to undo with, and fleets on a private network.
The model asks for the features it needs; vmlab picks the engine (Apple's Virtualization.framework
or QEMU) that can provide them, or says exactly why none can.

This document is the single source of truth for an autonomous build loop. Every requirement has an
ID, a checkbox, acceptance criteria, and a **Verify** line that an agent can execute without human
input. The loop protocol lives in [CLAUDE.md](CLAUDE.md). The capability matrix lives in code
(`Sources/VMLabCore/Capabilities.swift`); `docs/FEATURES.md` is generated from it and records what
was verified on the development host.

Legend:
- `[ ]` not started, `[x]` done and verified, `[~]` in progress, `[!]` blocked (reason must follow)
- `[VERIFY]` marks a claim about an engine that was not confirmed when this backlog was written. The
  item that meets it runs the probe, records the answer in `docs/FEATURES.md`, and makes the matrix
  say what the probe found. Do not block on it; build the fallback the item names.

---

## 0. Scope and non-negotiable constraints

### Goals
- G1. **One MCP surface, two engines.** A model never names an engine. It states the guest it wants
  and the features it needs (Appendix A); vmlab chooses among the four profiles (Appendix B) or
  returns a structured, actionable refusal (Appendix D).
- G2. **Every channel a person has, and more.** Screen and input, shell, file transfer, serial
  console, GDB-level debugging, QEMU introspection, checkpoints, fleets on a private segment.
- G3. **Built for low-level work.** Direct kernel and initrd boot, custom firmware, a GDB stub, a
  serial console that works when the display stack is dead, and a checkpoint tree so a panicked
  guest costs seconds, not minutes.
- G4. **Built for macOS setup work.** macOS guests from prebuilt images, cloned in a second, with a
  baseline-and-diff tool that says what a setup script changed.
- G5. **Durable.** Guests outlive the MCP server process. State on disk is the truth; the server
  reconnects to running guests on start.
- G6. **Usable by hand.** Everything the MCP exposes is also a CLI subcommand with `--json` output,
  so a person can reproduce what the model did.

### Hard constraints
- C1. **Public APIs only.** No private Apple APIs or symbols (no `_VZVNCServer`, no private
  framebuffer access). Where Virtualization.framework offers no public path, the feature is absent
  from that profile and the matrix says so.
- C2. **No root, no entitlements beyond `com.apple.security.virtualization`.** Anything that needs
  root or Apple-granted entitlements (bridged networking, `vmnet` from QEMU) is a *conditional*
  feature detected at runtime (Appendix E), never a prerequisite.
- C3. **Module boundaries.** `VMLabCore` imports neither `Virtualization` nor anything QEMU-specific,
  nor the MCP SDK. Backends implement the `Backend` protocol defined in Core. The MCP layer and the
  CLI are thin adapters over Core. Enforced by a test that reads the import lines.
- C4. **Guest state is on disk and versioned.** Every VM directory carries `vm.json` with a
  `schemaVersion`; every released version loads every prior version.
- C5. **Stack is fixed.** Swift 6 (strict concurrency), SwiftPM, Swift Testing, `swift-format`
  (toolchain). Dependencies: `swift-argument-parser`, `swift-log`, and the official MCP Swift SDK
  (`modelcontextprotocol/swift-sdk`). Add others only if a requirement names them. Host tools via
  Homebrew: `qemu`, `cirruslabs/cli/tart`. Nothing else is assumed installed.
- C6. **Target host:** Apple Silicon, macOS 15 or newer. The development host is an M1 Max, 32 GB,
  macOS 26.6 (Appendix E lists what follows from that: no nested virtualization here).
- C7. **The matrix in code is the authority.** When this document and
  `Sources/VMLabCore/Capabilities.swift` disagree, the code wins; fix this document in the same commit.
- C8. **Model-facing errors are structured.** Every refusal carries a code from Appendix D, a one-line
  message, a `hint` saying what to change, and machine-readable `data`. Never a bare string.
- C9. **No network at runtime** except image pulls the user asked for, guest traffic, and nothing
  else. No telemetry.
- C10. **MCP tool names use `[a-z0-9_]` only**, so every client accepts them. Tools that share a
  target take an `action` enum rather than multiplying tool names (Appendix C).

### Out of scope for v1 (do not build, do not stub)
- Bridged networking, USB passthrough, audio, clipboard sync, GPU for QEMU guests, Intel hosts,
  Windows guests, macOS guests under QEMU, moving a VM between engines, more than one host, an
  HTTP transport for MCP (stdio only), authentication, an in-guest accessibility tree, an in-guest
  agent of our own for VZ guests (SSH and serial cover v1), a GUI app.

### Host facts at planning time (2026-10-17)
macOS 26.6.2, Apple M1 Max, 32 GB, Swift 6.3.2, Node 24, Go present, `gh` present. Neither
`qemu-system-aarch64` nor `tart` installed: R-000 installs them. Nested virtualization requires an
M3 or newer, so the `nested_virt` feature is absent on this host and its tests are skipped here.

---

## Phase 0 — Scaffold and loop infrastructure

- [!] **R-000 Repository and toolchain** — blocked (tart only): `brew install cirruslabs/cli/tart`
  fails on Homebrew 7.0.9 because the tap's formula (upstream HEAD, v1.0.0) uses the disabled
  `depends_on :macos => :ventura` form outside `on_macos`; the tap must be fixed upstream. Everything
  else, including `qemu` (11.1.2), is done.
  `git init`. `swift package init` as a library-plus-executables package named `vmlab`, platform
  `.macOS(.v15)`, Swift tools 6.0, strict concurrency. Targets as in R-001. `scripts/check.sh`:
  `swift format lint --recursive Sources Tests` (fail on findings), `swift build`, `swift test`
  (unit only), then `scripts/sign.sh` (R-003). `scripts/bootstrap.sh` installs `qemu` and
  `cirruslabs/cli/tart` with Homebrew if missing, and prints versions. `.gitignore` for `.build/`,
  `.swiftpm/`, `*.xcodeproj`, `.DS_Store`, `.claude/worktrees/`, `dist/`. A GitHub Actions workflow
  on `macos-15` running `scripts/check.sh` (unit tests only; VMs cannot run on hosted runners).
  **Verify:** `scripts/check.sh` exits 0 on a fresh clone with Xcode command-line tools only.
  `scripts/bootstrap.sh` leaves `qemu-system-aarch64 --version` and `tart --version` working.
  `git log` has an initial commit.

- [x] **R-001 Directory layout and module boundaries**
  ```
  Sources/VMLabCore/       features, profiles, selector, VM store, Backend protocol, errors (no engine imports)
  Sources/VMLabQEMU/       QEMU process, QMP, serial, GDB endpoint, qcow2 snapshots
  Sources/VMLabVZ/         Virtualization.framework runner client, Tart image integration
  Sources/VMLabRFB/        VNC (RFB) client: framebuffer to PNG, pointer and key events
  Sources/VMLabGDB/        GDB remote serial protocol client
  Sources/VMLabMCP/        MCP server: tool schemas, handlers, stdio transport
  Sources/vmlab/           CLI executable (ArgumentParser); `vmlab serve` runs the MCP server
  Sources/vmlab-vz/        VZ runner executable: one process per VZ guest, control socket (needs entitlement)
  Sources/vmlab-switch/    user-space Ethernet switch for private segments
  Tests/UnitTests/         Swift Testing, fast, no engines
  Tests/IntegrationTests/  need QEMU/Tart and pulled images; gated by VMLAB_INTEGRATION=1
  Tests/Fixtures/          vm.json fixtures per schema version, QMP transcripts, RFB captures, host-facts samples
  docs/                    ARCHITECTURE.md, FEATURES.md (generated), TOOLS.md (generated), AGENT.md, specs/
  scripts/                 check.sh, sign.sh, bootstrap.sh, board.mjs, tidy.mjs, review.mjs, gen-docs.sh
  ```
  **Verify:** `Tests/UnitTests/BoundariesTests.swift` reads every file under `Sources/VMLabCore`
  and asserts none imports `Virtualization`, `MCP`, `VMLabQEMU`, `VMLabVZ`, `VMLabRFB`, `VMLabGDB`;
  and that `Sources/VMLabMCP` and `Sources/vmlab` import no backend module directly (only Core and
  the `Backends` registry in Core). Test passes on the tree.

- [x] **R-002 Process scripts and skills**
  Adapt `scripts/board.mjs`, `scripts/tidy.mjs` and `scripts/review.mjs` from the owner's repository
  at `~/Documents/lib/new-world/scripts/` (same owner, same process), replacing the `npm run` names
  with `scripts/*.sh` and dropping the public-repo word guard. Copy and adapt the `plan`, `build`,
  `bughunt` and `retro` skills from `~/Documents/lib/new-world/.claude/skills/` to
  `.claude/skills/`, replacing `npm run check` with `scripts/check.sh` and the game vocabulary with
  this project's. `.claude/settings.json` with the `SessionStart` board hook and a `PreToolUse`
  hook that refuses `git commit`, `git switch`, `git stash` and `swift test` in the main checkout
  when `.claude/worktrees/` exists (the worktree rule in CLAUDE.md). `docs/specs/TEMPLATE.md`
  exists (written with this backlog).
  **Verify:** `node scripts/board.mjs` prints an empty board; `node scripts/board.mjs claim R-002 x`
  then `release R-002` round-trips; the hook script exits non-zero for `git commit` in the main
  checkout and zero inside `.claude/worktrees/x`.

- [x] **R-003 Code signing for the VZ runner**
  `Sources/vmlab-vz/vmlab-vz.entitlements` with `com.apple.security.virtualization` only.
  `scripts/sign.sh` ad-hoc signs `.build/<config>/vmlab-vz` with that entitlements file after every
  build (called by `check.sh` and by `swift build` wrappers in `scripts/build.sh`). `vmlab doctor`
  (R-203) reports whether the runner binary carries the entitlement (`codesign -d --entitlements -`).
  **Verify:** after `scripts/build.sh`, `codesign -d --entitlements - .build/debug/vmlab-vz` lists
  `com.apple.security.virtualization`; a unit test parses that output format from a fixture.

- [x] **R-004 Logging and the event log**
  `swift-log` throughout. Every VM directory has `events.jsonl`: one JSON object per line with
  `ts`, `level`, `kind` (lifecycle, serial, checkpoint, net, error, panic) and `message`. Core writes
  it; backends append through Core. Log level from `VMLAB_LOG` (default `info`); server logs to
  stderr only (stdout is the MCP transport).
  **Verify:** unit test: 100 appended events round-trip through the reader; a malformed line is
  skipped with a warning, not a crash.

- [x] **R-005 Architecture and docs scaffold**
  `docs/ARCHITECTURE.md` with one paragraph per target from R-001. `docs/AGENT.md` placeholder (filled
  by R-1104). `scripts/gen-docs.sh` regenerates `docs/FEATURES.md` from the matrix (R-102) and
  `docs/TOOLS.md` from the tool schemas (R-202); `check.sh` fails if the generated files are stale.
  **Verify:** `scripts/gen-docs.sh && git diff --exit-code docs/FEATURES.md docs/TOOLS.md` exits 0
  after a build.

---

## Phase 1 — Core model: features, profiles, selection, store

- [x] **R-100 Feature catalogue**
  `Sources/VMLabCore/Features.swift`: `enum Feature: String, CaseIterable, Codable` with every row
  of Appendix A, each with a one-line `summary` and a `kind` (`channel`, `boot`, `state`, `net`,
  `compute`). `GuestSpec { os: macos|linux, arch: arm64|x86_64|riscv64|other(String) }`.
  `Requirements { guest, require: [Feature], prefer: [Feature], resources, network: NetworkSpec,
  image: String?, boot: BootSpec? }` (Appendix C `vm_create` input). Contradictions inside a request
  are rejected at decode time with `invalid_request` (Appendix D): macOS with `direct_kernel_boot`
  or `custom_firmware` or `serial`; `rosetta` with a non-Linux guest or non-arm64 arch;
  `net_none` with `net_nat`, `net_fast`, `net_port_forward` or `net_segment`.
  **Verify:** snapshot test of the catalogue; a table-driven test of every contradiction above and
  of ten valid requests that decode.

- [x] **R-101 Profiles and host facts**
  `enum Profile: String { vzMacOS = "vz-macos", vzLinux = "vz-linux", qemuHVF = "qemu-hvf",
  qemuTCG = "qemu-tcg" }` with `performanceTier`, `energyTier`, `startupTier` (Appendix B).
  `HostFacts` (Appendix E) as a Codable struct, gathered by `HostProbe` (fast, every server start:
  OS version, chip, memory, free disk, tool presence and versions, root, Rosetta, entitlement on the
  runner, running macOS guest count) plus persisted slow probes in `~/.vmlab/host-facts.json`
  (`qemu_hvf_live_snapshot`, `qemu_hvf_gdb`, `vz_linux_live_snapshot`, `vz_macos_live_snapshot`,
  `qemu_vmnet`), each `unknown | yes | no` with the date probed. Unknown counts as `no` for
  selection and is reported as `unverified` in `vm_plan` output.
  **Verify:** `HostProbe` parses fixture outputs of `sw_vers`, `sysctl`, `qemu-system-aarch64
  -accel help`, `tart --version`, `codesign -d`; a fixture `host-facts.json` round-trips; an
  `unknown` probe makes the dependent feature unavailable in the matrix.

- [x] **R-102 Capability matrix**
  `Sources/VMLabCore/Capabilities.swift`: `func capabilities(of: Profile, host: HostFacts) ->
  [Feature: Availability]` where `Availability` is `.yes`, `.no(reason)`, or `.conditional(reason)`
  resolved to yes/no by host facts. Exactly Appendix B, including every condition. `docs/FEATURES.md`
  is generated from it by `scripts/gen-docs.sh` as a table with a column per profile and a final
  column "verified on dev host" filled from `host-facts.json`.
  **Verify:** snapshot test of the matrix against a fixture host (M1, no root, all probes `yes`) and
  against the same host with all probes `unknown`; one assertion per row of Appendix B that the
  code agrees with the document (table-driven from a copy of the table in the test file).

- [x] **R-103 Selector**
  `Sources/VMLabCore/Selector.swift`: `func select(_ r: Requirements, host: HostFacts, running:
  Inventory) -> Result<Plan, Unsatisfiable>` implementing Appendix I exactly: normalise, filter
  profiles by guest OS and arch, filter by every `require` feature recording which profiles each
  eliminated, dynamic limits (macOS guest count, memory budget), rank survivors by `prefer`
  coverage then performance, energy, startup tiers, ties to VZ. `Plan` carries the profile, the
  resolved feature set, the preferred features it could not honour, and `unverified` features.
  `Unsatisfiable` carries per-feature eliminations and `suggestions`: the smallest subsets of
  `require` whose removal makes some profile satisfiable (smallest subsets first, up to size 3, at most
  five suggestions), each with the profile it would yield.
  **Verify:** every worked example in Appendix I is a unit test with the exact expected profile or
  the exact expected suggestions; a property test over 500 random requirement sets asserts a
  returned plan satisfies every required feature and the dynamic limits.

- [x] **R-104 VM store and `vm.json`**
  `VMLAB_HOME` (default `~/.vmlab`) with the layout of Appendix F. `VMRecord` (`schemaVersion`,
  `id`, `name`, `profile`, `guest`, `features`, `resources`, `image`, `network`, `createdAt`,
  `state: created|running|paused|stopped|suspended|broken`, `runtime: { pid, controlSocket,
  qmpSocket?, serialSocket?, vncSocket?, gdbEndpoint?, sshPort?, ip? }`, `checkpoints`). `Store`
  lists, loads, saves atomically (write temp, rename), and migrates older `schemaVersion`s through
  a registry. IDs are `vm-` plus six lowercase base32 characters; names are unique, default to the
  ID. A per-VM `flock` guards concurrent writers from two server processes.
  **Verify:** unit tests: round-trip; a fixture at each released schema version loads; two
  concurrent saves from two processes (spawned test helper) never corrupt the file.

- [x] **R-105 Backend protocol and registry**
  `protocol Backend { var profile: Profile; func create(_: VMRecord, plan: Plan) async throws;
  func start/stop/kill/pause/resume/destroy; func attach(_: VMRecord) async throws -> RunningVM }`
  and `protocol RunningVM` exposing optional channel handles: `serial: SerialChannel?`, `display:
  DisplayEndpoint?` (a VNC socket path plus auth), `gdb: GDBEndpoint?`, `introspection:
  Introspection?`, `exec: ExecChannel` (SSH or agent), `checkpoints: CheckpointProvider`. Core never
  calls a channel the plan did not grant: `RunningVM.channel(_:)` throws `capability_missing` with
  the feature name and the `vm_plan` hint. `Backends.register(_:)` is how `vmlab` wires the
  engines at startup; Core holds only the protocol.
  **Verify:** a `FakeBackend` in `Tests/UnitTests/Support` drives a full lifecycle through Core;
  requesting a channel absent from the plan throws `capability_missing` with the right feature.

- [x] **R-106 Lifecycle state machine and reattach**
  Transitions: created→running (start), running→paused→running, running→stopped (stop: ACPI or
  guest shutdown with a 60 s grace, then kill), any→destroyed, running→suspended (live checkpoint
  with stop). Illegal transitions throw `wrong_state` naming the current state and the legal
  actions. On server start, `Store.reconcile()` checks every record's `runtime.pid`: alive and
  socket answering → `running`; dead → `stopped` (or `broken` if the disk image is missing) with an
  event logged.
  **Verify:** table-driven unit test over every (state, action) pair; a reconcile test with a fixture
  directory whose pid is a finished process marks it `stopped` and logs the event.

- [x] **R-107 Memory and concurrency budgets**
  Before start: sum of memory of running guests plus this one must leave `reserveGB` (Appendix G,
  default 4) free of physical memory, else `limit_memory` with the numbers. Running macOS guests
  must stay under 2, else `limit_macos_guests`. A global `StartGate` limits concurrent starts to
  `parallelStarts` (default 4).
  **Verify:** unit tests with fixture inventories for both limits and the gate.

---

## Phase 2 — MCP server and CLI skeleton

- [x] **R-200 CLI executable**
  `vmlab` with ArgumentParser: `serve`, `doctor`, `facts`, `images`, `plan`, `create`, `list`,
  `inspect`, `start`, `stop`, `kill`, `pause`, `resume`, `destroy`, `clone`, `exec`, `file`,
  `computer`, `serial`, `debug`, `introspect`, `checkpoint`, `manifest`, `logs`, `segment`, `fleet`.
  Each mirrors the MCP tool of the same name (Appendix C) and shares its handler in `VMLabMCP`;
  `--json` prints the tool's result object, otherwise a short human rendering. `vmlab --version`.
  Subcommands that are built later register as they land; this item ships the frame plus `facts`,
  `doctor`, `plan`, `list`, `inspect`.
  **Verify:** `vmlab facts --json` prints valid JSON matching `HostFacts`; `vmlab plan --guest
  linux --require serial,gdb --json` prints a `Plan` or an `Unsatisfiable`; unit test for the
  argument parsing of `plan`.

- [x] **R-201 MCP server over stdio**
  `vmlab serve` runs an MCP server with the official Swift SDK: `initialize`, `tools/list`,
  `tools/call`, `ping`, and `notifications/progress` for long calls (create, pull, checkpoint
  restore). Tool results are `content: [text(JSON)]`, plus an `image` content block for
  screenshots. Every thrown `VMLabError` becomes `isError: true` with the Appendix D object as the
  text. Server name `vmlab`, version from the package. Logs go to stderr. If the SDK does not build
  with the pinned toolchain, implement JSON-RPC 2.0 over stdio by hand for exactly those methods
  (the protocol is small) and say so in the commit.
  **Verify:** an integration-free unit test speaks JSON-RPC to the server over pipes: `initialize`,
  `tools/list` returns every tool in Appendix C that is built so far, `tools/call host_facts`
  returns facts, an unknown tool returns a JSON-RPC error. Manual: Claude Code with
  `claude mcp add vmlab -- /path/to/vmlab serve` lists the tools.

- [x] **R-202 Tool schemas and generated reference**
  Every tool in Appendix C has a JSON Schema input and a documented output shape in
  `Sources/VMLabMCP/Tools/*.swift`, one file per tool, with `description` text written for a model
  (what it does, when to use it, what it returns, the errors it can raise). `scripts/gen-docs.sh`
  writes `docs/TOOLS.md` from the schemas.
  **Verify:** unit test: every schema is valid JSON Schema draft 2020-12 (structural checks: `type`,
  `properties`, `required` subset of properties, enums non-empty), every tool name matches
  `^[a-z0-9_]{1,40}$`, every description is 40–1200 characters.

- [x] **R-203 `host_doctor`**
  `vmlab doctor` (and the tool): runs the fast probes, reports each prerequisite as ok/missing with
  the fix (`brew install qemu`, `brew install cirruslabs/cli/tart`, `softwareupdate
  --install-rosetta`, the signing step), reports the entitlement on `vmlab-vz`, free memory and
  disk, running guest counts, and the persisted slow-probe results with dates. `--probe` runs the
  slow probes (each boots a throwaway minimal guest; built by the items that own the feature:
  R-307, R-608, R-702) and persists them.
  **Verify:** `vmlab doctor --json` on the dev host lists every prerequisite; a unit test renders a
  fixture report with one missing tool and shows its fix line.

- [ ] **R-204 `vm_plan`, `vm_list`, `vm_inspect` on the server**
  Wire R-103, R-104 to the tools. `vm_inspect` returns the record, the runtime endpoints, the
  resolved features (so a model can rediscover what a VM has after a context reset), and the last
  20 events. `vm_plan` returns the plan or the unsatisfiable object
  with suggestions, never an error.
  **Verify:** JSON-RPC test over pipes with the fake backend: `vm_plan` for an impossible request
  returns suggestions; `vm_list` lists a fixture VM.

- [ ] **R-205 Long operations and cancellation**
  Calls that may exceed 10 s (`vm_create` with a pull, `vm_lifecycle start`, `vm_checkpoint restore`,
  `images pull`, `fleet create`) send progress notifications at least every 5 s and honour MCP
  cancellation by cancelling the Swift task; a cancelled create destroys what it made.
  **Verify:** unit test with the fake backend: a slow create emits progress, and cancellation
  leaves no VM directory.

---

## Phase 3 — QEMU backend

- [x] **R-300 Linux cloud image catalogue and pull**
  `Sources/VMLabCore/Images.swift`: the catalogue of Appendix H (name, guest, arch, URL, format,
  sha512 URL, login). `images pull <name>` downloads to `~/.vmlab/images/<name>/`, verifies the
  checksum, converts qcow2→raw with `qemu-img` when a raw file is also wanted (VZ needs raw; R-603),
  and records `image.json`. `images list` shows pulled and available. `images remove`.
  Re-pull is a no-op when the checksum matches.
  **Verify:** unit test for catalogue decoding and checksum verification against a fixture;
  integration (`VMLAB_INTEGRATION=1`): `vmlab images pull debian-13-arm64` succeeds and a second
  pull is a no-op.

- [x] **R-301 Cloud-init seed**
  `Sources/VMLabCore/CloudInit.swift` builds a NoCloud seed ISO with `hdiutil makehybrid -iso
  -joliet -default-volume-name cidata` from `user-data` and `meta-data`: hostname, the VM's SSH
  public key for the image's default user, password login off, `qemu-guest-agent` installed and
  enabled, serial console on, optional packages (GUI VNC stack, R-504), static addressing for a
  segment NIC (R-901), and optional user-supplied `user-data` merged last. Used by both engines.
  **Verify:** unit test: the generated `user-data` is valid YAML with the expected keys; the ISO is
  produced and `hdiutil` lists `user-data` and `meta-data` inside.

- [ ] **R-302 QEMU process and QMP client**
  `VMLabQEMU`: builds the command line from a `VMRecord` and `Plan` (Appendix G for defaults):
  `-machine virt -accel hvf` for `qemu-hvf`, `-accel tcg` for `qemu-tcg`, `-cpu host|max`, UEFI from
  Homebrew's edk2 for installed-disk boot, virtio-blk disks, virtio-net, `-qmp
  unix:<vm>/qmp.sock,server,nowait`, `-serial unix:<vm>/serial.sock,server,nowait`, `-vnc
  unix:<vm>/vnc.sock`, `-gdb tcp:127.0.0.1:<port>` when `gdb` is granted, `-device virtio-gpu-pci` (the framebuffer the VNC server shows, from firmware on),
  `-device qemu-xhci -device usb-kbd -device usb-tablet` (an absolute pointer, so VNC clicks land
  where the screenshot says), `-pidfile`, `-daemonize` with `-display none`, and always `-S`: Core
  connects QMP and the serial socket first, then sends `cont` (or leaves the CPU halted when
  `boot.haltAtStart` is set, R-703), so the serial log starts at the first byte. The QMP client speaks the capabilities handshake, commands with ids,
  events (as an `AsyncStream`), and reconnects to a running guest by socket path.
  **Verify:** unit tests of the command line for each profile from fixture records (snapshot), and
  of the QMP client against a fixture transcript (greeting, `query-status`, `SHUTDOWN` event);
  integration: boot `debian-13-arm64` under `qemu-hvf`, `query-status` says `running`, stop via
  `system_powerdown` finishes within 60 s.

- [x] **R-303 Serial channel**
  `SerialChannel` over the serial unix socket: a background reader appends to `<vm>/serial.log`
  (never truncated during a run; rotated to `serial.log.1` at 64 MB) and a 4 MB ring with byte
  offsets. `read(since: offset|tail: n)`, `write(text)`, `wait(regex, timeout)` returning the match
  and the offset after it. Boot output from the first byte is captured because R-302 opens the socket
  before `cont` releases the CPU.
  **Verify:** unit test against a fake socket: offsets, tail, wait with timeout; integration: the
  Debian boot log contains `login:` within 90 s via `wait`.

- [ ] **R-304 Panic and crash detection**
  The serial reader matches a small table (`Kernel panic - not syncing`, `BUG:`, `Oops:`, `general
  protection fault`, `Synchronous Exception`, `rcu: INFO: rcu_sched self-detected stall`) and logs a
  `panic` event with the matched line and offset; `vm_inspect` surfaces the latest. QMP `GUEST_PANICKED`
  and `RESET` events are logged as well.
  **Verify:** unit test feeds a panic transcript and asserts the event; a `vm_logs` call lists it.

- [ ] **R-305 Direct kernel boot and custom firmware**
  `BootSpec`: `.disk` (default), `.kernel(kernel, initrd?, cmdline, dtb?)` → `-kernel/-initrd/-append`,
  `.firmware(path, format: pflash|bios)` → `-pflash` or `-bios`, `.binary(path, loadAddress)` →
  `-device loader,file=...,addr=...` with `-nographic`-equivalent flags. Kernel paths are
  registered through `images register <name> --kernel <path> [--initrd <path>]` into
  `~/.vmlab/images/<name>/`. `images extract-kernel <image>` copies the kernel, initrd,
  `System.map` and kernel `config` out of a pulled Linux image into `images/<image>/kernel/`.
  **Verify:** command-line snapshot tests for each mode; integration: boot the Debian cloud
  kernel and initrd extracted from the pulled image (`images extract-kernel debian-13-arm64`) with
  `console=ttyAMA0 root=/dev/vda1` and reach `login:` on serial.

- [ ] **R-306 Custom devices**
  `Requirements.extra.qemuArgs: [String]` is passed through verbatim for the `custom_devices`
  feature, after vmlab's own arguments, with a denylist (`-qmp`, `-serial`, `-vnc`, `-gdb`,
  `-pidfile`, `-daemonize`, `-monitor`) that raises `invalid_request`.
  **Verify:** unit tests for pass-through and the denylist.

- [ ] **R-307 qcow2 checkpoints and the live-snapshot probe**
  `CheckpointProvider` for QEMU: disk checkpoints on a stopped guest via `qemu-img snapshot -c`;
  on a running guest via QMP `snapshot-save` (memory and disk) when the host fact
  `qemu_hvf_live_snapshot` is `yes`, else `wrong_state` with the hint to stop first. The slow probe
  (`doctor --probe`): boot a tiny guest under HVF, `snapshot-save`, `snapshot-load`, confirm the
  guest resumes (serial responds) [VERIFY]; record the answer. Under TCG live snapshots are always
  on. Restore: `qemu-img snapshot -a` (stopped) or `snapshot-load` (live). Delete: `snapshot -d`.
  **Verify:** integration: stopped checkpoint, write a file in the guest, restore, file gone; the
  probe runs and writes `host-facts.json`; if it says `yes`, a live checkpoint and restore keep an
  SSH session's shell history.

- [ ] **R-308 User-mode networking and port forwarding**
  Default NIC `-netdev user` with `hostfwd` for SSH (an ephemeral localhost port recorded in
  `runtime.sshPort`) and for every `net_port_forward` entry in the request (`guest:host` pairs,
  host port 0 for ephemeral; the result records the chosen ports). `net_none` omits the NIC.
  **Verify:** command-line snapshot; integration: `ssh -p <port>` reaches the Debian guest with the
  generated key.

- [ ] **R-309 vmnet fast networking (conditional)**
  When running as root or `qemu_vmnet` probes `yes`, `net_fast` uses `-netdev vmnet-shared`. The
  probe tries `vmnet-shared` on a throwaway guest and records the answer; everywhere else the
  feature is `.no("needs root or an entitlement")`.
  **Verify:** command-line snapshot for both cases; the matrix row flips with the fact.

- [ ] **R-310 TCG profile for x86_64 and other architectures**
  `qemu-tcg` selects `qemu-system-x86_64` (`-machine q35`, `-cpu max`, edk2 x86 firmware) or
  `qemu-system-<arch>` for `riscv64` (`-machine virt`) and `other(String)` with no defaults beyond
  `-machine virt` and a warning in the plan. TCG profile applies `-smp` up to 8 and warns in the
  plan about speed.
  **Verify:** command-line snapshot per arch; integration: boot `debian-13-amd64` under TCG to
  `login:` on serial within 10 minutes (this is slow; the test is tagged `slow`).

- [ ] **R-311 Memory dump and QMP introspection**
  `Introspection` for QEMU: `status`, `block` (`query-block`), `pci` (`query-pci`), `cpus`
  (`query-cpus-fast`), `memory_tree` (`human-monitor-command info mtree`), `registers` (`info
  registers -a`), `devices` (`info qtree`), and `raw` for an allowlist of read-only QMP commands
  (`query-*`) and HMP `info *`; anything else raises `invalid_request`. `vm_memory_dump` uses
  `pmemsave` for a range and `dump-guest-memory` (ELF) for everything, to a path under `<vm>/dumps/`,
  returning the path and size; a range over 256 MB needs `confirm: true`.
  **Verify:** QMP transcript tests; integration: `pci` lists the virtio devices, `pmemsave` of 1 MB
  produces a file of that size.

---

## Phase 4 — Shell and files

- [ ] **R-400 SSH keys and known hosts**
  `vm_create` generates `<vm>/id_ed25519` (`ssh-keygen -t ed25519 -N ""`), injects the public key
  (cloud-init for Linux; R-606 for macOS). `ExecChannel.ssh` runs the system `ssh` with `-i`, `-o
  BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=<vm>/known_hosts`, the
  recorded port or IP, and the image's user. Readiness: `vm_lifecycle start` waits until an SSH
  `true` succeeds or the boot timeout (Appendix G) passes, then marks `running`; a guest that never
  answers stays `running` with a `ssh_unreachable` warning in the result.
  **Verify:** unit test of the argument vector; integration: `vm_exec "uname -a"` on Debian returns
  the kernel line with exit 0.

- [ ] **R-401 `vm_exec`**
  Runs a command with `timeout` (default 120 s), optional `cwd`, `env`, `stdin`, `user` (sudo when
  not the login user), `via: auto|ssh|agent`. Returns `exitCode`, `stdout`, `stderr`, `durationMs`,
  `truncated`. Output over 64 KB keeps the head 16 KB and tail 48 KB and sets `truncated` with the
  full text saved under `<vm>/exec/<job>.log` and the path returned. A timeout kills the remote
  process group and returns `timeout` with partial output.
  **Verify:** integration on Debian: exit codes, stderr separation, a 200 KB output is truncated
  with the log path present, `sleep 300` with `timeout: 2` returns within 5 s.

- [ ] **R-402 Background jobs**
  `vm_exec` with `background: true` returns a job id at once; the remote runs under `nohup` with
  output to `<vm>/exec/<job>.log` streamed back by a reader. `vm_job read` returns new output since
  the last read and whether it finished; `wait(timeout)`; `kill`. Jobs survive a server restart
  (the log keeps streaming through a fresh `ssh tail -f`).
  **Verify:** integration: a background `for i in $(seq 1 5); do echo $i; sleep 1; done` is read
  incrementally and finishes with exit 0.

- [ ] **R-403 Agent exec for QEMU guests**
  `via: agent` uses `qemu-guest-agent` through QMP (`guest-exec`, `guest-exec-status`, polling)
  when `exec_agent` was granted; it works with no guest networking and before SSH is up. `auto`
  prefers SSH when reachable, else the agent.
  **Verify:** integration: with `net_none`, `vm_exec "id"` via agent returns `uid=0`.

- [ ] **R-404 File push, pull and shared directories**
  `vm_file push|pull` via `scp` (or `sftp` batch) with size reporting; directories recursively;
  `pull` to `<vm>/pulled/` when no local path is given. `shared_dir` grants mount a host directory
  read-write at a guest path: QEMU via 9p (`-virtfs local,...`, mounted by cloud-init `mounts`),
  VZ via virtiofs (R-603).
  **Verify:** integration: push a 5 MB file, pull it back, bytes equal; a shared directory shows a
  host-written file inside the guest within 2 s.

---

## Phase 5 — GUI channel

- [x] **R-500 RFB client: handshake and framebuffer**
  `VMLabRFB`: RFB 3.8 over a unix or TCP socket; security types None and VNC Authentication (DES
  challenge); `ClientInit` shared; encodings requested: Raw, CopyRect, DesktopSize; pixel format
  negotiated to 32-bit BGRX; an incremental `FramebufferUpdateRequest` loop keeps a `Framebuffer`
  current; `snapshot() -> CGImage`. Handles `DesktopSize` changes and server-side resize.
  **Verify:** unit tests against recorded fixture streams (`Tests/Fixtures/rfb/*.bin`) decode the
  expected image hash; integration: connect to the Debian guest's QEMU VNC socket during boot and
  get a non-blank image.

- [x] **R-501 RFB client: input**
  `pointer(x, y, buttons)`, `key(keysym, down)`, a US keysym table for printable ASCII and the
  named keys of Appendix C (`Return`, `Tab`, `Escape`, arrows, function keys, modifiers, `cmd` on
  macOS guests mapped to `Super_L`), and `type(text)` that sends press/release per character with
  shift handling and a 10 ms gap. Chords like `cmd+shift+4` and `ctrl+alt+Delete`.
  **Verify:** unit test: the byte sequences for a chord and for typing `Hello, World!`; integration:
  on the Debian guest's tty1 login prompt shown by QEMU's VNC, type `debian` + Return; the next
  screenshot shows `Password:` (the image differs from the previous one in the prompt region).

- [ ] **R-502 `vm_computer`**
  The tool of Appendix C with the computer-use action set: `screenshot` (PNG, scaled so the long
  edge ≤ `maxEdge`, default 1280, with the scale factor returned; coordinates in every other
  action are in the unscaled guest pixel space unless `scaled: true`), `left_click`, `right_click`,
  `middle_click`, `double_click`, `triple_click`, `left_click_drag`, `mouse_move`,
  `cursor_position`, `type`, `key`, `scroll`, `wait`, `zoom` (region crop at full resolution),
  `screen_info`. Every action except `screenshot`, `zoom`, `screen_info` and `cursor_position`
  returns a fresh screenshot after a `settleMs` delay (default 300).
  **Verify:** unit tests for coordinate scaling and action dispatch against a fake RFB connection;
  integration on Debian with the GUI image (R-504): click the terminal icon, type a command, the
  screenshot contains new pixels in the terminal region.

- [ ] **R-503 Display endpoint per profile**
  QEMU: the built-in VNC socket, always present, works from the first firmware frame (`gui_preboot`).
  VZ Linux: an in-guest VNC server on the NAT address, port 5900, password from `<vm>/vnc.pass`,
  provisioned by R-504 when `gui` was granted; absent otherwise. VZ macOS: the guest's Screen
  Sharing with legacy VNC password (R-606). `DisplayEndpoint` says which and whether the display
  survives a guest display-stack crash (`hostSide: Bool`), surfaced in `vm_inspect`.
  **Verify:** unit test that the endpoint is absent when `gui` was not required; integration for
  each profile in its own phase (R-502, R-607, R-608).

- [ ] **R-504 GUI-enabled Linux provisioning**
  When `gui` is required for a Linux guest, cloud-init installs a minimal desktop (Debian:
  `xfce4`, `lightdm` with autologin, `tigervnc-scraping-server` or `x11vnc` bound to the NIC with
  the password file) and enables it; the Plan's `startupTier` worsens by one and `vm_plan` reports
  the extra install time. Not applied for QEMU guests unless `gui_desktop` is also required
  (QEMU's VNC shows the console without any desktop).
  **Verify:** integration: a `qemu-hvf` Debian guest with `gui_desktop` shows a desktop in a
  screenshot within 10 minutes of first boot and within 90 s of a second boot. The VZ case is
  verified by R-601.

- [x] **R-505 Screenshot economy**
  `screenshot` supports `format: png|jpeg` (default png), `quality`, `maxEdge`, `region`, and
  `diffFrom: <screenshotId>`: the server keeps the last 20 screenshots per VM and, with `diffFrom`,
  returns only the bounding box that changed plus its offset, or `unchanged: true`. Every
  screenshot result has an `id`, the guest `width`/`height`, and the `scale` used.
  **Verify:** unit tests on synthetic framebuffers for bounding boxes and `unchanged`.

---

## Phase 6 — Virtualization.framework backend

- [ ] **R-600 `vmlab-vz` runner process and control socket**
  One `vmlab-vz` process per VZ guest, started detached by `VMLabVZ`, with `<vm>/control.sock`
  speaking newline-delimited JSON: `status`, `pause`, `resume`, `stop` (ACPI/guest request via
  `requestStop`), `kill`, `save(path)`, `restore(path)`, `exit`. It writes `<vm>/vz.pid`, logs to
  `<vm>/vz.log`, and keeps running after the MCP server exits. `VMLabVZ.attach` reconnects by
  socket path. The runner is signed by R-003; a missing entitlement is reported as
  `host_missing_tool` with the signing hint.
  **Verify:** unit test of the protocol codec; integration: start a Linux guest, kill the MCP server
  process, start it again, `vm_list` shows the guest `running` and `pause` works.

- [ ] **R-601 VZ Linux guest configuration**
  `VZVirtualMachineConfiguration` from a `VMRecord`: CPUs, memory, `VZEFIBootLoader` with a per-VM
  variable store for `.disk` boot or `VZLinuxBootLoader` for `.kernel` (R-604), virtio-blk raw
  disk, cloud-init seed as a second virtio-blk device, `VZNATNetworkDeviceAttachment` with a stable
  MAC, virtio-rng, virtio-balloon, `VZVirtioConsoleDeviceSerialPortConfiguration` with pipes to the
  runner (R-602), `VZVirtioEntropyDevice`, and `VZVirtioGraphicsDevice` only when `gui` was granted.
  The guest IP is read from the vmnet DHCP lease file (`/var/db/dhcpd_leases`) by MAC and recorded
  as `runtime.ip`.
  **Verify:** unit test of the configuration builder's decisions (serialised to a plain struct for
  snapshotting); integration: boot `debian-13-arm64` (raw) to `login:` on serial within 60 s and
  SSH to the leased IP; with `gui` required, a screenshot through the in-guest VNC server (R-504
  provisioning) shows a desktop.

- [ ] **R-602 Serial on VZ Linux**
  The runner bridges the console pipes to `<vm>/serial.sock` with the same wire behaviour as
  R-303 so `SerialChannel` is shared; cloud-init sets `console=hvc0` and a getty on it.
  **Verify:** integration: `vm_serial wait "login:"`, `write "root\n"`, and the prompt appears.

- [ ] **R-603 virtiofs shares and Rosetta**
  `shared_dir` → `VZVirtioFileSystemDeviceConfiguration` with tag `share0`, mounted by cloud-init.
  `rosetta` → `VZLinuxRosettaDirectoryShare` (host fact `rosetta_installed` must be `yes`, else
  the feature is `.no("softwareupdate --install-rosetta")`) plus the binfmt registration lines in
  cloud-init.
  **Verify:** integration: a host file appears in the guest; an `x86_64` static `hello` binary
  (fixture) runs in the arm64 guest and prints its greeting.

- [ ] **R-604 Direct kernel boot on VZ Linux**
  `.kernel(kernel, initrd?, cmdline)` → `VZLinuxBootLoader` (uncompressed arm64 `Image`; a gzip
  kernel is decompressed on registration). `custom_firmware` and `custom_devices` stay `.no` with
  the reason "Virtualization.framework boots only Apple EFI or a Linux kernel".
  **Verify:** integration: the extracted Debian kernel boots to `login:` on serial.

- [ ] **R-605 Tart images for macOS**
  `images pull macos-base` runs `tart pull <ref>` for the catalogue ref (Appendix H) and records the
  Tart VM name. `vm_create` for `vz-macos` runs `tart clone <base> <vm-id>` (an APFS clone, seconds)
  and reads the clone's directory (`~/.tart/vms/<id>/`: `config.json`, `disk.img`, `nvram.bin`) to
  build a `VZMacPlatformConfiguration` (hardware model and machine identifier from `config.json`,
  auxiliary storage `nvram.bin`) and `VZMacOSBootLoader` in our runner. If the pinned Tart
  version's layout cannot be read, fall back to running the guest with `tart run --no-graphics`
  and say so in the commit and `docs/FEATURES.md` (pause and live checkpoints then come from `tart
  suspend`, one at a time).
  **Verify:** unit test parses a fixture `config.json`; integration: a cloned macOS guest boots,
  `tart ip`-equivalent lease lookup finds it, and `ssh admin@<ip>` with the image password works.

- [ ] **R-606 macOS guest provisioning**
  First boot of a macOS guest runs over SSH with the image's password: install the VM's public key
  in `~/.ssh/authorized_keys`, set the hostname, confirm Screen Sharing is on and set the legacy VNC
  password (`/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart
  -configure -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw <pass>`) when `gui` was granted, write `<vm>/provisioned`. Password auth stays enabled (the
  images are disposable).
  **Verify:** integration: after create, `vm_exec "sw_vers"` works with the key and a screenshot
  through the guest's VNC is non-blank.

- [ ] **R-607 GUI on macOS guests**
  `DisplayEndpoint` for `vz-macos` is the guest's Screen Sharing (`hostSide: false`), RFB security
  type VNC with the password from R-606. `vm_computer` works end to end; `key` maps `cmd` to
  `Super_L` and the result notes that.
  **Verify:** integration: `key cmd+space`, `type "Terminal"`, `key Return`, screenshot contains a
  new window (bounding-box diff non-empty).

- [ ] **R-608 Save and restore on VZ (live checkpoints)**
  Runner `save(path)`: pause, `saveMachineStateTo`, APFS-clone the disk (`clonefile(2)`) and the
  auxiliary storage beside it; `restore(path)`: `restoreMachineStateFrom` on a configuration built
  from the checkpoint's clones. `CheckpointProvider` for VZ: `disk` mode clones the disk of a
  stopped guest; `live` mode uses save/restore. The slow probes `vz_linux_live_snapshot` and
  `vz_macos_live_snapshot` try one save and restore each on a throwaway guest [VERIFY]; a `no`
  turns `checkpoint_live` off for that profile with the reason.
  **Verify:** integration: a live checkpoint of a Linux guest with a running `yes > /dev/null`
  restores with that process still running (`pgrep yes`); the probe writes `host-facts.json`.

- [ ] **R-609 Nested virtualization (conditional)**
  `nested_virt` → `VZGenericPlatformConfiguration.isNestedVirtualizationEnabled = true` when
  `VZGenericPlatformConfiguration.isNestedVirtualizationSupported`; otherwise `.no("needs an M3 or
  newer and macOS 15")`. On the dev host this is `.no`.
  **Verify:** unit test that the matrix says `.no` for an M1 fact set and `.yes` for an M3 fact
  set; integration test skipped unless supported.

---

## Phase 7 — Debug channel

- [x] **R-700 GDB remote protocol client**
  `VMLabGDB`: packet framing with checksums and acks, `qSupported`, `?`, `vCont?`, `c`, `s`, `g`/`G`,
  `p`/`P`, `m`/`M`, `Z0`/`z0` (software breakpoints), `Z1`/`z1` (hardware), `vCont;c`/`;s`,
  interrupt (`\x03`), `qXfer:features:read` to parse `target.xml` into a register map, with
  built-in fallbacks for arm64 (`aarch64-core.xml`) and x86_64. Stop replies parsed to
  `StopReason { signal, thread, pc }`.
  **Verify:** unit tests against fixture transcripts for every packet; a fake stub in tests serves
  `target.xml` and a `g` reply, and the client names `pc`, `sp`, `x0` with the right values.

- [ ] **R-701 `vm_debug` tool**
  Actions of Appendix C: `info` (endpoint for a human's lldb or gdb, attached state), `halt`,
  `continue`, `step`, `wait(timeout)` (block until stop), `breakpoint_add(address|symbol?,
  hardware)`, `breakpoint_remove`, `breakpoints`, `registers`, `read_memory(address, size)` (hex
  and, for ≤ 256 bytes, an ASCII column), `write_memory`. Addresses accept `0x` hex. The stub is
  started with the guest (`-gdb tcp:127.0.0.1:<port>` with `-S` only when `boot.haltAtStart`
  is set). Symbols are out of scope (addresses only) but `symbolFile` on the request is recorded
  for the `info` output so a human can `target remote` with it.
  **Verify:** integration on `qemu-tcg` x86_64: halt at start, read `rip`, set a breakpoint at the
  kernel entry from the extracted `System.map` (R-305), continue, `wait` stops there.

- [ ] **R-702 GDB under HVF probe**
  The slow probe `qemu_hvf_gdb`: boot a throwaway guest under HVF with `-gdb`, halt, read
  registers, set a software breakpoint at the current `pc` + 4, continue, expect the stop [VERIFY].
  `yes` keeps `gdb` on `qemu-hvf`; `no` turns it off with "GDB under HVF unsupported by this QEMU;
  use arch x86_64 or `prefer: [tcg]`" and the selector then offers `qemu-tcg` for arm64 guests (an
  arm64 TCG guest is legal, only slow).
  **Verify:** the probe runs from `doctor --probe` and writes the fact; the matrix row follows it.

- [ ] **R-703 Halt at start and reset**
  `boot.haltAtStart: true` starts QEMU with `-S` so the first instruction can be stepped;
  `vm_lifecycle action: reset` (QEMU `system_reset`; VZ: stop and start) returns the guest to its
  first instruction with breakpoints kept.
  **Verify:** integration: halt at start, `registers` shows the reset `pc`, `continue`, serial shows
  firmware output.

- [ ] **R-704 Watchpoints**
  `Z2`/`Z3`/`Z4` write/read/access watchpoints in the client and `breakpoint_add(kind: watch_write|
  watch_read|watch_access, size)`.
  **Verify:** unit test packets; integration under TCG: a watchpoint on a stack address stops.

- [ ] **R-705 Debug session durability**
  The GDB connection is owned by the server, not the request; it reconnects after a server restart
  if the stub is still listening, and `vm_debug info` reports `attached: false` with the endpoint
  when a human has the stub (QEMU allows one client; the tool says so instead of hanging).
  **Verify:** unit test with the fake stub refusing a second connection → `debug_busy`.

---

## Phase 8 — Checkpoints and manifests

- [ ] **R-800 Checkpoint tree**
  `<vm>/checkpoints.json`: nodes with `id`, `name`, `parent`, `mode: disk|live`, `createdAt`,
  `state at creation`, `manifestPath?`, `note`. `vm_checkpoint create(name, mode: auto|disk|live,
  manifest: bool, note)`: `auto` picks `live` if granted and the guest is running, else `disk`
  (stopping first is never implicit: a running guest without `checkpoint_live` gets `wrong_state`
  with the hint). `list`, `restore(name)` (the current node becomes the restored one), `delete`
  (refused if it has children unless `recursive`). Names unique per VM; `@latest` resolves to the
  newest.
  **Verify:** unit tests of the tree with the fake provider; integration on QEMU and VZ Linux:
  create A, change, create B, restore A, state matches A, restore B, matches B.

- [ ] **R-801 Guest manifests**
  `vm_manifest(profile: linux|macos|custom, paths)` runs a script over SSH that writes a JSON
  manifest: files under the given roots (path, size, mode, mtime, sha256 for files ≤ 8 MB), and
  per profile: Linux: `dpkg -l`/`rpm -qa`, `systemctl list-unit-files --state=enabled`, users,
  `/etc` hashes; macOS: `defaults read` of every domain in `~/Library/Preferences` and
  `/Library/Preferences`, `brew list --versions`, `launchctl list`, `profiles list`, `dscl`
  users, login items, `/etc` hashes, dotfiles in the home directory. Stored under
  `<vm>/manifests/<id>.json`, returned as a summary (counts) plus the path.
  **Verify:** unit test parses fixture outputs for both profiles; integration: a Debian manifest
  lists `/etc/hostname` with the expected hash; a macOS manifest lists `com.apple.dock`.

- [ ] **R-802 Checkpoint and manifest diff**
  `vm_checkpoint diff(from, to)` where each side is a checkpoint with a manifest, `@now` (take a
  manifest now), or a manifest id: returns added, removed and changed files (with what changed:
  size, mode, hash), packages, services, defaults keys (old and new values), users, login items.
  Output capped at 500 entries per section with the full diff saved beside the manifests.
  **Verify:** unit test over two fixture manifests; integration on macOS: run `defaults write
  com.apple.dock autohide -bool true` and the diff shows the key with `0 → 1`.

- [ ] **R-803 Clone from checkpoint**
  `vm_lifecycle clone(from: checkpoint?, name)`: a new VM from the current disk or a named
  checkpoint (APFS clone for raw images, `qemu-img create -b` backing file for qcow2 with the
  backing chain recorded), new MAC and SSH key, same plan.
  **Verify:** integration: clone, boot, the clone has the checkpoint's file; the original is
  untouched.

- [ ] **R-804 Templates**
  `images template create <vm> <name>`: a stopped VM becomes a template (its disk copied into
  `~/.vmlab/images/<name>/` with `image.json` carrying the guest and the provisioning already done,
  the SSH key removed from `authorized_keys` so each child gets its own). `vm_create image:
  <template>` uses it. Fleets build on this.
  **Verify:** integration: template from a provisioned Debian, create from it, SSH works with the
  child's key and the parent's key is refused.

- [ ] **R-805 Garbage collection**
  `vmlab gc`: removes orphaned runner processes (pid files whose record is gone), dumps and exec
  logs older than 7 days, checkpoints marked `temporary`, unused template backing files; reports
  bytes freed. `vm_lifecycle destroy` refuses when another VM's backing chain depends on this disk
  unless `force`.
  **Verify:** unit test with a fixture home directory; the backing-chain refusal is tested.

---

## Phase 9 — Segments and fleets

- [x] **R-900 `vmlab-switch`**
  A user-space Ethernet switch: one process per segment, `~/.vmlab/segments/<name>/switch.sock`
  (unix datagram); each port is a connected datagram socket; learning MAC table; broadcast
  flooding; frames over 1600 bytes dropped with a count; stats on `stats.sock`. No host
  connectivity through the switch (guests reach the internet by their NAT NIC).
  **Verify:** unit test with three in-process ports: unicast is delivered to the learned port only,
  broadcast to all others; a malformed frame is counted and dropped.

- [ ] **R-901 Segment attachment per engine**
  `net_segment` adds a second NIC: QEMU via `-netdev dgram,local.type=unix,local.path=<port>,
  remote.type=unix,remote.path=<switch>` [VERIFY on the Homebrew QEMU; fallback: `-netdev
  socket,mcast=230.0.0.<n>:<port>` for QEMU-only segments with the switch absent, recorded in
  `docs/FEATURES.md`]; VZ via `VZFileHandleNetworkDeviceAttachment` on a `socketpair` whose other
  end the runner hands to the switch over `control.sock`. Addresses: segment `n` is `10.n.0.0/24`,
  guests get `.10` upward by join order, set by cloud-init on Linux; macOS guests get a static
  address via `networksetup` in provisioning. `net_segment create|list|destroy`.
  **Verify:** integration: two QEMU guests ping each other over the segment and not over NAT (the
  NAT addresses differ in subnet); a VZ Linux guest and a QEMU guest on one segment ping.

- [ ] **R-902 Names on a segment**
  Each join appends `<ip> <vm-name> <vm-name>.<segment>` to every member's `/etc/hosts` over SSH
  (idempotent, marker-delimited block) and removes it on leave. `vm_inspect` lists segment
  addresses.
  **Verify:** integration: `ping node-2.cluster` resolves on node-1.

- [ ] **R-903 `fleet create`**
  `fleet(action: create, name, count, requirements, image|template, segment: name|auto)`: runs the
  selector once (one plan for the fleet), checks the memory budget for all members at once and
  the macOS limit, creates `<name>-1..n` from the template in parallel under the start gate,
  joins them to the segment, waits for SSH on each, and returns per-member results (some may fail;
  the fleet record lists them). `fleet status|list|destroy`. Fleet records live in
  `~/.vmlab/fleets/<name>.json`.
  **Verify:** unit test of the budget and naming; integration: a fleet of three Debian guests on
  `qemu-hvf` is up with `fleet status` all `running` within 5 minutes, then destroyed with no
  directories left.

- [ ] **R-904 `fleet exec`**
  Runs a command on every member (or a `members` subset) in parallel with the same options as
  `vm_exec`, returning a map of member → result and an `allSucceeded` flag.
  **Verify:** integration: `fleet exec "hostname"` returns each member's name.

- [ ] **R-905 Port forwarding and segment reachability from the host**
  For QEMU guests `net_port_forward` already works (R-308). For VZ guests the NAT address is
  directly reachable from the host, so `vm_inspect` reports `hostReachable: <ip>:<port>` for
  requested forwards instead of a mapped port, and the result of `vm_create` explains which it
  gave. A stand-in for a cluster check in the integration test: a fleet of three; run
  `python3 -m http.server` on node-1 and `curl` it from node-2 by name and from the host by the
  reported address.
  **Verify:** the integration test above passes on both engines.

---

## Phase 10 — Images and provisioning

- [ ] **R-1000 Ubuntu images and the amd64 catalogue**
  Add `ubuntu-24.04-arm64`, `ubuntu-24.04-amd64`, `debian-13-amd64` with their checksum URLs;
  amd64 images select `qemu-tcg` only.
  **Verify:** catalogue test; integration: Ubuntu arm64 boots under both engines.

- [ ] **R-1001 Custom user-data and packages**
  `Requirements.provision: { packages: [String], userData: String?, runCommands: [String] }` merged
  into the cloud-init seed; for macOS guests `runCommands` run over SSH after R-606.
  **Verify:** integration: a Debian guest created with `packages: [jq]` has `jq --version` working.

- [ ] **R-1002 Register a local disk image or installer**
  `images register <name> --disk <path> --guest linux --arch arm64 [--format raw|qcow2]` and
  `images register --ipsw <path>` (hands off to `tart create --from-ipsw` for a macOS base built
  locally; the attended install is the user's, documented in `docs/AGENT.md`).
  **Verify:** unit test for `image.json`; integration: a registered raw image boots.

- [ ] **R-1003 Image cache policy**
  `~/.vmlab/images` reports size in `host_facts`; `images prune` removes images no VM or template
  references; pulls over 10 GB (macOS) require `confirm: true` from the tool with the size stated.
  **Verify:** unit tests for the reference check and the confirm gate.

- [ ] **R-1004 Reproducible first boot**
  Every provisioning step (cloud-init, macOS SSH steps) writes `<vm>/provision.log` and a
  `provision.json` with each step's command, duration and exit; `vm_inspect` surfaces failures as
  a `provision_failed` warning rather than hiding them behind `ssh_unreachable`.
  **Verify:** integration: a deliberately failing `runCommands` entry shows up in `provision.json`
  and in `vm_inspect`.

---

## Phase 11 — Hardening, documentation, agent guide

- [ ] **R-1100 Concurrency and two servers**
  Two `vmlab serve` processes (two Claude sessions) share `~/.vmlab` safely: per-VM `flock`, the
  start gate as a cross-process semaphore (lock files), the memory budget computed from the records
  of both. Integration test spawns two servers and creates from both at once.
  **Verify:** the integration test passes; no record corruption.

- [ ] **R-1101 Timeouts and hangs**
  Every guest-facing call has a timeout from Appendix G and returns `timeout` with partial data;
  the QMP, RFB, GDB and control-socket clients detect a dead peer within 5 s and mark the VM
  `broken` with the reason. `vm_lifecycle kill` always works on a `broken` VM.
  **Verify:** unit tests with fake sockets that stop answering.

- [ ] **R-1102 Security review of the tool surface**
  Paths in `vm_file`, `vm_memory_dump`, `images register` and `shared_dir` are canonicalised and
  must be under the user's home or `/tmp` unless `allowAnyPath` is set in `~/.vmlab/config.json`;
  `extra.qemuArgs` keeps its denylist; `vm_introspect raw` keeps its allowlist; no tool executes a
  host shell with model-supplied strings unquoted (all host subprocesses use argument arrays).
  **Verify:** unit tests for the path policy and a grep test that no `Process` in the tree is
  given a `/bin/sh -c` with interpolated input.

- [ ] **R-1103 `docs/FEATURES.md` verified column**
  After the slow probes have run on the dev host, the generated matrix shows the verified state of
  every `[VERIFY]` row; this document's Appendix B is updated to agree (constraint C7).
  **Verify:** `scripts/gen-docs.sh` output has no `unknown` on the dev host; the C7 check passes.

- [ ] **R-1104 `docs/AGENT.md`: how a model should use vmlab**
  Written for the model that will connect: the request shape, how to read a plan or an
  unsatisfiable result, the rule "ask for every feature you might need up front because a VM
  cannot change engine", which channel to prefer for which job (serial when the display is dead,
  SSH for anything scripted, the screen only when a person would need it), the checkpoint
  discipline (checkpoint before every risky step), fleet patterns, and the five worked sessions:
  "fix a crashing window manager", "step a bootloader", "test a macOS setup script and diff",
  "three-node cluster", "bisect a kernel panic with checkpoints". Each session is a list of tool
  calls with the expected result shapes, verified against the server.
  **Verify:** every tool call in the five sessions is also a test in `Tests/IntegrationTests/AgentGuideTests.swift` that runs it and checks the result shape.

- [ ] **R-1105 Claude Code and Claude Desktop installation**
  `vmlab install-mcp --client claude-code|claude-desktop` writes or prints the MCP configuration
  (command, args, env `VMLAB_HOME`) for the client; README documents it and the Homebrew-less
  install (`swift build -c release`, `scripts/sign.sh`, copy to `~/.local/bin`).
  **Verify:** unit test of the generated configuration JSON; manual: Claude Code lists the tools.

- [ ] **R-1106 Release build**
  `scripts/release.sh`: `swift build -c release`, signs `vmlab-vz`, bundles `vmlab`, `vmlab-vz`,
  `vmlab-switch` into `dist/vmlab-<version>-arm64.tar.gz` with a checksum; `vmlab --version` reads
  the tag.
  **Verify:** the tarball unpacks and `vmlab doctor` runs from it.

---

## Phase 12 — Planned work

Phases 0 to 11 are the backlog. Work that arrives afterwards (a bug, a problem, a feature) is
planned by `/plan` into a spec under `docs/specs/` and built by workers from that spec (the process is
in [CLAUDE.md](CLAUDE.md)). Each work item gets one line here, written by the planner; the worker
that builds it ticks the line in its own pull request and nobody else edits it.

(none yet)

---

## Appendix A — Feature catalogue

Features are what a request names in `require` and `prefer`. The guest OS and architecture are
fields of the request, not features. Kind: channel (how the model interacts), boot (how the guest
starts), state (saving and restoring), net, compute.

| Feature | Kind | Meaning |
|---|---|---|
| `exec_ssh` | channel | Run commands and move files over SSH with a per-VM key |
| `exec_agent` | channel | Run commands with no guest network, through a host-side agent channel |
| `gui` | channel | Screenshots and pointer/keyboard input on the guest display |
| `gui_preboot` | channel | The display works before any OS is running (firmware, bootloader) |
| `gui_desktop` | channel | A desktop environment is installed in a Linux guest |
| `gui_accel` | compute | Paravirtualized graphics; smooth desktop use |
| `serial` | channel | A serial console captured from the first byte, readable and writable |
| `gdb` | channel | A GDB stub on the guest CPU: halt, step, breakpoints, registers, memory |
| `introspection` | channel | Machine state queries: PCI, block, memory map, CPU registers |
| `memory_dump` | channel | Dump guest physical memory to a file |
| `direct_kernel_boot` | boot | Boot a kernel and initrd without a disk-resident bootloader |
| `custom_firmware` | boot | Supply the firmware or bootloader image itself |
| `custom_devices` | boot | Pass arbitrary virtual-device arguments to the engine |
| `halt_at_start` | boot | The CPU starts halted so the first instruction can be debugged |
| `checkpoint_disk` | state | Named disk snapshots of a stopped guest |
| `checkpoint_live` | state | Named snapshots of a running guest including memory |
| `pause` | state | Pause and resume without saving to disk |
| `net_nat` | net | Outbound internet through host NAT |
| `net_fast` | net | NAT on the fast vmnet path rather than user-mode networking |
| `net_segment` | net | A second NIC on a private host-local segment shared with other guests |
| `net_port_forward` | net | A guest port reachable from the host |
| `net_none` | net | No network device at all |
| `rosetta` | compute | Run amd64 Linux binaries in an arm64 Linux guest |
| `nested_virt` | compute | The guest can run its own hypervisor |
| `shared_dir` | compute | A host directory mounted in the guest |
| `cloud_init` | boot | First-boot provisioning for Linux guests |
| `many_guests` | compute | More than two instances may run at once |

## Appendix B — Capability matrix

Y yes; N no (reason in code); C conditional on a host fact (named); ? conditional on a slow probe
that was `unknown` when this was written (`[VERIFY]`; the item that owns it is named).

| Feature | vz-macos | vz-linux | qemu-hvf (arm64) | qemu-tcg (any arch) |
|---|---|---|---|---|
| `exec_ssh` | Y | Y | Y | Y |
| `exec_agent` | N | N | Y (qemu-ga) | Y |
| `gui` | Y (guest Screen Sharing) | Y (in-guest VNC) | Y (QEMU VNC) | Y |
| `gui_preboot` | N | N | Y | Y |
| `gui_desktop` | Y (built in) | Y (R-504) | Y (R-504) | Y |
| `gui_accel` | Y | Y | N | N |
| `serial` | N | Y | Y | Y |
| `gdb` | N | N | ? `qemu_hvf_gdb` (R-702) | Y |
| `introspection` | N | N | Y | Y |
| `memory_dump` | N | N | Y | Y |
| `direct_kernel_boot` | N | Y | Y | Y |
| `custom_firmware` | N | N | Y | Y |
| `custom_devices` | N | N | Y | Y |
| `halt_at_start` | N | N | Y | Y |
| `checkpoint_disk` | Y | Y | Y | Y |
| `checkpoint_live` | ? `vz_macos_live_snapshot` (R-608) | ? `vz_linux_live_snapshot` (R-608) | ? `qemu_hvf_live_snapshot` (R-307) | Y |
| `pause` | Y | Y | Y | Y |
| `net_nat` | Y | Y | Y | Y |
| `net_fast` | Y | Y | C `root` or `qemu_vmnet` | C same |
| `net_segment` | Y (static, R-901) | Y | Y | Y |
| `net_port_forward` | Y (host-reachable address) | Y (same) | Y (hostfwd) | Y (hostfwd) |
| `net_none` | Y | Y | Y | Y |
| `rosetta` | N | C `rosetta_installed` | N | N |
| `nested_virt` | N | C `nested_supported` (M3+, macOS 15+) | N | Y (slow) |
| `shared_dir` | Y (virtiofs) | Y (virtiofs) | Y (9p) | Y (9p) |
| `cloud_init` | N | Y | Y | Y |
| `many_guests` | N (limit 2) | Y | Y | Y |
| Guest OS | macOS | Linux | Linux | Linux |
| Arch | arm64 | arm64 | arm64 | x86_64, arm64, riscv64, other |
| Performance tier (1 best) | 1 | 1 | 2 | 4 |
| Energy tier (1 best) | 1 | 1 | 2 | 3 |
| Startup tier (1 best) | 2 | 1 | 1 | 3 |

## Appendix C — MCP tools

Names are final. Each row gives the input fields (required in bold) and the result shape. Every
result also carries `vm` (id and name) where a VM is involved and `warnings: [String]`.

| Tool | Input | Result |
|---|---|---|
| `host_facts` | — | `HostFacts` (Appendix E) |
| `host_doctor` | `probe: bool` | `[ { check, status: ok|missing|unknown, fix } ]`, probe results |
| `images` | **`action`**: list, pull, remove, register, template_create, prune, extract_kernel; `name`, `confirm`, `path`, `guest`, `arch`, `format` | list: `[Image]`; pull: `{ name, path, bytes, cached }` |
| `vm_plan` | **`requirements`** (below) | `Plan { profile, features, unverified, preferredDenied, estimatedStartupSeconds, notes }` or `Unsatisfiable { eliminated: { feature: [profile] }, suggestions: [ { drop: [feature], profile } ] }` |
| `vm_create` | **`requirements`**, `name`, `autostart` (default true), `confirm` | `{ plan, vm, state, endpoints }` |
| `vm_list` | `state?`, `fleet?` | `[ { id, name, profile, state, guest, fleet?, ip?, sshPort? } ]` |
| `vm_inspect` | **`vm`** | record, plan, endpoints, segment addresses, last 20 events, warnings, latest panic |
| `vm_lifecycle` | **`vm`**, **`action`**: start, stop, kill, pause, resume, reset, destroy, clone; `name`, `from`, `force`, `timeoutSeconds` | `{ state, durationMs }`; clone: the new VM |
| `vm_exec` | **`vm`**, **`command`**, `timeoutSeconds`, `cwd`, `env`, `stdin`, `user`, `via`: auto|ssh|agent, `background` | `{ exitCode, stdout, stderr, durationMs, truncated, logPath }` or `{ job }` |
| `vm_job` | **`vm`**, **`job`**, **`action`**: read, wait, kill; `timeoutSeconds` | `{ output, finished, exitCode? }` |
| `vm_file` | **`vm`**, **`action`**: push, pull; **`remote`**, `local` | `{ bytes, path }` |
| `vm_computer` | **`vm`**, **`action`**: screenshot, left_click, right_click, middle_click, double_click, triple_click, left_click_drag, mouse_move, cursor_position, type, key, scroll, wait, zoom, screen_info; `coordinate: [x, y]`, `startCoordinate`, `text`, `scrollDirection`, `scrollAmount`, `region: [x0, y0, x1, y1]`, `durationSeconds`, `maxEdge`, `format`, `quality`, `diffFrom`, `scaled`, `settleMs` | image content + `{ id, width, height, scale, changedRegion?, unchanged? }` |
| `vm_serial` | **`vm`**, **`action`**: read, tail, write, wait; `since`, `lines`, `text`, `pattern`, `timeoutSeconds` | `{ text, offset, matched?, truncated }` |
| `vm_debug` | **`vm`**, **`action`**: info, halt, continue, step, wait, breakpoint_add, breakpoint_remove, breakpoints, registers, read_memory, write_memory; `address`, `size`, `data` (hex), `kind`: software|hardware|watch_write|watch_read|watch_access, `timeoutSeconds`, `thread` | `{ stopped, reason?, pc?, registers?, bytes?, breakpoints? , endpoint }` |
| `vm_introspect` | **`vm`**, **`query`**: status, block, pci, cpus, memory_tree, registers, devices, raw; `qmp`, `hmp` | the engine's answer as JSON or text |
| `vm_memory_dump` | **`vm`**, `address`, `size`, `confirm` | `{ path, bytes, format: raw|elf }` |
| `vm_checkpoint` | **`vm`**, **`action`**: create, list, restore, delete, diff; `name`, `mode`: auto|disk|live, `manifest`, `note`, `recursive`, `from`, `to` | create: node; list: tree; diff: sections (files, packages, services, defaults, users, loginItems), `path` |
| `vm_manifest` | **`vm`**, `profile`: linux|macos|custom, `paths` | `{ id, path, counts }` |
| `vm_logs` | **`vm`**, `source`: events|serial|provision|all, `tail` | `{ lines }` |
| `net_segment` | **`action`**: create, list, destroy; `name` | `{ name, subnet, members }` |
| `fleet` | **`action`**: create, list, status, exec, destroy; `name`, `count`, `requirements`, `image`, `segment`, `command`, `members`, `timeoutSeconds` | create/status: `{ members: [ { vm, state, ip, error? } ] }`; exec: `{ results: { name: ExecResult }, allSucceeded }` |

`requirements` (shared by `vm_plan`, `vm_create`, `fleet create`):

```json
{
  "guest": { "os": "linux", "arch": "arm64" },
  "require": ["serial", "gdb", "checkpoint_live"],
  "prefer": ["net_fast"],
  "resources": { "cpus": 4, "memoryGB": 8, "diskGB": 32 },
  "network": { "mode": "nat", "segment": "cluster-a", "forwards": [{ "guest": 22 }, { "guest": 8080, "host": 18080 }] },
  "image": "debian-13-arm64",
  "boot": { "mode": "kernel", "kernel": "…", "initrd": "…", "cmdline": "console=ttyAMA0", "haltAtStart": false },
  "provision": { "packages": ["jq"], "runCommands": ["…"], "userData": null },
  "extra": { "qemuArgs": [] }
}
```

Every field but `guest` has a default (Appendix G). `require` defaults to `[]`, which lands on a VZ
profile. The result of `vm_create` repeats the resolved plan so the model knows what it has.

## Appendix D — Error codes

Every error is `{ code, message, hint, data }`.

| Code | When | `data` |
|---|---|---|
| `invalid_request` | the request contradicts itself or a field is malformed | `field`, `reason` |
| `unsatisfiable` | no profile provides every required feature on this host | `eliminated`, `suggestions` |
| `unverified_capability` | a feature depends on a probe still `unknown` and `allowUnverified` was not set | `feature`, `probe`, hint "run host_doctor with probe: true" |
| `capability_missing` | a channel was called on a VM whose plan did not grant it | `feature`, `profile`, hint to recreate with `require` |
| `vm_not_found` | | `vm` |
| `wrong_state` | the action is illegal in the VM's current state | `state`, `legalActions` |
| `limit_macos_guests` | two macOS guests already run | `running` |
| `limit_memory` | the memory budget would be exceeded | `requestedGB`, `freeGB`, `reserveGB` |
| `host_missing_tool` | QEMU, Tart, Rosetta or the signed runner is missing | `tool`, `fix` |
| `image_not_found` | | `name`, `available` |
| `confirm_required` | a large pull or dump needs `confirm: true` | `bytes` |
| `timeout` | a guest-facing call hit its deadline | `timeoutSeconds`, partial data |
| `guest_unreachable` | SSH or the agent did not answer | `tried`, last error |
| `provision_failed` | a first-boot step failed | `step`, `log` |
| `debug_busy` | the GDB stub has another client | `endpoint` |
| `engine_error` | the engine returned an error | `engine`, `raw` |
| `internal` | a bug; always logged with a stack | `id` |

## Appendix E — Host facts and probes

Fast facts (every server start): `osVersion`, `chip` (model string and generation), `memoryGB`,
`freeMemoryGB`, `freeDiskGB`, `isRoot`, `qemu: { present, version, path, accelerators: [hvf, tcg] }`,
`tart: { present, version }`, `rosettaInstalled`, `nestedSupported`
(`VZGenericPlatformConfiguration.isNestedVirtualizationSupported`, via the runner), `runnerSigned`,
`runningMacOSGuests`, `runningGuests`, `imagesBytes`.

Slow probes (persisted in `~/.vmlab/host-facts.json` with `probedAt` and the tool versions they
were probed with; invalidated when the QEMU or macOS version changes):

| Probe | Owner | Method |
|---|---|---|
| `qemu_hvf_live_snapshot` | R-307 | `snapshot-save` then `snapshot-load` on a tiny HVF guest; serial responds after |
| `qemu_hvf_gdb` | R-702 | halt, software breakpoint at pc+4, continue, stop arrives |
| `qemu_vmnet` | R-309 | start a guest with `-netdev vmnet-shared`; it gets a lease |
| `vz_linux_live_snapshot` | R-608 | save and restore a tiny Linux guest; serial responds after |
| `vz_macos_live_snapshot` | R-608 | save and restore a macOS guest; SSH responds after (needs a pulled macOS image; skipped and left `unknown` otherwise) |

Known on the development host: M1 Max → `nestedSupported = false`; 32 GB → budget allows about
six 4 GB guests with the default reserve; macOS 26.6 → VZ save/restore APIs present.

## Appendix F — On-disk layout

```
~/.vmlab/                      (VMLAB_HOME)
  config.json                  reserveGB, parallelStarts, allowAnyPath, defaults
  host-facts.json              slow probe results
  board.json                   session board (R-002; never committed)
  images/<name>/               image.json, disk.(raw|qcow2), kernel/, checksums
  vms/<id>/
    vm.json                    VMRecord (schemaVersion)
    events.jsonl
    disk.raw | disk.qcow2      (vz-macos: the Tart clone lives under ~/.tart/vms/<id>/ and vm.json points there)
    seed.iso                   cloud-init
    efi-vars.bin               VZ EFI variable store / QEMU pflash vars
    id_ed25519, id_ed25519.pub, known_hosts, vnc.pass
    qmp.sock, serial.sock, vnc.sock, control.sock, vz.pid, qemu.pid
    serial.log, vz.log, qemu.log, provision.log, provision.json
    checkpoints.json, checkpoints/<id>/ (VZ state files and disk clones)
    manifests/<id>.json, exec/<job>.log, dumps/, pulled/, screenshots/
  segments/<name>/             switch.sock, stats.sock, switch.pid, ports/
  fleets/<name>.json
  locks/
```

## Appendix G — Defaults and limits

| Setting | Default |
|---|---|
| CPUs / memory / disk | 2 / 4 GB / 32 GB (macOS: 4 / 8 GB / image size) |
| Memory reserve kept free on the host | 4 GB |
| Concurrent starts | 4 |
| macOS guests running | 2 (Apple's limit) |
| Boot timeout until SSH (Linux / macOS / TCG) | 180 s / 300 s / 900 s |
| `vm_exec` timeout | 120 s |
| Exec output kept inline | 64 KB (16 KB head + 48 KB tail) |
| Serial ring buffer / log rotation | 4 MB / 64 MB |
| Screenshot long edge / format | 1280 px / PNG |
| Screenshots kept per VM for `diffFrom` | 20 |
| Settle delay after an input action | 300 ms |
| Stop grace before kill | 60 s |
| Dead-peer detection on sockets | 5 s |
| Memory dump without `confirm` | ≤ 256 MB |
| Image pull without `confirm` | ≤ 10 GB |
| GC age for dumps and exec logs | 7 days |
| Segment subnets | `10.<n>.0.0/24`, guests from `.10` |

## Appendix H — Images

| Name | Guest | Arch | Source | Format | Login |
|---|---|---|---|---|---|
| `debian-13-arm64` | linux | arm64 | `https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2` (a `.raw` is published too; vmlab pulls the smaller qcow2 and converts it), `SHA512SUMS` beside it | qcow2 (converted to raw for VZ) | `debian` via key |
| `debian-13-amd64` | linux | x86_64 | same path, `-amd64` | qcow2 | `debian` |
| `ubuntu-24.04-arm64` | linux | arm64 | `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img`, `SHA256SUMS` | qcow2 (converted to raw for VZ) | `ubuntu` |
| `ubuntu-24.04-amd64` | linux | x86_64 | same, `-amd64.img` | qcow2 | `ubuntu` |
| `macos-base` | macos | arm64 | `ghcr.io/cirruslabs/macos-tahoe-base:latest` via `tart pull`; if it does not boot on this host, `macos-sequoia-base:latest` (record which in `docs/FEATURES.md`) | Tart VM | `admin` / `admin`, SSH and Screen Sharing enabled by the image |

The Debian kernel and initrd for direct boot are extracted from the pulled raw image
(`images extract-kernel`: mount with `hdiutil attach -imagekey diskimage-class=CRawDiskImage` or
read the ext4 partition with a small reader in `VMLabCore/Ext4.swift` if `hdiutil` cannot mount
ext4; decide in R-305 and record it).

## Appendix I — Selection algorithm and worked examples

1. **Normalise.** Defaults from Appendix G; `guest` required. Reject contradictions (R-100).
2. **Host facts.** Fast facts now; slow probes from the persisted file (`unknown` → `no`, and the
   feature is listed as `unverified` with the hint to probe; `allowUnverified: true` treats it as
   `yes` and the plan says so).
3. **Guest filter.** macOS → `vz-macos` only. Linux arm64 → `vz-linux`, `qemu-hvf`, `qemu-tcg`.
   Linux other arch → `qemu-tcg` only.
4. **Feature filter.** For each feature in `require`, drop every profile whose matrix entry
   resolves to `no`; record `eliminated[feature] = [profiles]`.
5. **Empty?** Return `Unsatisfiable` with `eliminated` and `suggestions`: smallest subsets of
   `require` (size 1, then 2, then 3) whose removal leaves a survivor, each with that survivor.
6. **Dynamic limits.** For each survivor in rank order: macOS count, memory budget; the first that
   passes wins; if none, the error of the first survivor.
7. **Rank.** For an arm64 guest, `qemu-tcg` only after every hardware-virtualized survivor (a
   preference never moves a native guest onto an emulated CPU); then count of `prefer` satisfied
   (desc), then performance tier, energy tier, startup tier (asc), then `vz-linux` before
   `qemu-hvf` before `qemu-tcg`.
8. **Plan.** Profile, resolved features (`require` ∪ every `yes` in the matrix for that profile, so
   the model learns what else it has), `preferredDenied`, `unverified`, `notes` (TCG speed warning,
   GUI install time, host-reachable address instead of a forwarded port on VZ).

Worked examples (each is a unit test in R-103; host = dev host, all probes `yes`, no root):

| Request | Result |
|---|---|
| linux arm64, require [] | `vz-linux` |
| linux arm64, require [serial, gdb] | `qemu-hvf` |
| linux arm64, require [gdb, checkpoint_live], probe `qemu_hvf_live_snapshot` = no | `qemu-tcg` (notes: slow) |
| linux arm64, require [serial, rosetta] | `vz-linux` |
| linux arm64, require [rosetta, gdb] | unsatisfiable: `rosetta` eliminated qemu-hvf, qemu-tcg; `gdb` eliminated vz-linux; suggestions: drop [gdb] → vz-linux; drop [rosetta] → qemu-hvf |
| linux x86_64, require [gui_preboot, custom_firmware] | `qemu-tcg` |
| linux x86_64, require [gui_accel] | unsatisfiable: `gui_accel` eliminated qemu-tcg (the only x86_64 profile); suggestions: drop [gui_accel] → qemu-tcg |
| linux arm64, network.mode none, require [net_port_forward] | `invalid_request` (contradiction, caught before selection) |
| macos, require [] | `vz-macos` |
| macos, require [serial] | `invalid_request` (contradiction, caught before selection) |
| macos, require [gui, checkpoint_disk], two macOS guests running | `limit_macos_guests` |
| linux arm64, require [net_fast], not root, `qemu_vmnet` = no | `vz-linux` (net_fast is yes there) |
| linux arm64, require [net_fast, gdb], not root, `qemu_vmnet` = no | unsatisfiable; suggestions: drop [gdb] → vz-linux; drop [net_fast] → qemu-hvf |
| linux arm64, require [nested_virt] on M1 | `qemu-tcg` (notes: nested virtualization emulated, very slow; `vz-linux` eliminated by `nested_supported = false`) |
| linux arm64, require [gdb], prefer [checkpoint_live], probe `qemu_hvf_live_snapshot` = unknown | `qemu-hvf` with `unverified: [checkpoint_live]`, `preferredDenied: [checkpoint_live]` |
| linux arm64, require [], prefer [serial] | `vz-linux` (serial is yes there) |
| linux arm64, require [exec_agent] | `qemu-hvf` |
| fleet of 6 × 8 GB on a 32 GB host | `limit_memory` with the numbers |
| linux arm64, require [many_guests, gui_accel] | `vz-linux` |
| macos, require [many_guests] | unsatisfiable; eliminated: many_guests → vz-macos; suggestions: drop [many_guests] → vz-macos |
