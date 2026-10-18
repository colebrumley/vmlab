# Architecture

vmlab is one Swift package. A model talks MCP over stdio to `vmlab serve`; the MCP layer and the CLI
are thin adapters over `VMLabCore`, which chooses an engine for each guest and drives it through the
`Backend` protocol. State lives on disk under `VMLAB_HOME` (Appendix F), so guests outlive the server.
Constraint C3 is enforced by `Tests/UnitTests/BoundariesTests.swift`: Core imports no engine and no
MCP module, and `VMLabMCP` and `vmlab` import no backend module; `vmlab` reaches the engines only
through `VMLabEngines` (which also registers the RFB display connector behind Core's `DisplayConnector`).

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
`CodeSignature` reads `codesign` output so `vmlab doctor` can say whether the runner is entitled. `Profile` names the four profiles with their Appendix B tiers. `HostProbe` gathers `HostFacts` (Appendix E fast facts) through an injectable `CommandRunning` and merges the slow probes persisted in `VMLAB_HOME/host-facts.json` (`SlowProbes`), resetting to `unknown` any probe recorded under another macOS or QEMU version; `ProbeResult.countsAsYes` is how selection reads a probe (unknown counts as no). `SlowProbeRunner.swift` is the slow probe registry: an item that owns a probe (`SlowProbe.owner`: R-307, R-309, R-608, R-702) conforms a `SlowProbeRunner` and calls `SlowProbeRunners.register`; `SlowProbeRegistry.runAll` runs them one at a time, persists each `yes` or `no` to `host-facts.json`, and reports a probe with no runner as `not_implemented`, left as it was. `docs/FEATURES.md` does not read that file: its "verified on dev host" column reads the committed snapshot `docs/dev-host-facts.json` (same format), so a probe run in one worktree does not make `scripts/check.sh` fail in the others. Recording probe results in the docs means `scripts/gen-docs.sh --refresh-host-facts` (copies `VMLAB_HOME/host-facts.json` into the snapshot via the hidden `vmlab gen-docs host-facts`, then regenerates) and committing the snapshot with `docs/FEATURES.md`.
`Images.swift` holds the Appendix H catalogue (`ImageCatalogue.builtin`, decoded from JSON into `CatalogImage`) and `ImageStore`, an actor over `VMLAB_HOME/images/<name>/` that pulls (URLSession through an injectable `ImageDownloading`, checksum from the published `SHA512SUMS`/`SHA256SUMS`, qcow2 to raw with `qemu-img` through `CommandRunning`), lists and removes images and records `image.json` (`PulledImage`); a re-pull whose file still matches the published checksum is a no-op. `ImageStore.defaultHome()` resolves `VMLAB_HOME`.
`KernelImages.swift` adds direct-kernel-boot files to the store (R-305): `extractKernel` copies the newest `vmlinuz-*` with its initrd, `System.map` and `config` out of a pulled image's `/boot` into `images/<name>/kernel/` (recorded under the `files` keys `kernel`, `initrd`, `systemMap`, `config`, plus `kernelVersion`), and `registerKernel` records a host kernel (and initrd), as a `format: kernel` image when no disk is pulled under that name. `Ext4.swift` (`Ext4Volume`) reads GPT partitions and ext4 (extents, block maps, linear and hashed directories, symlinks) read-only, because macOS has no ext4 driver for `hdiutil` to mount; an image without `disk.raw` is converted to a temporary raw file first. Debian's `System.map` is a stub that points at the `-dbg` package.
`ImageRegistration.swift` registers local images (R-1002): `registerDisk` copies a raw or qcow2 Linux disk (format from its header, `detectFormat`) into `images/<name>/`, adds the qcow2 QEMU overlays and, for arm64, the raw VZ boots, and records `image.json` with its SHA-256 and the login `vmlab`; `registerIPSW` runs `tart create --from-ipsw <ipsw> vmlab-image-<name>` (`tartCreateArguments`) and records a `tart` image whose `tartVM` is that local VM. Names in use (catalogue, pulled, registered) are refused.
`ImageCache.swift` is the cache policy (R-1003): `checkPullSize` refuses a pull whose catalogue `approxBytes` is over 10 GB (`confirmAboveBytes`, Appendix G) with `confirm_required` stating the size unless `confirm` is set (the images tool and `vm_create` pass theirs); `references(records)` is the set of image names VM records use and `unreferenced`/`prune` remove every pulled or registered image outside it (the images handler keeps everything when a VM record is unreadable, and asks for `confirm` above 10 GB); `sizes(of:)` measures allocated bytes, which `host_facts` reports as `imagesBytes`.
`CloudInit` builds the NoCloud seed both engines attach: from a plain `CloudInitConfig` (hostname, user, SSH key, packages, optional `GUIStack` (R-504: Xfce, LightDM autologin with `logind-check-graphical=false` since the cloud kernel has no DRM and X runs on fbdev, and x11vnc on port 5900 only when a VNC password is given; `GUIStack.inGuestVNC(vmDirectory:)` makes or reuses `<vm>/vnc.pass`), `SegmentNIC`, `GuestMount`s, `ConsoleDevice`, `dhcpIdentifierMAC` (a `network-config` NIC with `dhcp-identifier: mac`, so vmnet's lease file is keyed by the MAC), extra user-data merged last as a MIME part) it emits `user-data`, `meta-data` and `network-config` with a small hand-written YAML emitter (every string double-quoted; no YAML library, C5) and runs `hdiutil makehybrid` to make the `cidata` ISO. `FeatureDocs` renders `docs/FEATURES.md` from the matrix. It depends on swift-log only.
`Provision.swift` holds the request's `provision` (R-1001: `ProvisionSpec` with `packages`, `userData`, `runCommands`; stored on `VMRecord.provision`). On Linux `CloudInitConfig.provisioned(_:)` folds it into the seed (packages appended, user-data as the last MIME part, commands as files under `/var/lib/vmlab/provision/` that a runner script in `runcmd` executes in order, recording `<n> <exit> <ms>` in `steps.tsv` (`ProvisionPaths`, R-1004)); on macOS `runCommands` imply `exec_ssh`. `VMManager` hands every start whose guest answered SSH to a `GuestProvisioning` (`SSHProvisioner` by default), which, once per VM and only when the request had a `provision`, either waits for `cloud-init status --wait` and reads the runner's results back as root (Linux) or runs the commands one by one over `SSHExecChannel` (macOS), and records each step (`ProvisionStep`: command, status, exit, duration) in `<vm>/provision.json` (`ProvisionReport`) with their output in `<vm>/provision.log`. A failed step becomes a `provision_failed` start warning, and `vm_inspect` returns the report and the same warning (or `provision_unknown` when SSH never answered).
`Store.swift` holds the VM store: `VMRecord` (the `vm.json` of `vms/<id>/`, with `VMState`, `VMRuntime` endpoints, `CheckpointRef`s, the resolved `[Feature]` and the optional creating `Plan`), and `Store`, which lists, loads, creates (IDs `vm-` plus six base32 characters, unique names defaulting to the ID), updates and removes records under `VMLAB_HOME` (`Store.defaultHome`). Writes go through a temp file and `rename(2)` under a per-VM `flock` on `locks/<id>.lock` (names under `locks/store.lock`, always taken after a VM lock), so two server processes never corrupt or lose an update; `StoreMigrations` upgrades older `schemaVersion`s step by step, with one fixture per released version in `Tests/Fixtures/store/`. `Store.runningGuests()` is the counter `HostProbe.runningGuests` and the budgets read. `Tests/StoreHelper` builds `vmlab-store-helper`, a test-only executable (no product) that `StoreTests` spawns as the second writer.

`Lifecycle.swift` holds the lifecycle state machine: `Lifecycle.table` maps each `VMState` and `LifecycleAction` (start, stop, kill, pause, resume, reset, destroy, checkpoint_stop) to a `LifecycleTarget` (a state or `destroyed`); `Lifecycle.transition` throws `wrong_state` with `state` and `legalActions` for any other pair. It also holds reattach: `Store.reconcile(probe:)` checks each record's `runtime.pid` with an injectable `LivenessProbe` (default `kill(pid, 0)` plus a connect to the control or QMP unix socket), marks a live, answering engine `running`, and a gone or silent one `stopped` (`broken` when no `Store.diskCandidates` file exists, `suspended` kept), clearing `runtime` and logging a `lifecycle` event per change. The server calls it at start.
`Serial.swift` holds `SerialChannel`, an actor over a guest's serial unix stream socket (QEMU's `-serial unix:`, or the `vmlab-vz` bridge, R-602), engine-neutral so both backends share it. `start(connectTimeout:)` connects (retrying while the socket is absent or refusing) and a reader thread feeds bytes in order to the actor, which appends them to `<vm>/serial.log` (`O_APPEND`, never truncated, rotated to `serial.log.1` past 64 MB) and a 4 MB `ByteRing` addressed by absolute byte offsets from the channel's first byte. `read(since:maxBytes:)` and `read(tail:)` return `SerialRead` (`text`, `start`, `offset`, `truncated` when bytes fell out of the ring or were cut); `write(_:)` sends UTF-8 and returns the end offset; `wait(for:since:timeout:)` matches a Swift `Regex` against output at or after `since` (default: the current end) and returns `SerialMatch` (`match`, `start`, `offset` after it), or `timeout`, `guest_unreachable` when the socket closes, `invalid_request` for a bad pattern. `setLineObserver` receives every completed `SerialLine` with its offsets (R-304's panic table hangs there). The socket descriptor is closed exactly once, by the reader, under the lock writes take.
`Backend.swift` holds the engine seam (R-105): `protocol Backend` (its `profile`; `create(_:plan:)`, `start` returning the `VMRuntime`, `stop`, `kill`, `pause`, `resume`, `reset` (default kill then start), `destroy`, and `attach(_:)` returning a `RunningVM`), every call taking the current `VMRecord` and throwing `VMLabError`. `protocol RunningVM` exposes the raw channel handles a backend provides (`serial: SerialChannel?`, `display: DisplayEndpoint?` (VNC unix socket or host:port, `Auth` none or a password file, `hostSide`), `gdb: GDBEndpoint?` (host, port; parses `tcp:` runtime strings), `introspection: (any Introspection)?` (`query(IntrospectionQuery) -> IntrospectionAnswer`: the named queries or raw `qmp`/`hmp`, answered as JSON or text), `memoryDump: (any MemoryDumper)?` (default nil; `dump(MemoryDumpRequest) -> MemoryDumpResult`, raw range or full ELF), `exec: any ExecChannel`, `checkpoints: any CheckpointProvider`; `CheckpointProvider` documents its `wrong_state`/`invalid_request` contract, and `Backend.checkpoints(_:)` returns one for a VM in any state, by default the attached VM's channel), and callers reach them only through `channel(_:)` with a typed `Channel` key (`.serial`, `.display`, `.gdb`, `.introspection`, `.memoryDump`, `.exec`, `.checkpoints`), which throws `capability_missing` (`feature`, `profile`, `channel`, `anyOf`, the `vm_plan` hint) unless the VM's granted features include one that grants the channel, and `guest_unreachable` when it was granted but the engine has not brought it up. `Display.swift` (R-503) says where each profile serves a screen: `DisplayEndpoint.forVM(_:vmDirectory:)` gives QEMU's VNC unix socket whenever the guest runs (`hostSide`), and for VZ guests the in-guest VNC server (Linux, R-504) or Screen Sharing (macOS, R-606) at the guest IP, port 5900, password file `<vm>/vnc.pass`, only when the plan *requested* a display feature (`Plan.requested`: the asked-for features the profile grants, as opposed to `features`, which holds every `yes`); `resolve` adds the refusals (`capability_missing`, `wrong_state`, `guest_unreachable`) and `json` is the `vm_inspect` form. The same file holds the engine-free seam of `vm_computer` (R-502): `protocol DisplaySession` (screen size, `screenshot(ScreenshotRequest) -> ScreenCapture` with format, quality, `maxEdge`, `DisplayRect` region and `diffFrom`, `pointer(x:y:buttons:)` with `DisplayButtons`, `press(chord)`, `type(text)`, `close`), `protocol DisplayConnector` that opens one on a `DisplayEndpoint`, and the process-wide `Displays.shared` registry (`DisplayConnectorRegistry`) that `VMLabEngines` fills, so the MCP layer drives displays without importing `VMLabRFB` (C3). `BackendRegistry` (a `Mutex`-guarded map from profile to backend) and its process-wide `Backends.shared`/`Backends.register(_:)` are how `vmlab` wires the engines. `VMManager.swift` is the actor that drives a VM through `Lifecycle`, `Store` and its `Backend`: `create(_:plan:)` stores the record (profile, features, resources from the plan) and has the backend create it, removing everything on failure or cancellation; `perform(_:on:)` checks the transition, calls the backend, re-checks the state under the VM's lock and records the target state and runtime (destroy kills a live guest, destroys and removes the directory), logging a `lifecycle` event or an `error` event; actions on one VM are serialized in-process; `attach(_:)` needs a running or paused VM. `Tests/UnitTests/Support/FakeBackend.swift` is the backend tests drive it with.
`SSH.swift` (R-400) is the engine-neutral shell channel's setup: `SSHKeys` makes `<vm>/id_ed25519`
(`ssh-keygen -t ed25519 -N ""`, which `VMManager.create` runs for every new VM, before the backend
builds the seed) and names `known_hosts`; `SSHEndpoint` is where sshd answers (from `VMRuntime`: the
forwarded loopback `sshPort`, else `ip`:22; `Backend.sshEndpoint(_:timeout:)` defaults to that and a
backend that learns its address later overrides it); `SSHTarget` adds the image's login user
(Appendix H) and the VM directory and builds the `ssh` argument vector (`-i`, `BatchMode=yes`,
`StrictHostKeyChecking=accept-new`, `UserKnownHostsFile=<vm>/known_hosts`, `HostKeyAlias=<id>`,
keepalives). `GuestReadiness`/`SSHReadiness` retry `ssh true` every 2 s; `VMManager.run(_:on:)`
(which `perform` wraps) records a started `exec_ssh` guest `running` with its runtime, then waits
under the VM's lock up to `ResourceLimits.bootTimeout` (180/300/900 s) and returns an `Outcome` whose
`warnings` carry `ssh_unreachable` when it never answered. `SSHExec.swift` holds `SSHExecChannel`
(`ExecChannel.ssh(target)`), which runs a command with output streamed to scratch files under
`<vm>/exec/` and maps an `ssh` failure (status 255 with ssh's own message) to `guest_unreachable`.
`ExecRequest` (R-401) carries `cwd`, `env`, `user`, `via` (`ExecVia`) and the timeout;
`ExecResult` adds `durationMs`, `truncated`, `logPath`. `RemoteShell.swift` writes the POSIX text
sent to the guest: every model value single-quoted, the command (`cd`, `export`, then the user's
`$SHELL -c`) run in a process group of its own (`setsid -w`, else `perl` `setpgrp` for macOS
guests) that records its id in `/tmp/vmlab-exec-<uid>/<job>/pgid`, under `sudo -n -u <user> -H`
when `user` is not the login user; at the deadline the channel ends the local `ssh` and a second
connection runs `RemoteShell.kill` (TERM, then KILL, of the group), and the refusal is `timeout`
with the partial output. `ExecOutput` keeps each stream inline up to 64 KB, else its first 16 KB
and last 48 KB around a marker, with the whole output moved to `<vm>/exec/<job>.log`.
`ExecJobs.swift` (R-402) is the process-wide actor of background jobs (`ExecJobs.shared`): a job
(`ExecJob`, kept in `<vm>/exec/<job>.json` with its read offset and status) runs in the guest under
`nohup` in its own process group, output to `/tmp/vmlab-exec-<uid>/<job>/out`, status to `rc`
(`RemoteShell.background`). A reader (`RemoteShell.follow`: `tail -c +<n> -f` until `rc` exists,
replacing any reader an earlier server left) appends to `<vm>/exec/<job>.log` (`O_APPEND`); when
it reports the status, `RemoteShell.collect` fetches what it had not passed on and removes the
guest's files. `read` returns up to 64 KB of log past the offset (on a UTF-8 boundary), starting a
reader when this process has none, which is how a job survives a server restart; `wait` polls;
`kill` runs `RemoteShell.kill` (status 143). `stopReaders()` drops this process's readers.
`Manifest.swift` (R-801) holds guest manifests: `GuestManifest` (files keyed by path with kind,
size, octal mode, mtime and sha256 up to 8 MB; packages, services, users and defaults as key →
value maps; login items and configuration profiles as lists), stored by `Store.saveManifest` at
`<vm>/manifests/<id>.json` (`m-` and twelve hex digits). `GuestManifests.take` runs
`ManifestScript` (POSIX `sh`, passed as an argument with stdin closed, `sudo -n` for walks and
system queries when allowed) over the VM's exec channel: each section is the raw output of one
command (`stat`, `sha256sum`/`shasum`, `dpkg-query`/`rpm`, `systemctl`, `getent`, `defaults
export`, `brew`, `launchctl`, `profiles`, `dscl`, LaunchAgents and `osascript` login items)
between `@@vmlab section` markers, read back from the exec log when the output was cut, and
`ManifestParser` turns it into the manifest (`custom` records only the roots).
`ManifestDiff.swift` (R-802) compares two manifests key by key into sorted added/removed/changed
entries per section (files name each attribute that changed: kind, mode, size except for
directories, sha256, and mtime only when neither side has a hash), warns when the profiles or
roots differ, and is saved whole by `Store.saveManifestDiff` at
`<vm>/manifests/diff-<from>-<to>.json`.
`HostProcess` runs one host subprocess asynchronously (stdin bytes, output to file handles, a
deadline that sends `SIGTERM` then `SIGKILL`, cancellation likewise).
`Checkpoints.swift` is the checkpoint tree (R-800): `CheckpointTree` (`<vm>/checkpoints.json`: `CheckpointNode`s in creation order with `id` (`cp-` plus six base32 characters, the engine snapshot tag), unique `name`, `parent`, `mode`, `createdAt`, the VM `state` at creation, `manifestPath?`, `note?`, `temporary`; the `current` node; the `resume` node of a suspended VM), read and written by `Store.checkpoints(of:)` and `Store.updateCheckpoints(of:_:)` under the VM's lock, which also rewrites `vm.json`'s `checkpoints` summary. `VMManager.createCheckpoint` (auto is live when `checkpoint_live` was granted and the guest is live, else disk; a running guest without it is `wrong_state`, never an implicit stop), `restoreCheckpoint` (the restored node becomes current), `deleteCheckpoint` (children only with `recursive`, deepest first; current passes to the nearest surviving ancestor) and `checkpoints(of:)` drive the engine through `Backend.checkpoints(_:)`; `@latest` names the newest node. `checkpoint_stop` (`VMManager.perform`) takes a temporary live checkpoint, kills the engine and leaves the VM `suspended` with `resume` set; starting it boots the engine and restores that checkpoint (an engine that restores natively should leave `resume` unset). `GuestManifestTaker` is the R-801 hook: `VMManager(manifests:)` (`ToolContext` passes `CheckpointManifests`); without one, or when the manifest fails (a stopped guest), `manifest: true` is a warning and no `manifestPath`.
`Capabilities` is the Appendix B matrix: `Capabilities.entry(feature, on: profile)` gives the unresolved cell (`Availability.yes`, `.no(reason)` or `.conditional(Condition)`, where a `Condition` names a fast fact such as `root` or a `SlowProbe`, plus the note and the item that verifies a `?`), and `capabilities(of:host:allowUnverified:)` resolves every cell to yes or no against `HostFacts` (an `unknown` probe is no unless `allowUnverified`); `unverifiedProbes` says which probes a plan reports as unverified, and `supports(_:on:)` is the guest OS and arch filter.
`Selector.swift` is Appendix I: `select(_:host:running:allowUnverified:)` (also `ProfileSelector.select`, which takes `ResourceLimits`) normalises a `Requirements` (features implied by `network` and `boot` become required, Appendix G resources filled in), filters the four profiles by guest and by every required feature, applies the dynamic limits to the survivors in rank order and returns a `Plan` (profile, resolved resources, `features` = required plus every `yes`, `requested` = the asked-for subset, `preferredDenied`, `unverified`, notes, a startup estimate and `startupTier`; `provisionsDesktop` (R-504) is true for a Linux guest that requested `gui_desktop`, or `gui` on VZ, and adds `Plan.desktopInstallSeconds` (300) to the estimate, one to the tier and a note) or an `Unsatisfiable` (per-feature `eliminated` with reasons, minimal drop `suggestions` up to size 3 and at most five, the `unverified` probes in the way, or the `limit` error) whose `error` is the Appendix D refusal. `Limits.swift` holds `ResourceLimits` (reserve 4 GB, two macOS guests, four parallel starts; `defaultResources(for:)`, `checkMacOSGuests`, `checkMemory`, which R-107 reuses before a start) and `Inventory`, the live guests (profile, OS, memory) built from `VMRecord`s or `Store.inventory()`. `StartGate.swift` (R-107) is admission to a start: the `StartGating` protocol (`admit(_:running:host:)` returns a `StartPermit`, `release(_:)`, `withStart`) and `StartGate`, the in-process actor (`StartGate.shared`) that holds a FIFO semaphore of `parallelStarts` slots and, once a slot is held, runs `ResourceLimits.check` against the running inventory plus the guests of starts already admitted (deduplicated by id), so concurrent starts cannot overrun the memory or macOS budget. R-1100 makes it cross-process by conforming another type to `StartGating`.
`CloudInit` builds the NoCloud seed both engines attach: from a plain `CloudInitConfig` (hostname, user, SSH key, packages, optional `GUIStack`, `SegmentNIC`, `GuestMount`s, `ConsoleDevice`, `dhcpIdentifierMAC` (a `network-config` NIC with `dhcp-identifier: mac`, so vmnet's lease file is keyed by the MAC), extra user-data merged last as a MIME part) it emits `user-data`, `meta-data` and `network-config` with a small hand-written YAML emitter (every string double-quoted; no YAML library, C5) and runs `hdiutil makehybrid` to make the `cidata` ISO. `FeatureDocs` renders `docs/FEATURES.md` from the matrix, with a last column from the committed slow-probe snapshot `docs/dev-host-facts.json` (never `VMLAB_HOME`). It depends on swift-log only.

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
image. `VMRecord.extra.qemuArgs` (R-306, `ExtraSpec` in Core, which refuses vmlab's own
options) go last and verbatim when the plan grants `custom_devices`. Networking (R-308): one
`-netdev user` NIC (none for `net_none`) forwards a fresh loopback port to guest 22
(`runtime.sshPort`) and every request forward; `QEMUBackend.resolveForwards` binds a port for each
`host: nil`, and `VMRuntime.forwards` records the ports chosen (shown as `endpoints.forwards`). A request that
asks for `net_fast` (`Plan.requests`; granted only as root or when the `qemu_vmnet` probe said
yes) gets `-netdev vmnet-shared` instead, with no forwards; `QEMUVmnetProbe` starts a throwaway
edk2 guest with that NIC and answers `no` when QEMU cannot create the vmnet interface. Architectures
(R-310): `qemu-system-<target>` per arch (aarch64, x86_64 on `q35`, riscv64, or an `other` name
under `-machine virt` with no CPU model, firmware or display devices); TCG caps `-smp` at
`ProfileSelector.maxTCGCPUs` (8), and the plan says so.
`QMPClient` (an actor over a `QMPTransport`; `UnixQMPTransport` reads on its own thread) does
the greeting and `qmp_capabilities`, matches replies to `vmlab-<n>` ids (QMP errors become
`engine_error`, silence `timeout`, a closed socket `guest_unreachable`) and broadcasts events to
every `events()` stream; reconnecting is `connect(socketPath:)` again once the previous client has
gone (QEMU greets one client at a time). `QEMUMachine` prepares the overlay, EFI vars and seed,
daemonizes QEMU (output to `qemu.log`, with `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES`: the
forked daemon otherwise aborts on its first `snapshot-save` under HVF), connects QMP and the `SerialChannel` while the CPU is
halted, then sends `cont` unless `haltAtStart`; `attach` reconnects from the pid file, `powerdown`
sends `system_powerdown` and waits for the process to exit, `kill` sends `quit` then `SIGKILL`.
`QEMUBackend` is the `Backend` for `qemu-hvf` and `qemu-tcg`: it keeps a `QEMUMachine` per running
guest (reattaching after a server restart), builds the seed when R-400's `id_ed25519.pub` exists (with the desktop, no VNC server, when the stored plan provisions one, R-504),
and hands out `QEMURunningVM` (serial, VNC display, GDB, QMP `query-*` introspection,
checkpoints, memory dumps, exec over SSH through the forwarded loopback port (`SSHExecChannel`)). `QMPIntrospection`
maps `status`/`block`/`pci`/`cpus` to `query-status`/`query-block`/`query-pci`/`query-cpus-fast`
and `memory_tree`/`registers`/`devices` to HMP `info mtree`/`info registers -a`/`info qtree`, and
allows raw only for `query-[a-z0-9-]+` and `info <words>` (anything else `invalid_request`);
`QMPMemoryDumper` runs `pmemsave` for a range and `dump-guest-memory` (ELF, no paging) for all. `QEMUCheckpoints` (also from
`Backend.checkpoints(_:)`, which needs no running guest) keeps checkpoints as qcow2 internal
snapshots of `disk.qcow2` tagged with the checkpoint id: `qemu-img snapshot -c/-a/-d` while the
guest is stopped, the QMP jobs `snapshot-save`/`snapshot-load`/`snapshot-delete` on the `disk0`
node (memory and disk; polled with `query-jobs`, then dismissed) while it runs, when live is
allowed (TCG, `checkpoint_live` granted, or `qemu_hvf_live_snapshot` yes); a mode the state cannot
serve is `wrong_state`, never an implicit stop or start. `QEMULiveSnapshotProbe` is that slow
probe: an image-free HVF guest (an empty qcow2, so edk2 drops to its UEFI shell on serial) saved,
loaded and typed at; `VMLabEngines.Engines.registerProbes()` registers it for `vmlab doctor --probe`.

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
runner builds from (`linux(record:vmDirectory:boot:seed:)`: CPUs, memory, `Boot` `.efi` with
`efi-vars.bin` or `.linuxKernel`, `disk.raw` then `seed.iso` read-only, a NAT NIC with
`stableMAC(for:)` (an FNV-1a hash of the id, locally administered) unless the network is `none`,
console to `console.log`, the balloon, `Graphics` only when `gui` was granted).
`MachineDecisions.swift` resolves a config against `VZMachineLimits` into `VZMachineDecisions`, the
plain device list the runner materialises one to one (snapshotted in `Tests/Fixtures/vz/`), and
holds `MACAddress.normalize`. `DHCPLeases` parses `/var/db/dhcpd_leases` (macOS drops leading zeros
per octet) and finds the newest unexpired lease by MAC. Create reuses (or makes) Core's
`SSHKeys` pair for the seed. `VZRunnerLauncher` checks the runner's entitlement
(`host_missing_tool` with `signingHint`), writes the config and starts `vmlab-vz run <vm>` with
`Process` (own process group, stdin `/dev/null`, output appended to `vz.log`), then waits for
`status` to say `running` (or `stopped` with `hold`); a runner that dies first reports its error as
a `vmlab-vz-error: <json>` line in `vz.log`. `VMLabVZ.attach(socketPath:)` / `attach(runtime:)`
reconnect by socket path alone. `VZBackend` (profile `vz-linux`) conforms to Core's `Backend`:
create clones the pulled raw image to `<vm>/disk.raw` and writes the VM's key and `seed.iso`
(image login user, console `hvc0`, DHCP by MAC, and when the plan provisions a desktop the R-504 `GUIStack` with its x11vnc password in `<vm>/vnc.pass`), start launches and waits up to `leaseTimeout` for
the lease, recorded as `runtime.ip`, stop/kill wait for the runner to exit; `VZRunningVM` offers exec over SSH to the leased address (`SSHExecChannel`) and no serial, display or checkpoint channel yet (R-602, R-503, R-605; its display endpoint is Core's `DisplayEndpoint.forVM`, which `vm_computer` and `vm_inspect` use directly).

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
`StartGating` gate of one `VMLAB_HOME`, the `DisplaySessions` actor (one display session per VM, held for the server's life, with the pointer position last sent and the last screenshot's geometry for `scaled: true`; each session holds that VM's screenshot cache), plus the call's `progress` and `heartbeat` interval. A `ToolResult` is the Appendix C result object (always with
`warnings`) plus image blocks; `ToolRendering` turns results and `VMLabError`s into JSON (the MCP text)
or a terminal line. Built so far: `host_facts`, `host_doctor` (checks with `detail` and `fix`, the runner and its
entitlement, the probes with owner and date; `probe: true` runs `SlowProbeRunners.shared`),
`vm_plan` (an unsatisfiable request is a result with `satisfiable: false`, never an error),
`vm_list`, `vm_inspect` (the record, the creating `Plan` that `VMManager.create` stores in
`VMRecord.plan`, features, endpoints, the last 20 events, the latest `panic` event or null),
`vm_logs` (events rendered one per line, tails of `serial.log` and `provision.log`; `all` is each
source in turn, prefixed), `vm_create` (plan, pull the image if missing, `VMManager.create`, then
start unless `autostart: false`; all or nothing: a cancelled or failed call destroys the VM),
`vm_lifecycle` (start/stop/kill/pause/resume/reset/destroy; clone waits for R-803; a start's
`ssh_unreachable` warning comes from `VMManager.Outcome`), `vm_exec` (R-401: validates the
request into an `ExecRequest`, picks the channel by `via` (`Channel.execSSH`, `.execAgent`,
`.exec`) on `VMManager.attach`, runs it under a heartbeat and returns `exitCode`, `stdout`,
`stderr`, `durationMs`, `truncated`, `logPath`; `background: true` starts an `ExecJobs` job over
the VM's `SSHExecChannel` and returns `{ job }`), `vm_job` (read/wait/kill: `output`, `finished`,
`exitCode`, `more`, `logPath`), `vm_manifest` (R-801: `profile` defaults to the guest's OS,
`custom` needs `paths`; a running VM only; returns `{ id, path, profile, counts }` with the
manifest's warnings), `vm_checkpoint diff` (`Handlers/CheckpointDiff.swift`, R-802: each side
is `@now`, taken with the other side's profile and roots, a manifest id, or a checkpoint whose node
has a manifest; sections capped at 500 entries with the counts and `truncated`, the whole diff's
`path`), `images`
(list/pull/remove), `vm_computer` (`Handlers/VMComputerHandler.swift`, R-502: resolves the VM's
`DisplayEndpoint`, gets its session from `ToolContext.displays`, and maps the computer-use actions
onto pointer, key and type events; clicks move first, double and triple clicks repeat 60 ms apart,
drags hold the left button over eight steps, scroll strikes wheel buttons; coordinates are checked
against the screen and, with `scaled: true`, mapped through the last screenshot as origin +
pixel / scale; every acting action sleeps `settleMs` and returns a fresh screenshot), `vm_introspect` (an `IntrospectionQuery` to the attached VM's `introspection`
channel; `raw` takes exactly one of `qmp`/`hmp`; returns `{ query, json | text }`) and
`vm_memory_dump` (the `memory_dump` channel writes to `<vm>/dumps/<UTC time>-0x<addr>-<size>.raw`
or `<UTC time>.elf`; a range over 256 MB without `confirm: true` is `confirm_required` with
`bytes`). Long calls (R-205) go through `Handlers/LongOperation.swift`: an image pull and
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
`destroy`, `exec` and `job` (`Sources/vmlab/ExecCommands.swift`: stdout to stdout, stderr and a
non-zero status to stderr), `images pull|list|remove`, `computer <vm> <action>` (`--at x,y`, `--out` writes the image), `introspect`, `memory-dump`, `serve`, `--version`. It bootstraps logging and hands off to Core and `VMLabMCP`.

**`VMLabEngines`** (library). The engine wiring, and the only module that imports both Core and the
backends for that purpose: `Engines.registerAll(store:into:displays:)` registers `QEMUBackend` for `qemu-hvf`
and `qemu-tcg` and `VZBackend` for `vz-linux` in `Backends.shared` (or a given `BackendRegistry`),
and `RFBDisplayConnector` in `Displays.shared`. `RFBDisplay.swift` is Core's `DisplaySession` over
`VMLabRFB`: `RFBDisplaySession` (an actor) connects with the endpoint's password file, waits for the
first frame, keeps the VM's `ScreenshotCache` across reconnects (a dropped connection is reopened on
the next call) and maps `RFBError` to Appendix D codes (bad requests and key names
`invalid_request`, unreachable or refused displays `guest_unreachable`, protocol trouble
`engine_error`).
`vmlab` calls it once in `main`, before any command runs, so `serve` and every tool subcommand can
create and start guests; `Engines.registerProbes(into:)` likewise fills `SlowProbeRunners.shared`
with the engines' slow probes (`VMLabQEMU.probeRunners`). `vz-macos` joins `Engines.profiles` when `VZBackend` runs macOS guests.
`BoundariesTests` checks that it imports only Core, QEMU, VZ and RFB and that no library imports it.

**`vmlab-vz`** (executable). The VZ runner: one process per Virtualization.framework guest, so a
guest outlives the server. `vmlab-vz run <vm-dir> [--hold]` writes `vz.pid`, builds the machine from
`vz-config.json` (`ConfigurationBuilder` materialises `VZMachineDecisions`: generic platform,
`VZEFIBootLoader` with its variable store or `VZLinuxBootLoader`, virtio-blk raw disks, NAT
virtio-net with the MAC, a virtio console on two pipes (`ConsolePipes`; the runner appends guest
output to `console.log`, R-602 bridges them to `serial.sock`), entropy, the balloon, and with `gui`
virtio graphics plus USB keyboard and pointer; a missing entitlement at `validate()` is
`host_missing_tool`), owns the `VZVirtualMachine` on the main queue (`Runner`) and
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
`sign.sh`, `bootstrap.sh` (Homebrew: qemu, tart), `gen-docs.sh` (`--check` for check.sh;
`--refresh-host-facts` copies this host's slow probes into `docs/dev-host-facts.json`, the only
input of FEATURES.md that is not code), and the process scripts
`board.mjs`, `tidy.mjs`, `review.mjs`, `retro.mjs` and `guard.mjs` (the worktree-rule hook)
described in CLAUDE.md.
