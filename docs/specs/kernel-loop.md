# Kernel loop: spec for R-1200 to R-1207

Written by `/plan` on 2026-10-21. Status: approved.

**The request, in the owner's words:** an assessment of how two bare-metal kernel projects (ptah,
aikern) use vmlab from Claude Code found that the rebuild-and-run loop routes around the tools in
several places. A test run powers the guest off in under a second and then `vm_serial` refuses it
with `wrong_state` (the only recurring error in every vmlab MCP log on the host), so the projects
read `console.log` from `console.start` with a shell script and poll `vm.json` for `stopped`.
`vm_lifecycle reset` keeps the kernel QEMU loaded at start, so a rebuilt image is not picked up and
the projects forbid reset. A kernel boot still gets the default Debian image, a 32 GB sparse disk,
a cloud-init seed and the guest-agent port. No feature lets an arm64 guest land on `qemu-tcg`, so
`-icount`, instruction tracing and system registers are unreachable. Memory dumps live only under
the VM directory and die with it. The agent guide has no worked session for this loop. And `vmlab
gc` does not see the switch processes a killed integration run leaves behind.

## Goal

A model iterating on a bare-metal kernel creates one VM with `image: "none"`, then for every
rebuild calls `reset` and `vm_serial wait`, reads the whole run back after the guest powered off,
dumps memory to a path it chose, and can ask for an emulated CPU when it needs `-icount`. None of
it needs a shell script beside vmlab.

## Non-goals

- Symbol resolution in `vm_debug`, system registers under HVF, `info irq` under HVF: QEMU and HVF
  limits, not vmlab's.
- A `since` for `vm_logs`: once `vm_serial` reads stopped guests it is not needed.
- A new lifecycle action (`restart`, `run`): `reset` and `wait` cover the loop.
- Changing what an omitted `image` means: it stays the guest's default image (W3).
- Ending `vmlab-switch` processes that belong to another `VMLAB_HOME` from `vmlab gc` (W8 fixes the
  test harness that leaks them instead).
- `cpu_emulation` on VZ: Virtualization.framework runs the CPU natively; the row is N.

## Engines and the matrix

- W5 adds the feature `cpu_emulation` (kind compute) to Appendix A and a row to Appendix B and
  `Capabilities.swift`: Y on `qemu-tcg`, N on `vz-macos`, `vz-linux` and `qemu-hvf` with the
  reason that the engine runs the guest CPU natively. No probe: `qemu-tcg` exists on every host
  with QEMU (`QEMUTCGIntegrationTests` already boot it).
- W3 lets a `vz-linux` kernel boot run with no storage device. That path exists: a registered
  kernel-only image (R-305, CX-30) gets no disk and no seed on VZ (`VZBackend.createFiles`,
  `vmlab-vz/Configuration.swift` maps an empty storage list). `image: "none"` takes the same path.
- W4's `relaunched` is reported for every engine that was started anew by a reset: on the VZ
  profiles `Backend.reset`'s default is already kill and start, so a VZ file boot picks up a rebuilt
  kernel today and every VZ reset reports `relaunched: true`; `bootFiles` is recorded by QEMU only.
- Everything else is QEMU-side behaviour or host-side tooling and changes no matrix row.

## Shared surfaces

| Surface | Changed by | Note |
|---|---|---|
| `Tests/IntegrationTests/BareKernel.swift` (new test helper) | W1, goes first | W2, W4, W5, W7 boot it |
| `Feature` enum (`Sources/VMLabCore/Features.swift`), Appendix A and B, `Capabilities.swift`, the `require`/`prefer` enums in every tool schema | W5 only | regenerates `docs/FEATURES.md` and `docs/TOOLS.md` |
| `VMRuntime` (`Sources/VMLabCore/Store.swift`): optional `bootFiles` | W4 only | additive, no `schemaVersion` bump; an absent value means "unknown, do not relaunch" |
| `vm_serial` result shape (`stopped`) | W2 only | additive |
| `vm_lifecycle` result shape (`relaunched`) | W4 only | additive |
| `vm_memory_dump` input (`local`) | W6 only | additive |
| `requirements.image` ("none") in `ToolSpec.requirements` | W3 only | a reserved name, not a schema change |
| `QEMUBackend.swift` | W3 (`request`), W4 (`reset`) | different functions; W4 goes after W3 |
| `EngineProcess.isSwitch` (`Sources/VMLabCore/EngineProcess.swift`, new predicate beside `isEngine`) | W8 only | `isEngine` stays as it is |
| `ImageStore.checkName` (`Sources/VMLabCore/Images.swift`) reserving `"none"` | W3 only | |
| `docs/TOOLS.md`, `docs/FEATURES.md` | every item that changes a schema or the matrix | regenerate after syncing `origin/main`, never hand-merge |
| `docs/AGENT.md` | W2, W3, W4, W5, W6 (a sentence each), W7 (session 6) | W7 goes last |

## Work items

### W1 — A bare arm64 test kernel (R-1200, size S, depends on: nothing)

Files: `Tests/IntegrationTests/BareKernel.swift` (new), `Tests/IntegrationTests/QEMUBootIntegrationTests.swift`,
`docs/ARCHITECTURE.md` (the test-helper paragraph)

A raw arm64 image the tests write themselves, so that every item below can boot a guest that prints
a known line and powers off in well under a second, without a cross toolchain, a pulled image or a
checked-in binary. `BareKernel.image(message:, then:)` returns the bytes: a 64-byte Linux arm64
`Image` header (`text_offset` 0x80000, the `ARM\x64` magic at byte 56, `code0` a branch over the
header) followed by hand-encoded instructions that write `message` byte by byte to the PL011 data
register at `0x09000000`, then either call PSCI `SYSTEM_OFF` (`x0 = 0x84000008`, `hvc #0`;
`then: .powerOff`) or spin forever (`then: .halt`). `BareKernel.write(to:message:then:)` writes it to a file. The instruction
encodings are fixed 32-bit little-endian words; the message is embedded after the code and ends in
`\n`, so a `vm_serial wait` for it matches a whole line.

Acceptance:
- A `qemu-hvf` guest created with `boot.mode: kernel`, `boot.kernel` naming the written file,
  `require: ["serial", "net_none"]`, `cpus: 1`, `memoryGB: 1`, `autostart: false`, then started,
  prints `message` on its serial console and reaches `stopped` within ten seconds of `start`
  (the events log says the guest powered off).
- The `then: .halt` variant prints the message and stays `running` until killed.
- Two images with different messages differ in bytes and print their own message.
- The helper has no dependency beyond Foundation and the test target; it is `Sendable` and usable
  from `@Suite(.serialized)` suites.

Verify: `swift test --filter QEMUBootIntegrationTests/bareKernelBytes` (not integration: two
messages give two images that differ, each holding its message and ending in `\n`, the header's
magic at byte 56); `VMLAB_INTEGRATION=1 swift test --no-parallel --filter
QEMUBootIntegrationTests/bareKernelPowersOff` and `--filter QEMUBootIntegrationTests/bareKernelHalts`
(integration; W3 has not landed, so the tests name `image: "debian-13-arm64"`, which the kernel
boot ignores); `scripts/check.sh`.

### W2 — `vm_serial` reads a stopped guest and `wait` notices the power-off (R-1201, size M, depends on: W1)

Files: `Sources/VMLabMCP/Handlers/VMSerialHandler.swift`, `Sources/VMLabMCP/Tools/VMSerialTool.swift`,
`Sources/VMLabCore/Serial.swift`, `Sources/VMLabCore/VMManager.swift` (if a stopped VM's console log
needs a Core accessor), `Tests/UnitTests/MCP/Handlers/VMSerialHandlerTests.swift`,
`Tests/UnitTests/Core/SerialTests.swift`, `Tests/IntegrationTests/SerialIntegrationTests.swift`,
`docs/AGENT.md` (the "which channel" table and the serial paragraph), `docs/ARCHITECTURE.md`

Today `VMManager.attach` refuses every state but running and paused, so `read`, `tail` and `wait`
fail with `wrong_state` the moment a guest powers off, although `<vm>/console.log` holds every byte.
The console log is the record (R-602, the kernel-ux fix); the live socket only wakes the reader.

Acceptance:
- On a VM in any state that is not running or paused (`stopped`, `created`, `broken`, `suspended`)
  whose directory has a `console.log`, `vm_serial read`, `tail` and `wait` answer from the file with
  the same offsets, `since` default (`console.start`) and result shape as on a running VM. The
  feature check is unchanged: a VM whose plan lacks `serial` fails with `capability_missing` in
  every state. `write` on a VM that is not live still fails with `wrong_state` and the hint to
  start it. A VM with no `console.log` yet answers `read` and `tail` with empty text and offset 0,
  and `wait` with `stopped: true`, empty text and offset 0.
- `wait` on a VM that is not running scans the log from `since`; a match returns as today, and no
  match returns at once (no timeout wait) with `stopped: true`, `text` from `since` (capped as a
  timed-out wait caps it, `truncated` set accordingly), `offset` at the end of the log and no
  `matched`.
- `wait` on a running VM whose guest powers off (QEMU exits after `SHUTDOWN`) or is killed before
  the pattern matches returns within two seconds of the engine's exit with `stopped: true` and the
  same fields, rather than waiting out `timeoutSeconds` or failing with `guest_unreachable`. A
  match found in output that arrived before the reader ended returns `matched` and no `stopped`.
  The record's state flips to `stopped` asynchronously (the event watcher waits up to ten seconds
  for the pid, `recordHangUp` adds a settle), so the handler does not rely on it: after the
  channel's reader ends without a match it checks every 100 ms, for at most three seconds, whether
  the engine process the runtime names is gone (`EngineProcess.isRunning(pid, vmDirectory:)`) or
  the record is no longer live; either gives `stopped: true`. A VM whose engine is still running
  when the three seconds are up fails with `guest_unreachable` as today.
- The `vm_serial` summary and result documentation say so (`stopped?` in the result shape; "works on
  a stopped guest: the log is the record"); `docs/TOOLS.md` regenerated.
- The CLI subcommand for `vm_serial` (G6, `Sources/vmlab/ToolCommand.swift`) gets the same
  behaviour for free; the integration test calls it once on a stopped VM.

Verify: `swift test --filter VMSerialHandlerTests` (cases: `read`, `tail` and `wait` on a stopped
record with a `console.log`, the match and the no-match case; a `suspended` record; a stopped
record with no log; `write` on a stopped record is `wrong_state`; a stopped record whose plan lacks
`serial` is `capability_missing`; a running record whose channel reader ends and whose fake engine
pid is gone: `stopped: true`; the same with the pid still alive after the wait: `guest_unreachable`),
`swift test --filter SerialTests` (the channel reports "reader ended, no match" distinctly from a
timeout);
`VMLAB_INTEGRATION=1 swift test --no-parallel --filter SerialIntegrationTests` (integration: the W1
kernel with `SYSTEM_OFF`; `wait` for a pattern the kernel never prints returns `stopped: true`
within two seconds; `read` after `stopped` returns the message; `write` fails with `wrong_state`;
`vmlab serial wait` from the CLI on the stopped VM prints `stopped: true`);
`scripts/check.sh`.

### W3 — `image: "none"` for kernel, binary and firmware boots (R-1202, size M, depends on: W1)

Files: `Sources/VMLabMCP/Handlers/VMCreateHandler.swift`, `Sources/VMLabMCP/Tools/ToolSpec.swift`
(the `image` description), `Sources/VMLabCore/Features.swift` (the contradiction check, beside the
`net_none` one), `Sources/VMLabCore/Images.swift` (`checkName`), `Sources/VMLabCore/VMManager.swift` (start without an SSH wait),
`Sources/VMLabQEMU/QEMUBackend.swift` (`request`), `Sources/VMLabQEMU/QEMUCommandLine.swift`,
`Sources/VMLabQEMU/QEMUMachine.swift` (`prepare`), `Sources/VMLabVZ/RunnerConfig.swift` and the
runner's machine builder, `Sources/VMLabMCP/Handlers/VMInspectHandler.swift`,
`Tests/UnitTests/MCP/Handlers/VMCreateHandlerTests.swift`, `.../FleetHandlerTests.swift`,
`.../ImagesHandlerTests.swift`, `.../VMCheckpointHandlerTests.swift`, `.../VMExecHandlerTests.swift`,
`.../VMInspectHandlerTests.swift`, `.../VMLifecycleHandlerTests.swift`,
`Tests/UnitTests/Core/SelectorTests.swift`, `Tests/UnitTests/Core/FeaturesTests.swift`,
`Tests/UnitTests/QEMU/QEMUCommandLineTests.swift`, `Tests/UnitTests/VZ/RunnerLauncherTests.swift`,
`Tests/IntegrationTests/QEMUBootIntegrationTests.swift`, `Tests/IntegrationTests/VZKernelBootIntegrationTests.swift`,
`docs/AGENT.md`, `docs/ARCHITECTURE.md`, REQUIREMENTS.md Appendix G (the `image` default line)

The owner's decision: a reserved image name, `"none"`, means a bare machine. Omitting `image` keeps
the guest's default image, so a custom kernel over the Debian root disk (the first use of
`direct_kernel_boot`) is unchanged.

Acceptance:
- `vm_plan` and `vm_create` accept `image: "none"` when `boot.mode` is `kernel`, `binary` or
  `firmware`; with `boot.mode: disk` (or omitted) they fail with `invalid_request` on field `image`
  and the hint "a disk boot needs an image; set boot.mode or name an image". `boot.kernel` (or
  `binary`, `firmware`) must then be given, since there is no image to extract a kernel from.
- With `image: "none"`, features that need a guest OS or a disk cannot be required: `exec_ssh`,
  `exec_agent`, `cloud_init`, `gui_desktop`, `shared_dir`, `net_port_forward`, `rosetta`,
  `checkpoint_disk` and `checkpoint_live` (QEMU checkpoints of either mode are qcow2 snapshots of
  `disk.qcow2`, VZ disk checkpoints clone the disk) in `require` fail with `invalid_request` before
  selection (a contradiction, like `serial` on macOS), and the resolved plan's `features` omits all
  nine. `vm_exec`, `vm_file`, `vm_job`, `vm_checkpoint create` in every mode (`auto` included),
  `vm_checkpoint restore` and `vm_lifecycle clone` on such a VM fail with `capability_missing`.
  `fleet create` with `image: "none"` is accepted under the same rules (it goes through the same
  image resolution); `vm_computer`, `vm_serial`, `vm_debug`, `vm_introspect`, `vm_memory_dump`,
  `pause` and `resume` work as the profile grants them.
- The VM record stores no image (`image` absent in `vm.json`; `vm_list` and `vm_inspect` show
  `image: "none"`). Nothing is pulled; no SSH key is generated; no `seed.iso`, no `disk.qcow2`
  (`resources.diskGB` is ignored and the plan carries a note saying so when it was given); on QEMU
  no `-drive`, no guest-agent chardev and port; `ramfb` and the input devices stay (`gui_preboot`
  works on a bare machine). On `vz-linux`, the runner configuration has no storage device (or the
  fallback named under "Engines and the matrix").
- `vm_create` with `autostart` and `vm_lifecycle start` return as soon as the engine is up and the
  console is connected, as a `haltAtStart` boot does today, with no `ssh_unreachable` warning, and
  the first-boot provisioning step records nothing. `vm_inspect` lists no SSH endpoint and no
  provisioning.
- `ImageStore.checkName` reserves `"none"`, so `images register`, `pull`, `remove`,
  `extract_kernel` and `template_create` refuse it with `invalid_request`.

Verify: `swift test --filter VMCreateHandlerTests` (accepted for the three file modes, refused for
disk, nine features refused, the plan's `features`, no key and no pull), `--filter
FleetHandlerTests`, `--filter ImagesHandlerTests` (the reserved name), `--filter
VMCheckpointHandlerTests` (`auto`, `disk`, `live` and `restore` all `capability_missing`),
`--filter VMExecHandlerTests`, `--filter VMLifecycleHandlerTests` (`clone`), `--filter
VMInspectHandlerTests` (`image: "none"`, no SSH endpoint), `--filter FeaturesTests`, `--filter
SelectorTests`, `--filter QEMUCommandLineTests` (no `-drive`, no guest-agent chardev, `ramfb`
kept), `--filter RunnerLauncherTests` (no storage device); `VMLAB_INTEGRATION=1 swift test --no-parallel
--filter QEMUBootIntegrationTests/bareKernelWithoutImage` (integration: the W1 kernel on `qemu-hvf`
with `image: "none"`; the VM directory has no disk and no seed; `start` returns in under five
seconds) and `--filter VZKernelBootIntegrationTests/kernelWithoutImage` (integration, `vz-linux`:
the extracted `debian-13-arm64` kernel and initrd with `image: "none"`; `vm_serial wait` for
`Linux version|Booting Linux` matches on `hvc0`; the initrd finding no root is expected and the
VM is killed); `scripts/check.sh`.

### W4 — `reset` relaunches a QEMU file boot whose files changed (R-1203, size M, depends on: W1, W3)

Files: `Sources/VMLabCore/Store.swift` (`VMRuntime.bootFiles`), `Sources/VMLabCore/VMManager.swift`
(`run(.reset)` outcome), `Sources/VMLabQEMU/QEMUBackend.swift` (`reset`, and `start` recording the
fingerprint), `Sources/VMLabCore/Debug.swift` (`afterRelaunch`),
`Sources/VMLabMCP/Handlers/VMLifecycleHandler.swift`, `Sources/VMLabMCP/Tools/VMLifecycleTool.swift`,
`Tests/UnitTests/Engines/EnginesTests.swift` (the fake engine), `Tests/UnitTests/MCP/Handlers/VMLifecycleHandlerTests.swift`,
`Tests/UnitTests/Core/DebugTests.swift`,
`Tests/IntegrationTests/DebugIntegrationTests.swift`, `docs/AGENT.md`, `docs/ARCHITECTURE.md`

The owner's decision: QEMU reloads its in-memory copy of `-kernel`, `-initrd`, `-dtb`, `-bios` and
`-device loader` files on `system_reset`, so a rebuilt file is not seen. `reset` compares the files
with what `start` recorded and relaunches when they changed; an unchanged file keeps today's
in-process `system_reset`.

Acceptance:
- `start` of a QEMU guest whose `boot.mode` is `kernel`, `binary` or `firmware` records, in the
  runtime, each boot file the mode uses (`boot.kernel`, `boot.initrd`, `boot.dtb`,
  `boot.firmware`, `boot.binary`) as `runtime.bootFiles`: a JSON array of `{ "path", "size",
  "modified" (nanoseconds since the epoch, from `stat`), "inode" }`. VZ profiles record nothing:
  their `reset` is kill and start already, so a rebuilt file is always picked up there and every
  VZ reset reports `relaunched: true`.
- `vm_lifecycle reset` on such a guest: when every recorded file still has its size, modification
  time and inode, `system_reset` as today (`relaunched` absent). When any changed or is missing,
  the guest is killed and started again in one action under the VM's operation lock, through the
  same start path as `vm_lifecycle start` (the host-memory gate, the segment switch, the console
  run mark), so a new QEMU process serves the same VM id, name, record and `console.log`;
  `boot.haltAtStart` is honoured as at any start; the result carries `relaunched: true` and a
  warning naming the changed files; `state` is `running`. A start that fails (the file is gone)
  fails the reset with that start's error and leaves the VM `stopped`.
- A runtime recorded before this change (no `bootFiles`) resets as today, with a warning that the
  boot files could not be compared; `disk` boots never relaunch.
- A `vm_debug` session attached across a relaunch follows the guest eagerly, in the reset handler
  before it returns (not on the next `vm_debug` call, which would insert an entry breakpoint after
  the kernel ran past it): the stub's address changes with the process, so the session drops its
  old connection, connects to the new endpoint, inserts every saved point again, and leaves the
  CPU stopped at its first instruction when `haltAtStart` is set, else running (as `afterReset`
  does for an in-process reset). `vm_debug info` after the relaunch shows the new endpoint.
- Breakpoints a session set are listed unchanged by `vm_debug breakpoints` after either kind of
  reset.
- `docs/TOOLS.md` says what `reset` does for file boots (`relaunched?` in the result shape);
  `docs/AGENT.md` tells the model to call `reset` after a rebuild.

Verify: `swift test --filter VMLifecycleHandlerTests` (fake engine: unchanged files → `reset` only;
a touched file → kill and start, `relaunched: true`; a deleted file → the reset fails and the
record is `stopped`; an old runtime without `bootFiles` → `system_reset` and the warning; a `disk`
boot → never compared), `swift test --filter DebugTests` (a session re-inserts its points on a new
endpoint); `VMLAB_INTEGRATION=1 swift test --no-parallel --filter
DebugIntegrationTests/resetRelaunchesARebuiltKernel` (integration: the W1 kernel with message A,
`image: "none"`, `boot.haltAtStart: true`, `require: ["serial", "gdb", "halt_at_start", "net_none"]`;
`vm_debug registers` shows the CPU halted; a hardware breakpoint at `0x40080000`, the kernel's
entry; `continue`, then `wait` stops at the breakpoint; `continue` again and `vm_serial wait` sees
A; overwrite the file with message B; `reset` → `relaunched: true` and `vm_debug info` shows a new
endpoint; `breakpoints` still lists the point; `continue`, `wait` stops at the same breakpoint;
`continue` and `vm_serial wait` sees B); `scripts/check.sh`.

### W5 — The `cpu_emulation` feature (R-1204, size M, depends on: W1)

Files: `Sources/VMLabCore/Features.swift`, `Sources/VMLabCore/Capabilities.swift`,
`Sources/VMLabCore/Selector.swift` (the TCG note; nothing else should need to change),
`Sources/VMLabCore/ExtraSpec.swift` (the `-icount` hint), `REQUIREMENTS.md` Appendix A, B and I,
`Tests/UnitTests/Core/FeaturesTests.swift`, `Tests/UnitTests/Core/CapabilitiesTests.swift`,
`Tests/UnitTests/Core/SelectorTests.swift`, `Tests/IntegrationTests/QEMUTCGIntegrationTests.swift`,
`docs/FEATURES.md`, `docs/TOOLS.md` (regenerated), `docs/AGENT.md`, `docs/ARCHITECTURE.md`

The owner's decision: the feature is named `cpu_emulation`, kind compute, summary "The guest CPU is
emulated in software: deterministic `-icount`, instruction tracing, any CPU model; many times
slower than hardware virtualization".

Acceptance:
- `cpu_emulation` is in Appendix A, in Appendix B (`vz-macos` N, `vz-linux` N, `qemu-hvf` N, each
  with the reason "the engine runs the guest CPU natively"; `qemu-tcg` Y), in `Capabilities.swift`,
  in `docs/FEATURES.md` and in the `require` and `prefer` enums of every tool schema
  (`docs/TOOLS.md`).
- Selection: a Linux arm64 request with `require: ["cpu_emulation"]` lands on `qemu-tcg` with the
  existing slow note; `require: ["cpu_emulation", "gdb", "serial", "halt_at_start"]` too;
  `prefer: ["cpu_emulation"]` with no `require` lands on `vz-linux` with `preferredDenied:
  ["cpu_emulation"]` (rule 7 of Appendix I: a preference never moves a native guest onto an emulated
  CPU); a macOS guest requiring it is `unsatisfiable` with the reason. These rows are added to the
  Appendix I table and to `SelectorTests` in table order.
- `extra.qemuArgs` with `-icount` on a profile without `cpu_emulation` keeps failing as today, but the
  hint now says "require cpu_emulation".
- The resolved `features` of every `qemu-tcg` plan lists `cpu_emulation`; no other profile's does.

Verify: `swift test --filter FeaturesTests`, `--filter CapabilitiesTests`, `--filter SelectorTests`;
`VMLAB_INTEGRATION=1 swift test --no-parallel --filter QEMUTCGIntegrationTests/bareKernelUnderEmulation`
(integration, `slow` tag: the W1 kernel with `require: ["cpu_emulation", "serial"]` and `image:
"debian-13-arm64"` (W3 may change that later); the plan's profile is `qemu-tcg` and the message
appears on serial within 120 seconds); `scripts/gen-docs.sh`; `scripts/check.sh`.

### W6 — `vm_memory_dump` writes to a path the model names (R-1205, size S, depends on: nothing)

Files: `Sources/VMLabMCP/Handlers/VMMemoryDumpHandler.swift`, `Sources/VMLabMCP/Tools/VMMemoryDumpTool.swift`,
`Sources/VMLabCore/PathPolicy.swift` (the doc comment only, unless a helper is missing),
`Sources/VMLabCore/FileTransfer.swift` (where `vm_file pull` checks and renames; reuse, do not copy),
`Tests/UnitTests/MCP/Handlers/VMMemoryDumpHandlerTests.swift` (new),
`Tests/IntegrationTests/QEMUIntrospectionIntegrationTests.swift`, `docs/AGENT.md`, `docs/ARCHITECTURE.md`

Acceptance:
- `vm_memory_dump` takes an optional `local`: an absolute host path for the dump file. It passes the
  write side of the path policy exactly as `vm_file pull`'s `local` does (under `/tmp`, `$TMPDIR`,
  `~/vmlab-files` or the owner's `writeRoots`; never a home dotfile, `~/Library` or `VMLAB_HOME`),
  and a refused path fails with the policy's error before the engine is asked. The parent directory
  must exist and not be a symlink (`invalid_request` otherwise, as a pull). A `local` naming an
  existing directory puts the dump's default file name inside it; one naming an existing file
  replaces it.
- The handler hands the engine a temporary name (`<final>.part`) in the destination directory and
  renames the file into place itself when the dump completes, so a partial dump is never left
  under the final name and a symlink planted at the final name after the check is not followed
  (the R-1102 rule for pulls); the engine's `dump` is unchanged.
- Without `local` the dump goes under `<vm>/dumps/` as today. The result's `path` is where the file
  is.
- `vmlab gc` leaves files written through `local` alone (they are not under the VM directory).
- The tool summary, `docs/TOOLS.md` and `docs/AGENT.md` (the ptah-style "copy it out before destroy"
  advice becomes "pass local") say so.

Verify: `swift test --filter VMMemoryDumpHandlerTests` (a fake dumper: default path; `local` under
`$TMPDIR`; `local` under `~/.ssh` refused; a missing parent refused; a directory `local`; an
existing file replaced; the fake sees a `.part` name and the result's `path` is the final name; a
symlink planted at the final name is replaced, not followed), `swift test --filter
GarbageCollectorTests` (a dump outside the VM directory is not an item); `VMLAB_INTEGRATION=1 swift test
--no-parallel --filter QEMUIntrospectionIntegrationTests/dumpToLocalPath` (integration,
`debian-13-arm64` on `qemu-hvf`: a 1 MB range to a `$TMPDIR` path is the size asked and starts with
the bytes `vm_debug read_memory` returns for the same address); `scripts/check.sh`.

### W7 — Agent guide session 6: iterate on a bare-metal kernel (R-1206, size M, depends on: W2, W3, W4, W6)

Files: `docs/AGENT.md`, `Tests/IntegrationTests/AgentGuideTests.swift`, `docs/ARCHITECTURE.md`

Acceptance:
- `docs/AGENT.md` gains "Session 6: Iterate on a bare-metal kernel", in the same call/result block
  format as sessions 1 to 5. Two VMs, because `boot.haltAtStart` is a create-time setting: `kern`
  for the run loop and `kern-dbg` (the same request plus `boot.haltAtStart: true`) for the
  debugger. The loop on `kern`: `vm_plan` then `vm_create` with `image: "none"`, `boot.mode:
  kernel`, `network.mode: none`, `require: ["serial", "gdb", "halt_at_start", "introspection",
  "memory_dump", "net_none"]` and `autostart: false`; `start`; `vm_serial wait` for
  `poweroff|panic`, whose documented block shows `matched: "kernel A: poweroff"` (the kernel's
  line arrives before the engine exits, so the match wins; the prose says a guest that stops
  without printing it returns `stopped: true` instead); `vm_serial read` after the guest stopped,
  showing the whole run; a rebuild, then `reset` with `relaunched: true` and `wait` matching
  `kernel B: poweroff`. Then `kern-dbg`: `start`, `vm_debug registers` (halted), a hardware
  breakpoint at `0x40080000`, `continue`, `wait`, `registers`, `vm_memory_dump` of 4096 bytes at
  `0x40080000` with `local` under `/tmp`, `vm_introspect status`, and `destroy` of both. The prose
  says why each call is made and which fields to read (`stopped`, `relaunched`, `offset`), that
  a different command line or halt setting is a different VM (both are in the record) while a
  rebuilt file is the same VM, and that `reset` is the call after a rebuild.
- The session names the kernel as `/Users/me/kernel/build/kernel.img`. `AgentGuideTests` gains a
  pre-seeded variable: the session text uses `{{kernel}}` where the call blocks need the path
  (the prose shows the example path), the test seeds `vars["kernel"]` with a file it wrote with
  W1's helper (message `kernel A: poweroff\n`, `.powerOff`) before the first call, and overwrites
  that file with message `kernel B: poweroff\n` immediately before the first `vm_lifecycle` call
  whose `action` is `reset` (a hook keyed on tool and action, in `AgentGuide.run`). Every call then
  runs and every result block is checked as for sessions 1 to 5.
- `guideSessionsAreWellFormed` (its numbers list and `titles` dictionary extended to 6) and
  `resultBlocksMatchAsDocumented` cover session 6; the "which channel for which job" table mentions
  reading the console of a stopped guest.

Verify: `swift test --filter AgentGuideTests` (the two unit checks); `VMLAB_INTEGRATION=1 swift test
--no-parallel --filter AgentGuideTests/session6` (integration, no pulled image); `scripts/check.sh`.

### W8 — Switches and test homes are collected (R-1207, size S, depends on: nothing)

Files: `Sources/VMLabCore/GarbageCollector.swift`, `Tests/UnitTests/Core/GarbageCollectorTests.swift`,
`Tests/IntegrationTests/LabHome.swift`, `Tests/IntegrationTests/IntegrationGate.swift`,
`Tests/IntegrationTests/AgentGuideTests.swift` (`makeHome`/`cleanUp` use the same teardown),
`docs/ARCHITECTURE.md`, CLAUDE.md ("Sharing the machine", one sentence)

On the development host two `vmlab-switch` processes from a worktree deleted two days earlier were
still running, 216 empty `vmlab-test-*` homes sat in `$TMPDIR`, and `~/.vmlab/locks` held 90 lock
files for VMs that no longer exist; `vmlab gc --dry-run` reported nothing.

Acceptance:
- `EngineProcess.isSwitch(path)` (new, beside `isEngine`, which does not change) is true for an
  executable named `vmlab-switch`; `ProcessInspector` gains nothing, `GarbageCollector` uses the
  new predicate for switches.
- `vmlab gc` in its home ends the switch of a segment whose `segments/<name>/switch.pid` names a
  live `vmlab-switch` whose `VMLAB_HOME` argument or environment is this home, when the segment's
  own manifest lists no member (`SegmentStore` `members` empty) and no VM record has `segment ==
  name` with a live state; it removes `segments/<name>/` when the segments manifest has no entry
  for `name` and the directory is older than `grace`. Each is reported as `orphan_process` or
  `orphan_directory` with `vm` set to the segment name. A segment with a member in its manifest, a
  live VM record naming it, or a manifest entry and no running switch, is left alone.
- `vmlab gc` removes, for an id with no record and no `vms/<id>/` directory, the files
  `locks/<id>.lock`, `locks/<id>.op.lock` and `locks/<id>.qmp-events.lock` (and any other
  `locks/<id>.*.lock`), reporting them under a new `stale_lock` kind; files younger than `grace`,
  `store.lock`, `segments.lock`, `segment-<name>.lock`, `switch-<name>.lock`, `starts/admit.lock`
  and `starts/slot-<n>.lock` are left alone.
- `LabHome.shutdown()` already stops every segment switch of the home before removing it, and stays
  so; the leak comes from runs that were killed before teardown. So: once per test process, before
  the first integration admission (`IntegrationAdmission.start`) and before the first `LabHome`
  is made (a `static let` evaluated from both), the harness sweeps `vmlab-test-*` directories under
  both `/tmp` and `FileManager.default.temporaryDirectory` (the integration homes live under
  `/tmp`, unit-test homes under the other) whose newest file is older than 24 hours: it ends the
  processes their `vms/*/qemu.pid`, `vms/*/vz.pid` and `segments/*/switch.pid` name when the pid
  runs an engine (`isEngine`, arguments in that home, as `gc` checks) or a switch (`isSwitch`,
  `VMLAB_HOME` that home), then removes the directory, printing one line per home. Homes younger
  than a day, and any pid it cannot confirm, are left. The sweep is a `GarbageCollector` entry
  point (`GarbageCollector.sweepTestHomes(roots:olderThan:processes:)`) so a unit test with a fake
  `ProcessInspector` covers it; the harness only calls it.

Verify: `swift test --filter GarbageCollectorTests` (a fake `ProcessInspector`: an orphan switch is
ended; a switch with a manifest member, or with a live VM record, is kept; a segment directory
with no manifest entry goes after `grace`, a young one stays; stale locks go, young locks and the
store, segment and start-gate locks stay; the sweep over a synthetic stale home with a fake engine
pid and a fake switch pid ends both and removes it, and leaves a young home and a home whose pid
is not confirmed);
`VMLAB_INTEGRATION=1 swift test --no-parallel --filter SegmentIntegrationTests` (integration: still
green); `scripts/check.sh`.

## Open questions and decisions

Decisions the owner made on 2026-10-21:

- **Reset after a rebuild** (W4): relaunch when the boot files changed, keep `system_reset` when
  they did not, same call and result shape with `relaunched: true` added. Rejected: warn only (the
  model would still have to kill and start, and ptah's rule would stay), and always relaunching
  file boots (a reset for debugging the same kernel would lose QEMU's in-process state and take
  longer).
- **A bare machine** (W3): the reserved image name `"none"`. Rejected: an omitted `image` meaning
  none for file boots (a kernel over the Debian root disk is the original `direct_kernel_boot`
  use, and existing requests would change), and leaving it (the pull, the seed and the OS-only
  features in the plan mislead the model).
- **Emulation** (W5): a new feature named `cpu_emulation`. Rejected: `emulated_cpu` (same meaning),
  and no feature (TCG stays unreachable on arm64).

Planner's choices, with the alternative rejected:

- `vm_serial wait` reports a power-off as a result (`stopped: true`), not an error: a guest that
  halts is the expected end of a kernel test run, not a failure, and the model needs the text either
  way. Rejected: a new error code (Appendix D would grow for a non-error).
- `vm_memory_dump` gains `local` under the pull policy, mirroring `vm_file pull`. Rejected: keeping
  dumps after `destroy` (where? for how long?) and a `vm_file pull` of the dump (the file is on the
  host already).
- `image: "none"` ignores `diskGB` with a note rather than failing: a model that copies the resources
  block from another request should not be refused for it.
- `vmlab gc` does not reach into other homes. The leak came from the test harness; W8 fixes the
  harness and the home's own segments and locks.
- Session 6 uses two VMs rather than toggling `boot.haltAtStart`: the setting is in the record, and
  the guide should teach that, not work around it.
- A `/critique --depth quick` run on 2026-10-21 found the checkpoint contradiction on a bare
  machine, the exit-timing race in W2, the VZ gap in W4 and the test-home roots in W8; all are
  folded in above.

What a worker should do on meeting a question not settled here: build the smaller reading, say so
under **Decisions** in the pull request, and leave the pull request open for the owner.
