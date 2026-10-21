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
and `EventLog.latestPanic()` reads the newest. Wiring: every serial channel a backend opens (QEMU's in `QEMUMachine.connect` through `ConsolePanicWatch`, VZ's in `VZSerialChannels`) gets one detector before it starts. QEMU's serial chardev also writes `<vm>/console.log` itself (`logfile=`, `logappend=on`), as the VZ runner does, so output survives while no vmlab process holds the socket; `ConsolePanicWatch` (both engines) first scans that log from `<vm>/console.scan` to its end, then has the channel, which counts in the same log, hand it lines from there on (`SerialChannel.observeLines(from:)`; the position is saved at each panic line and on disconnect). `console.log` is not rotated by vmlab (the engine holds it open); a channel without a console log still writes `serial.log` with R-303's 64 MB rotation (`SerialChannel.watchForPanics`; line observers are additive, `addLineObserver`), `QEMUBackend.watch` forwards the connection's QMP events (`QEMUBackend.forward`, only while holding `locks/<id>.qmp-events.lock`, so two servers log each event once), and `vmlab serve` attaches every live guest at start (`VMManager.monitorLiveGuests`). On vz-linux a disk boot passes `console=hvc0` itself (`DiskBoot`), so a first-boot panic is seen there too; only one before the virtio console driver loads is not (no early console), and a guest that fell back to EFI has the kernel console on hvc0 only from the second boot (cloud-init's GRUB drop-in). Also process-wide logging (`VMLabLogging`: swift-log to stderr at the `VMLAB_LOG` level, default `info`).
`CodeSignature` reads `codesign` output so `vmlab doctor` can say whether the runner is entitled. `Profile` names the four profiles with their Appendix B tiers. `HostProbe` gathers `HostFacts` (Appendix E fast facts) through an injectable `CommandRunning` and merges the persisted slow probes (`SlowProbes`), resetting to `unknown` any probe recorded under another macOS or QEMU version; `ProbeResult.countsAsYes` is how selection reads a probe (unknown counts as no). Slow probes are host facts, so they live in one host-wide file, `SlowProbes.hostFile`: `~/.vmlab/host-facts.json` whatever `VMLAB_HOME` says (`VMLAB_HOST_FACTS` names another, empty for none), set by `vmlab` at startup and nil by default, so unit tests never read the real host's file; a home's own `host-facts.json` is read only as an override of answered probes (`SlowProbes.effective`), and a fresh home sees every probe at once. `SlowProbeRunner.swift` is the slow probe registry: an item that owns a probe (`SlowProbe.owner`: R-307, R-309, R-608, R-702) conforms a `SlowProbeRunner` and calls `SlowProbeRunners.register`; `SlowProbeRegistry.runAll` runs them one at a time, persists each `yes` or `no` to the host-wide file (and to the home's own file when it has one, so an old override does not hide the answer), and reports a probe with no runner as `not_implemented`, left as it was. `docs/FEATURES.md` does not read that file: its "verified on dev host" column reads the committed snapshot `docs/dev-host-facts.json` (same format), so a probe run in one worktree does not make `scripts/check.sh` fail in the others. Recording probe results in the docs means `scripts/gen-docs.sh --refresh-host-facts` (copies the host-wide `host-facts.json` into the snapshot via the hidden `vmlab gen-docs host-facts`, then regenerates) and committing the snapshot with `docs/FEATURES.md`.
`Images.swift` holds the Appendix H catalogue (`ImageCatalogue.builtin`, decoded from JSON into `CatalogImage`) and `ImageStore`, an actor over `VMLAB_HOME/images/<name>/` that pulls (URLSession through an injectable `ImageDownloading`, checksum from the published `SHA512SUMS`/`SHA256SUMS`, qcow2 to raw with `qemu-img` through `CommandRunning`), lists and removes images and records `image.json` (`PulledImage`; a Tart image runs `tart pull` and records the ref to clone as `tartVM`); a re-pull whose file still matches the published checksum is a no-op, a concurrent pull of one image joins the one under way, and `remove` or a pull that would replace the disk refuses (`checkUnused`, `invalid_request` with `vms`) while `users(of:)` finds a VM whose `image` or `backingChain` reads it, or a record cannot be read. `ImageStore.defaultHome()` resolves `VMLAB_HOME`.
`KernelImages.swift` adds direct-kernel-boot files to the store (R-305): `extractKernel` copies the newest `vmlinuz-*` with its initrd, `System.map` and `config` out of a pulled image's `/boot` into `images/<name>/kernel/` (recorded under the `files` keys `kernel`, `initrd`, `systemMap`, `config`, plus `kernelVersion`), and `registerKernel` records a host kernel (and initrd), as a `format: kernel` image when no disk is pulled under that name; both store a gzip kernel uncompressed (`Gzip.swift`, RFC 1952 over Foundation's raw DEFLATE, because `VZLinuxBootLoader` takes only an `Image`, R-604). `ImageStore.resolvingBoot(_:image:)` is the boot spec both backends start from: a kernel boot without a kernel takes the image's kernel and initrd (extracted on first use), and every path the mode uses must be readable. `Ext4.swift` (`Ext4Volume`) reads GPT partitions and ext4 (extents, block maps, linear and hashed directories, symlinks) read-only (superblock geometry validated, offsets overflow-checked, sizes and extent trees capped, so a crafted image is an `engine_error`), because macOS has no ext4 driver for `hdiutil` to mount; an image without `disk.raw` is converted to a temporary raw file first. Debian's `System.map` is a stub that points at the `-dbg` package. `DiskBoot.swift` finds what a Linux disk boots by default (for `vz-linux` disk boots, which pass `console=hvc0` themselves): the default entry of `grub.cfg` (`GrubConfig`: menu entries and submenus, a literal `set default=`, `linux`/`initrd` lines with GRUB variables dropped) on any ext4 partition, else the `/vmlinuz` and `/initrd.img` links or the newest `vmlinuz-*` with `/etc/default/grub`'s command line and `/etc/fstab`'s root; `DiskBoot.stage(disk:cache:)` copies the kernel (gzip decompressed, checked to be an arm64 `Image`) and the initrd(s, concatenated) into a cache directory with a `boot.json` of their sources' inode, size, mtime and ctime, reused while they match, and returns the command line with `console=hvc0` last. It reads the disk as is, without replaying the ext4 journal, as GRUB does.
`Templates.swift` (R-804): `ImageStore.createTemplate(_:from:vmDirectory:)` turns a stopped Linux VM into `images/<name>/` (built in `.<name>.partial/` and renamed): a QEMU overlay flattened with `qemu-img convert` to `disk.qcow2` and then `disk.raw`, or a VZ `disk.raw` cloned and converted to qcow2, so either engine can create from it; `image.json` gets `PulledImage.template` (`TemplateInfo`: source VM, base image, `revokedKeys`, provisioned features) and the base image's login. macOS cannot write ext4, so the parent's key stays on the template's disk: `CloudInitConfig.applyTemplate` gives each child a `bootcmd` that deletes `revokedKeys` from the login user's and root's `authorized_keys` before sshd starts (cloud-init then authorizes the child's own key, the new `instance-id` regenerating host keys) and skips `apt-get update`. `images template_create` / `vmlab images template create <vm> <name>` call it; `vm_create image: <template>` needs nothing more.
`Segments.swift` (R-901): `SegmentStore` over `VMLAB_HOME/segments/<name>/` (`segment.json` = `Segment`: subnet index `n` for `10.n.0.0/24`, lowest free from 1, `auto` for a fleet's own, `SegmentMember`s in join order from `.10`), locked per segment (`locks/segment-<name>.lock`, `segments.lock` for a new index). `VMManager.create` joins a VM whose request names `network.segment` (making the segment if needed) and stores `VMRecord.segment` (`SegmentAttachment`: address, `/24`, a MAC from `SegmentAttachment.mac(for:)`, `52:54:5e` prefix); `run(.start)` first calls `startSwitch`, which launches `vmlab-switch <name>` detached with `VMLAB_HOME` (output to `switch.log`) under `locks/switch-<name>.lock` and waits until its sockets exist; destroy leaves the segment. `SegmentStore.destroy` refuses a segment with members (`wrong_state`) and otherwise stops the switch (SIGTERM, then SIGKILL) and removes the directory. Both seeds carry the static address as `CloudInitConfig.segment` (`SegmentNIC`, NICs matched by MAC). A `vz-macos` member gets the segment NIC from `VZRunnerConfig.macOS(record:clone:config:segmentAttachSocket:)` and its address from `MacProvisioner.segment`: provisioning writes `segmentScript` to `/tmp/vmlab-segment.sh` and runs it under sudo (interface by MAC from `ifconfig`, its service from `networksetup -listnetworkserviceorder`, created if missing, then `networksetup -setmanual`), recorded as the `segment_script` and `segment_address` steps. The `net_segment` handler (`Handlers/NetSegmentHandler.swift`) and `vmlab segment create|list|destroy` sit on it.
`SegmentHosts.swift` (R-902): after a segment member's start answers SSH (and after a member's destroy) `VMManager.publishNames` rewrites, on every running member with an SSH endpoint, one marker-delimited `/etc/hosts` block (`# vmlab segment <name> begin|end`, a line `<ip> <name> <name>.<segment>` per member) through the injectable `SegmentNaming` (`SSHSegmentHosts`: as root, lines on stdin, under `flock` in the guest, in parallel); a join and a leave are the same idempotent rewrite, cloud-init's boot-time `/etc/hosts` is fixed again by the next start, and a member that does not answer yet is logged rather than warned (its own start publishes). `vm_inspect` lists `segments` (segment, subnet, ip, MAC, names).
`Fleets.swift` (R-903): `FleetRecord` in `VMLAB_HOME/fleets/<name>.json` (`FleetStore`: the one plan, image, segment, `autoSegment`, and `FleetMember`s with their VM id, `VMLabError` and start warnings) and `FleetPlanning` (`memberNames` `<name>-1..n`, `checkName` (a fleet name is also its auto segment's: `[a-z0-9-]`, at most 28), `checkBudget`: `limit_macos_guests` and `limit_memory` for every member at once). `VMRecord.fleet` names a member's fleet (`vm_list fleet:` filters on it). `VMManager.run(_:on:force:sshTimeout:)` lets a caller shorten the SSH wait. `Handlers/FleetHandler.swift` runs `fleet create` (plan once, budget, pull, make or join the segment, save the record, then create and start every member in parallel under the start gate (`LongOperation.start`), a failure or `ssh_unreachable` becoming that member's `error`; a cancelled create destroys it all), `status`, `list`, `exec` (R-904: `VMExecHandler.request` reads the same options as `vm_exec`, run on every member or `members` in parallel through each VM's exec channel; `results` maps member to `vm_exec`'s object or `{ error }`, `allSucceeded` when every one exited 0) and `destroy` (every member VM in parallel and never with `force`, in rounds so dependents inside the fleet go first; a member it cannot destroy, such as one whose disk backs a VM outside the fleet, is listed in `failed` and kept in the record, and the auto segment and the record go only once every member has); `vmlab fleet create|list|status|exec|destroy`. `VMManager.publishNames` skips members busy with another action in this process, so a fleet destroy never reopens a removed VM directory over SSH.
R-905: `VMInspectHandler.forwards` is where the host reaches each requested guest port: a QEMU guest's loopback `hostfwd` port (`host` and `hostReachable` both `127.0.0.1:<port>`), a VZ guest's NAT address with no mapping (`host: null`, `hostReachable: <ip>:<guest port>`); `vm_inspect` and `vm_create` endpoints and `fleet status` members carry it, and `vm_create` adds `forwarding` (`mode: hostfwd | host_reachable` with a note), warning `forwards_not_mapped` when a VZ request named a host port.
`ImageRegistration.swift` registers local images (R-1002): `registerDisk` copies a raw or qcow2 Linux disk (format from its header, `detectFormat`) into `images/<name>/`, adds the qcow2 QEMU overlays and, for arm64, the raw VZ boots, and records `image.json` with its SHA-256 and the login `vmlab`; `registerIPSW` runs `tart create --from-ipsw <ipsw> vmlab-image-<name>` (`tartCreateArguments`) and records a `tart` image whose `tartVM` is that local VM. Names in use (catalogue, pulled, registered) are refused.
`ImageCache.swift` is the cache policy (R-1003): `checkPullSize` refuses a pull whose catalogue `approxBytes` is over 10 GB (`confirmAboveBytes`, Appendix G) with `confirm_required` stating the size unless `confirm` is set (the images tool and `vm_create` pass theirs); `references(records)` is the set of image names VM records use and `unreferenced`/`prune` remove every pulled or registered image outside it (the images handler keeps everything when a VM record is unreadable, and asks for `confirm` above 10 GB); `sizes(of:)` measures allocated bytes, which `host_facts` reports as `imagesBytes`.
`Provision.swift` holds the request's `provision` (R-1001: `ProvisionSpec` with `packages`, `userData`, `runCommands`; stored on `VMRecord.provision`). On Linux `CloudInitConfig.provisioned(_:)` folds it into the seed (packages appended, user-data as the last MIME part, commands as files under `/var/lib/vmlab/provision/` that a runner script in `runcmd` executes in order, recording `<n> <exit> <ms>` in `steps.tsv` (`ProvisionPaths`, R-1004)); on macOS `runCommands` imply `exec_ssh`. `VMManager` hands every start whose guest answered SSH to a `GuestProvisioning` (`SSHProvisioner` by default), which, once per VM, either waits for `cloud-init status --wait` and reads the runner's results back as root (Linux with a `provision`), asks `cloud-init status --long` once without waiting (Linux without one, so the R-504 desktop install and the image's own modules are recorded too; `VMManager.collectFirstBoot`, which `vm_inspect` calls, asks again until cloud-init has finished; a guest without cloud-init gets a skipped step), or runs the commands one by one over `SSHExecChannel` (macOS with a `provision`), and records each step (`ProvisionStep`: command, status, exit, duration) in `<vm>/provision.json` (`ProvisionReport`) with their output in `<vm>/provision.log`. A failed step becomes a `provision_failed` start warning, and `vm_inspect` returns the report and the same warning (or `provision_unknown` when SSH never answered).
`Store.swift` holds the VM store: `VMRecord` (the `vm.json` of `vms/<id>/`, with `VMState`, `VMRuntime` endpoints, `CheckpointRef`s, the resolved `[Feature]`, the optional creating `Plan` and, for `vz-macos`, `tartClone`, the Tart clone's directory), and `Store`, which lists, loads, creates (IDs `vm-` plus six base32 characters, unique names defaulting to the ID), updates and removes records under `VMLAB_HOME` (`Store.defaultHome`). Writes go through a temp file and `rename(2)` under a per-VM `flock` on `locks/<id>.lock` (names under `locks/store.lock`, always taken after a VM lock), so two server processes never corrupt or lose an update; `StoreMigrations` upgrades older `schemaVersion`s step by step, with one fixture per released version in `Tests/Fixtures/store/`. `Store.runningGuests()` is the counter `HostProbe.runningGuests` and the budgets read. `Tests/StoreHelper` builds `vmlab-store-helper`, a test-only executable (no product) that `StoreTests` spawns as the second writer.

`Lifecycle.swift` holds the lifecycle state machine: `Lifecycle.table` maps each `VMState` and `LifecycleAction` (start, stop, kill, pause, resume, reset, destroy, checkpoint_stop) to a `LifecycleTarget` (a state or `destroyed`); `Lifecycle.transition` throws `wrong_state` with `state` and `legalActions` for any other pair. It also holds reattach: `Store.reconcile(probe:)` checks each record's `runtime.pid` with an injectable `LivenessProbe` (default `kill(pid, 0)` plus a connect to the control or QMP unix socket), marks a live, answering engine `running`, and a gone or silent one `stopped` (`broken` when no `Store.diskCandidates` file exists, `suspended` kept), clearing `runtime` and logging a `lifecycle` event per change. The server calls it at start. `EngineProcess.swift` is the check every engine's pid file goes through before a start refuses, a backend waits on a pid or SIGKILLs it (BH-3): `isRunning(pid, vmDirectory:)` wants a live process whose executable is `qemu-system-*` or `vmlab-vz` and, when its arguments can be read, one argument inside the VM's directory (canonical forms compared), so a stale `qemu.pid`/`vz.pid` naming a reused pid is not this VM's engine; `kill(pid, vmDirectory:)` signals only such a pid. `QEMUMachine.isAlive(_:in:)` and `VZBackend` use it. `running(in:)` finds the engine a VM directory's pid files (`EngineProcess.pidFiles`) name, and `killStranded(in:)` kills it (CX-14): a start that crashed between launching its engine and recording `runtime` leaves one, so `Store.reconcile` (through `LivenessProbe.killStranded`), `VMManager`'s start and `vmlab gc` kill an engine running for a record with no runtime when they can take the VM's operation lock (a holder may be starting it); a start whose final record update fails kills what it launched. `Store.recordEngineExit` is how a backend that saw its engine exit records `stopped`: QEMU on a QMP `SHUTDOWN` or a monitor hang-up (`QEMUBackend.recordHangUp`, `broken` when QEMU still runs), vz-linux from a kqueue `NOTE_EXIT` source on the runner pid (`VZExitWatchers`, armed at start and attach).
`DeadPeer.swift` (R-1101) is dead-peer detection on the engine sockets: `DeadPeer.window` (5 s, Appendix G) and `probeInterval` (1 s); `PeerClock`, which a client's reader feeds (`received`) and its writer charges (`awaiting(what)`), answers `overdue(window:)` with the reason once an answer has been owed for the window; `DeadPeer.error` is `guest_unreachable` with `data.deadPeer`, `channel`, `endpoint`, `reason`. The clients: `QMPClient.watchPeer` probes an idle connection with `query-status` and declares the peer dead when any command but `longRunningCommands` (memory dumps) goes unanswered for the window (pending calls fail, the connection closes, `QEMUBackend` marks the VM broken and drops the machine); a watched client keeps `<vm>/qmp-busy.<pid>.<n>` while it has a long command out, and a watchdog that sees another live process's marker postpones the debt (`PeerClock.postpone`), since a dump stalls every monitor (CX-24); a peer that closes the connection itself calls `watchPeer(onClosed:)` once; `RFBClient.start(deadPeerWindow:)` sends a one-pixel non-incremental update request to a quiet server (a still screen answers nothing to incremental ones) and `connect` bounds the handshake (`RFBError.deadPeer`; only a `hostSide` display maps to `DeadPeer.error`, an in-guest VNC server's silence says nothing about the engine); `GDBClient` treats a missed ack or reply (`replyTimeout` = the window) as death, closes, records `deadPeerReason` and calls `onDeadPeer` (waiting for a running target is not); `VZControlClient` probes `status` on a second connection while a command longer than the window runs and abandons the command when a probe goes unanswered, and an unwatched command (`status`) that met silence for the whole window is a dead peer too unless `vz.pid` shows the runner gone. `Store.markBroken(id:reason:)` turns a live VM `broken` with `VMRecord.brokenReason` and a `lifecycle` warning; `VMManager` and `ToolHandlers.call` call it for any dead-peer error, a kill clears the reason, `Store.reconcile` leaves a broken VM whose engine still lives broken, and `QEMUBackend.kill` of a broken VM sends `SIGKILL` without touching QMP.
`PathPolicy.swift` (R-1102) holds `VMLabConfig` (`VMLAB_HOME/config.json`; `allowAnyPath`, `ignoreMemoryPressure`, `allowHostCode` and `writeRoots` are read, and a missing or malformed file means the safe defaults) and `PathPolicy`, which every model-supplied host path passes with an `Access`: reads (`vm_file push`'s `local`, `images register`'s `path`, `kernel` and `initrd`, `boot.kernel`, `initrd`, `dtb`, `firmware` and `binary`, which may also lie under `VMLAB_HOME/images/`) against `roots` (the user's home, `/tmp`, `$TMPDIR`), writes (`vm_file pull`'s destination, a share's `host`, checked at create and again at every backend's start, and the QEMU paths `ExtraSpec.HostPath.access` marks written) against `writeRoots` (`/tmp`, `$TMPDIR`, and `~/vmlab-files`, created on demand, or instead the owner's `writeRoots`; `~` expands). `neverWritten` refuses a write inside `VMLAB_HOME`, `~/Library` or any dot component under the home even with `allowAnyPath`; comparisons fold case and Unicode normalisation (APFS). vmlab's own writes into its VM directories do not pass through it. `SSHFileTransfer.pull` with a `local` checks the final destination (with the remote's base name), copies into `<vm>/pulled/.staging-*` and `renameat`s the result into the destination directory opened with `O_NOFOLLOW_ANY` (a cross-volume `EXDEV` falls back to an `openat(O_NOFOLLOW)` copy), so a symlink planted after the check is replaced, never followed. Image names are single path components (`ImageStore.checkName`, run by `Requirements`, `vm_create`/`fleet` and `images`), and `ImageStore.pulled` returns nil for a record whose `files` leave its directory. `check(_:field:access:)` requires an absolute path, canonicalises it (`canonical` resolves component by component as the kernel does, so a `..` after a symlink climbs from its target, and a dangling link's target counts) and refuses with `invalid_request` (`field`, `path`, `resolved`, `access`, `allowedRoots`, and for a never-written path `reason`; the hint names `writeRoots` and the config file) one outside its access's roots, unless `allowAnyPath`. `vm_memory_dump`'s `local` (R-1205) goes through the same `LocalDestination` (`FileTransfer.swift`: the policy's write check, an existing directory receiving the default name, a parent opened with `O_NOFOLLOW_ANY`, and `move`, the `renameat` into it): the engine writes `<final>.part` in a fresh `.staging-*` folder under `<vm>/dumps/` (never through the model's path, which a symlink could redirect) and the handler renames it into the checked directory. `Tests/UnitTests/HostShellTests.swift` greps `Sources` so that no host process is a shell: a shell literal may appear only in the guest-side files (`RemoteShell`, `Manifest`, `GuestAgentExec`, whose `sh -c` runs in the guest with quoted words) and in cloud-config data, and `system`, `popen`, `posix_spawn`, `exec*` and `NSTask` never appear. `ExtraSpec` refuses `-run-with` and holds `-plugin` and `-semihosting` to `allowHostCode`.
`Serial.swift` holds `SerialChannel`, an actor over a guest's serial unix stream socket (QEMU's `-serial unix:`, or the `vmlab-vz` bridge, R-602), engine-neutral so both backends share it. `start(connectTimeout:)` connects (retrying while the socket is absent or refusing). Both backends pass `consoleLog:` (`<vm>/console.log`, which the engine appends every guest byte to whether or not anyone holds the socket): then offsets are byte offsets into that file, the same in every process (each `vmlab serial` CLI call, the MCP server, a restarted server). `start` loads the file's tail into a 4 MB `ByteRing` based at the file's offset (`ConsoleFile`, read-only, `pread`), and the channel follows the file, woken by each socket chunk (the socket's bytes themselves are dropped) and polled every 25 ms (`followInterval`, since the engine logs a chunk just after sending it); `read` and `wait` below the ring's start read the file, so `startOffset` is 0 and nothing is `truncated` but by `maxBytes`. The log spans every boot of the VM; nothing rotates it. Without `consoleLog` (unit tests), a reader thread feeds socket bytes in order to the actor, which appends them to `serial.log` (`O_APPEND`, never truncated, rotated to `serial.log.1` past 64 MB) and the ring, offsets counting from the channel's first byte. `read(since:maxBytes:)` and `read(tail:)` return `SerialRead` (`text`, `start`, `offset`, `truncated` when bytes fell out of the ring or were cut); `write(_:stallTimeout:)` sends UTF-8 on a `vmlab.serial.writer` thread, off the actor, and returns the end offset, failing with `timeout` once the guest has taken no byte for the stall timeout (10 s); `wait(for:since:timeout:)` matches a Swift `Regex` against output at or after `since` (default: the current end) and returns `SerialMatch` (`match`, `start`, `offset` after it), or `timeout`, `guest_unreachable` when the socket closes, `invalid_request` for a bad pattern. A pattern that is a plain literal (`SerialMatcher.literal(of:)`: no regex syntax but escaped punctuation, like `login:` or `\$ `) is found byte for byte with `memmem` on the actor, linear and with no helper. No other pattern runs in the server: Swift `Regex` backtracks and cannot be interrupted (even `.*x` is quadratic, minutes on 64 KB), so each such wait gets a `vmlab-match` helper process (`SerialMatcher.swift`: `MatchHelperProcess`, launched through `Process` with no arguments, stdin and stdout pipes and the length-prefixed framing documented on `SerialMatcher`; the helper writes `R` once it runs). Each channel keeps one spare helper started ahead of need (at `start`, and again whenever a wait takes it), because the first exec of a freshly built or installed binary can take a second or more on a busy host while macOS checks it; time a wait's scans spent waiting for their helper to start is added to its deadline (`expire`, at most `maxLaunchGrace`, 10 s), so a slow spawn never makes an ordinary pattern time out. The helper compiles the pattern once and answers window after window of at most 64 KB (the backlog, then new output plus a 4 KB re-scan, at most one scan per waiter every `rescanInterval`, 25 ms, once caught up, so trickling output costs a round trip per interval, not per byte). A `vmlab.serial.match` thread blocks on each round trip, off the actor; when the wait ends (match, timeout, cancel, `stop`, the guest gone) the helper gets `SIGKILL` and Foundation reaps it, so a runaway pattern leaves no CPU busy and no process behind (`matcherPIDs` lets tests check). A channel runs at most `maxMatchers` (4) helpers; further waits queue for a free one rather than being refused. The helper is found once per process by `SerialMatcher.locate`: `VMLAB_MATCH_HELPER`, else beside the running executable (also with symlinks resolved), else beside the bundle Core is linked into (the test bundle in `.build/<config>/`); `SerialChannel(matcherPath:)` overrides it, and a missing or broken helper is `engine_error` (`data.tool` `vmlab-match`; a literal pattern needs none). Patterns over 1 KB, or with a nested unbounded quantifier (`(a+)+`), are still refused up front: the timeout would contain them, but refusing spares a helper that would only burn a core until the deadline. `Sources/vmlab-match/main.swift` is the helper (`SerialMatcher.serve`; `--self-test` for `release.sh`). `setLineObserver` receives every completed `SerialLine` with its offsets (R-304's panic table hangs there). The socket descriptor is non-blocking and closed exactly once, by the reader, under the lock each `send` takes; `SocketSend` (also used by `UnixQMPTransport`) never holds that lock across a wait for the peer, so `stop` always proceeds.
`Backend.swift` holds the engine seam (R-105): `protocol Backend` (its `profile`; `create(_:plan:)`, `start` returning the `VMRuntime`, `stop`, `kill`, `pause`, `resume`, `reset` (default kill then start), `destroy`, `stop(_:grace:)` (default: `stop`), and `attach(_:)` returning a `RunningVM`), every call taking the current `VMRecord` and throwing `VMLabError`. `protocol RunningVM` exposes the raw channel handles a backend provides (`serial: SerialChannel?`, `display: DisplayEndpoint?` (VNC unix socket or host:port, `Auth` none or a password file, `hostSide`), `gdb: GDBEndpoint?` (host, port; parses `tcp:` runtime strings), `introspection: (any Introspection)?` (`query(IntrospectionQuery) -> IntrospectionAnswer`: the named queries or raw `qmp`/`hmp`, answered as JSON or text), `memoryDump: (any MemoryDumper)?` (default nil; `dump(MemoryDumpRequest) -> MemoryDumpResult`, raw range or full ELF), `exec: any ExecChannel`, `checkpoints: any CheckpointProvider`; `CheckpointProvider` documents its `wrong_state`/`invalid_request` contract, and `Backend.checkpoints(_:)` returns one for a VM in any state, by default the attached VM's channel), and callers reach them only through `channel(_:)` with a typed `Channel` key (`.serial`, `.display`, `.gdb`, `.introspection`, `.memoryDump`, `.exec`, `.checkpoints`), which throws `capability_missing` (`feature`, `profile`, `channel`, `anyOf`, the `vm_plan` hint) unless the VM's granted features include one that grants the channel, and `guest_unreachable` when it was granted but the engine has not brought it up. `Display.swift` (R-503) says where each profile serves a screen: `DisplayEndpoint.forVM(_:vmDirectory:)` gives QEMU's VNC unix socket whenever the guest runs (`hostSide`), and for VZ guests the in-guest VNC server (Linux, R-504) or Screen Sharing (macOS, R-606) at the guest IP, port 5900, password file `<vm>/vnc.pass`, only when the plan *requested* a display feature (`Plan.requested`: the asked-for features the profile grants, as opposed to `features`, which holds every `yes`); `resolve` adds the refusals (`capability_missing`, `wrong_state`, `guest_unreachable`) and `json` is the `vm_inspect` form. The same file holds the engine-free seam of `vm_computer` (R-502): `protocol DisplaySession` (screen size, `screenshot(ScreenshotRequest) -> ScreenCapture` with format, quality, `maxEdge`, `DisplayRect` region and `diffFrom`, `pointer(x:y:buttons:)` with `DisplayButtons`, `press(chord)`, `type(text)`, `close`), `protocol DisplayConnector` that opens one on a `DisplayEndpoint`, and the process-wide `Displays.shared` registry (`DisplayConnectorRegistry`) that `VMLabEngines` fills, so the MCP layer drives displays without importing `VMLabRFB` (C3). `BackendRegistry` (a `Mutex`-guarded map from profile to backend) and its process-wide `Backends.shared`/`Backends.register(_:)` are how `vmlab` wires the engines. `VMManager.swift` is the actor that drives a VM through `Lifecycle`, `Store` and its `Backend`: `create(_:plan:)` stores the record (profile, features, resources from the plan) and has the backend create it, removing everything on failure or cancellation; `perform(_:on:)` checks the transition, calls the backend, re-checks the state under the VM's lock and records the target state and runtime (destroy kills a live guest, destroys and removes the directory), logging a `lifecycle` event or an `error` event; its `timeout` (`vm_lifecycle timeoutSeconds`) is a start's SSH wait and a stop's grace, after which a guest still up is killed with a warning; actions on one VM are serialized in-process; `attach(_:)` needs a running or paused VM. `Tests/UnitTests/Support/FakeBackend.swift` is the backend tests drive it with.
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
`AutoExecChannel.swift` (R-403) is `via: auto`, what `Channel.exec` now returns: SSH when it was
granted, and the agent (`RunningVM.agentExec`, default nil; `Channel.execAgent`) when it was
granted and SSH never reached the guest, which a channel marks with `data.connected: false` on its
`guest_unreachable` (`ExecFallback`; `SSHExecChannel` sets it only for connect-phase `ssh` errors,
so a command that started over SSH is never run twice). `ExecTimeout.error` is the shared
`timeout` refusal with partial output; `ExecFiles` and `ExecOutput.collect` are public for the
agent channel.
`FileTransfer.swift` (R-404) is `SSHFileTransfer`: the system `scp` in SFTP mode (`-s`, so a
guest path is never seen by a remote shell), `-r`, with `SSHTarget.options` (the key and
known-hosts options `ssh` shares); `push(local:remote:)` and `pull(remote:local:)` (no local:
`<vm>/pulled/<name>`, replaced; an existing local directory receives the copy inside it) return
`FileTransferResult` (`bytes` of every regular file, `path`), mapping an `ssh` failure to
`guest_unreachable` and any other `scp` error to `invalid_request` on `remote`.
`SharedDirSpec` (in `Features.swift`, R-404) is the request's `share` (`host`, absolute, default
`<vm>/shared/`; `guest`, default `/mnt/host`; tag `share0`), which implies `shared_dir` and is kept
as `VMRecord.share`; `SharedDirSpec.of(record)` is what a backend mounts: the record's `share`, or
the default when the plan *requested* `shared_dir` (every profile grants it, which alone mounts
nothing). Both engines put it in the seed as a `GuestMount`.
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
`OffPool.swift` keeps blocking work off Swift's cooperative pool (one thread per CPU, shared by
every tool call): `OffPool.run` runs a closure on a thread of its own (never
`DispatchQueue.global()`, which is as narrow) and suspends the caller, with an optional `onCancel`.
Blocking helpers that async code calls have an `async` overload built on it, which async callers
pick, so they cannot block by accident: `CommandRunning.run`, `SSHKeys.generate`,
`SegmentStore.destroy`, `QEMUMachine.run`/`prepare`, `QEMUImageSnapshots.tags`, `QEMUClone.info`,
`Tart.clone`/`setDiskSize`/`delete`, `VZRunnerLauncher.checkedRunner`; `ImageStore` runs on a
serial queue of its own (`unownedExecutor`). `Tests/UnitTests/Support/PoolSaturation.swift`
proves an API waits off the pool: twice as many callers as CPUs held six seconds by a silent peer
while a trivial task must still run within three.
Descriptors in tests: suites run in parallel in one process, so an fd closed twice or used after
its close hits another test's socket. Fake servers accept through
`Tests/UnitTests/Support/TestListener.swift` (Darwin's `close` does not wake a blocked `accept`;
the listener closes only once no thread is accepting). While any thread is in `posix_spawn`, the
half-made child holds a copy of every open descriptor for a few ms, so "the peer sees the close"
is waited for (`SpawnWindow.reachesEndOfFile`, `SpawnWindow.eventually`), never checked at once.
`Debug.swift` (R-701, R-705) is the engine-free debugger: `DebugPoint` (`address`, `DebugPointKind` software, hardware, watch_write, watch_read, watch_access, `size` for watchpoints), `DebugStop` (`reason` breakpoint, watchpoint, halted, step, signal or exited, `signal`, `thread`, `pc`, `watchAddress`) and `DebugRegister` (name, `0x` hex or nil); `protocol DebugTarget` is one live stub connection in all-stop mode and `protocol DebugConnector` opens one on a `GDBEndpoint` (`debug_busy` when the stub has another client). `DebugSession` (an actor, one per VM) owns the connection for this process rather than for a request: it connects on first use, follows the VM to a new endpoint, reconnects once when the stub closed the connection, adds and removes points on a running CPU by halting and resuming around them, names stops (a recorded breakpoint's pc is `breakpoint`, a SIGTRAP after a step is `step`, SIGINT is `halted`) and persists its points and the human's `symbolFile` in `<vm>/debug.json`, inserting every point again (remove, then insert) after a reconnect or a server restart (a point whose insert was sent but not confirmed is kept in `debug.json` as `pending` and removed from the stub on the next connect, and a failed add removes it at once, so the stub holds no point the session does not list), and after a reset (`afterReset(halted:)`, which `vm_lifecycle reset` calls: QEMU under HVF loses hardware breakpoints on `system_reset`; the CPU is left stopped for a `haltAtStart` VM, else running if it ran). A connect that finds the stub held by another client is `debug_busy` and sets `busySince` (cleared by the next connect that works), which `vm_debug info` reports instead of attaching. `DebugSessions` (`.shared`) holds the sessions and the registered connector; `vmlab` registers the GDB one through `VMLabEngines`. `Tests/UnitTests/Support/FakeDebugTarget.swift` is the scripted target tests drive it with.
`Checkpoints.swift` is the checkpoint tree (R-800): `CheckpointTree` (`<vm>/checkpoints.json`: `CheckpointNode`s in creation order with `id` (`cp-` plus six base32 characters, the engine snapshot tag), unique `name`, `parent`, `mode`, `createdAt`, the VM `state` at creation, `manifestPath?`, `note?`, `temporary`; the `current` node; the `resume` node of a suspended VM), read and written by `Store.checkpoints(of:)` and `Store.updateCheckpoints(of:_:)` under the VM's lock, which also rewrites `vm.json`'s `checkpoints` summary. `VMManager.createCheckpoint` (auto is live when `checkpoint_live` was granted and the guest is live, else disk; a running guest without it is `wrong_state`, never an implicit stop), `restoreCheckpoint` (the restored node becomes current), `deleteCheckpoint` (children only with `recursive`, deepest first; current passes to the nearest surviving ancestor) and `checkpoints(of:)` drive the engine through `Backend.checkpoints(_:)`; `@latest` names the newest node. `checkpoint_stop` (`VMManager.perform`) takes a temporary live checkpoint, kills the engine and leaves the VM `suspended` with `resume` set; starting it boots the engine and restores that checkpoint (an engine that restores natively should leave `resume` unset). `GuestManifestTaker` is the R-801 hook: `VMManager(manifests:)` (`ToolContext` passes `CheckpointManifests`); without one, or when the manifest fails (a stopped guest), `manifest: true` is a warning and no `manifestPath`.
`Clone.swift` (R-803): `VMManager.clone(_:name:from:)` makes a new `created` VM from a VM's current disk (the source must not be live) or from one of its checkpoints (any state but broken), with the source's plan, profile, image and network, a new id (so a new MAC: both engines derive it from the id) and a new SSH key (`SSHKeys`, as `create`), and the guest's memory not cloned. `Backend.clone(_:checkpoint:into:)` makes the disk and returns the files it reads through; the manager records them as `VMRecord.backingChain` with `VMRecord.clonedFrom` (`CloneOrigin`), and `VMManager.dependents(of:)` lists the VMs whose chain reads a file in another VM's directory. The cloud-init instance id is the VM id, so a clone's first boot runs the per-instance modules again and installs its own key.
`GarbageCollector.swift` (R-805) is `vmlab gc` (`Sources/vmlab/GCCommand.swift`, CLI only, `--dry-run`, `--json`): over one `VMLAB_HOME` it ends orphaned engine processes (a `qemu.pid`/`vz.pid` in a VM directory whose `vm.json` is gone, when `ProcessInspector` (`proc_pidpath`) says it is `qemu-system-*` or `vmlab-vz`, `EngineProcess.isEngine`, and `ProcessInspector.runsVM` says its arguments lie in that directory, so a stale pid reused by another VM's engine is spared) and removes that directory, ends an engine still running for a record with no runtime (`ProcessInspector.runsVM`, under the VM's operation lock, CX-14), removes `dumps/*` and `exec/*.log` older than 7 days, deletes temporary checkpoints (`VMManager.dropCheckpoint`, children move up) except a suspended VM's resume point, removes files in `<vm>/backing/` that no record's `backingChain` reads, and removes template images (`images/<name>/` whose `image.json` has `template`) that no record names as its `image` (the `images prune` rule) and no `backingChain` reads, once unchanged for 7 days (skipped when `images` is a link to a shared cache); anything younger than a 10-minute grace is spared, so a create or clone in another process is never collected. R-1207: it ends the switch of a segment no VM uses (no member in `segments/<name>/segment.json`, no record with a live state naming it, under a non-blocking hold of `segment-<name>.lock`) when `switch.pid` names a live `vmlab-switch` (`EngineProcess.isSwitch`) whose `VMLAB_HOME` environment is this home (`EngineProcess.isSwitchRunning`, which `ProcessInspector.runsVM` falls back to; `HostProcesses.environment` reads it from `KERN_PROCARGS2`), removes a segment directory with no manifest after the grace, and removes `locks/<id>.lock` and `locks/<id>.*.lock` (`stale_lock`) for a VM id with no record and no directory; locks whose stem is not a VM id (store, segments, segment, switch, start gate) are never touched. `GarbageCollector.sweepTestHomes(roots:olderThan:processes:)` is the test harness's broom: each `vmlab-test-*` directory whose newest entry is older than the limit loses its confirmed engines and switches and is removed, and one with a live engine or switch pid it cannot confirm is left; the integration harness runs it once per process (`TestHomeSweep` in `Tests/IntegrationTests/IntegrationGate.swift`, over `/tmp` and the temporary directory, 24 hours) before its first admission. It returns a `GCReport` (items with kind, target, allocated bytes; errors; `bytesFreed`). `VMManager.run(.destroy, force:)` refuses with `invalid_request` (field `force`, `dependents`) while `dependents(of:)` is not empty, and with `force` destroys anyway with a warning.
`Capabilities` is the Appendix B matrix: `Capabilities.entry(feature, on: profile)` gives the unresolved cell (`Availability.yes`, `.no(reason)` or `.conditional(Condition)`, where a `Condition` names a fast fact such as `root` or a `SlowProbe`, plus the note and the item that verifies a `?`), and `capabilities(of:host:allowUnverified:)` resolves every cell to yes or no against `HostFacts` (an `unknown` probe is no unless `allowUnverified`); `unverifiedProbes` says which probes a plan reports as unverified, and `supports(_:on:)` is the guest OS and arch filter. `cpu_emulation` (R-1204) is `yes` on `qemu-tcg` alone, so requiring it is how an arm64 guest reaches TCG; the selector's rank puts `qemu-tcg` last for arm64, so a preference for it is denied.
`Selector.swift` is Appendix I: `select(_:host:running:allowUnverified:)` (also `ProfileSelector.select`, which takes `ResourceLimits`) normalises a `Requirements` (features implied by `network` and `boot` become required, Appendix G resources filled in), filters the four profiles by guest and by every required feature, applies the dynamic limits to the survivors in rank order and returns a `Plan` (profile, resolved resources, `features` = required plus every `yes`, `requested` = the asked-for subset, `preferredDenied`, `unverified`, notes, a startup estimate and `startupTier`; `provisionsDesktop` (R-504) is true for a Linux guest that requested `gui_desktop`, or `gui` on VZ, and adds `Plan.desktopInstallSeconds` (300) to the estimate, one to the tier and a note) or an `Unsatisfiable` (per-feature `eliminated` with reasons, minimal drop `suggestions` up to size 3 and at most five, the `unverified` probes in the way, or the `limit` error) whose `error` is the Appendix D refusal. `Limits.swift` holds `ResourceLimits` (reserve 4 GB, two macOS guests, four parallel starts; `defaultResources(for:)`, `checkMacOSGuests`, `checkMemory`, which R-107 reuses before a start) and `Inventory`, the live guests (profile, OS, memory) built from `VMRecord`s or `Store.inventory()`. `StartGate.swift` (R-107) is admission to a start: the `StartGating` protocol (`admit(_:running:host:)` returns a `StartPermit`, `release(_:)`, `withStart`) and `StartGate`, the in-process actor (`StartGate.shared`) that holds a FIFO semaphore of `parallelStarts` slots and, once a slot is held, runs `ResourceLimits.check` against the running inventory plus the guests of starts already admitted (deduplicated by id), so concurrent starts cannot overrun the memory or macOS budget. `CrossProcess.swift` (R-1100) makes it cross-process: `FileLock` is an exclusive `flock` on a file under `locks/` (per open file, so it excludes within a process as across processes, and dies with its holder), with `isHeld` and `write` for what the holder publishes; `FileStartGate` is the `StartGating` `ToolContext.live()` uses: its slots are `locks/starts/slot-<n>.lock` (holding the admitted guest as JSON), and the limits are checked under `locks/starts/admit.lock` against the records plus every slot another holder has locked, so two `vmlab serve` processes share the slots, the macOS count and the memory budget. `HostMemory.swift` adds the host's own memory to every start: `HostMemoryGuard` (a `HostMemoryReading` plus the owner's escape hatch, `VMLAB_IGNORE_MEMORY_PRESSURE=1` or `ignoreMemoryPressure` in `config.json`) is the optional `hostMemory` of both gates, and `ToolContext.live()` gives the `FileStartGate` the live one. `LiveHostMemory` reads `kern.memorystatus_vm_pressure_level` (`sysctlbyname`), free + inactive + purgeable pages (`host_statistics64`) and the guest engine processes (`HostProcesses`: `proc_listallpids`, `proc_pidpath`, `KERN_PROCARGS2`), recognised by the `GuestProcessRecognizer`s the engine modules register (`VMLabQEMU.guestProcessRecognizer`: `qemu-system-*` with `-m`, directory from `-pidfile`; `VMLabVZ.guestProcessRecognizer`: `vmlab-vz run <vm>` with its `vz-config.json`) in `Engines.registerAll`, so Core names no engine. At admission `HostMemoryGuard.check` adds the host's guests that the budget does not already hold (`Inventory.addingHostGuests`, matched by pid or VM directory; `Inventory.Guest` carries both, `Store.startingGuest` sets the directory) before `ResourceLimits.check`, then `ResourceLimits.checkHostMemory` refuses with `limit_memory` at pressure `warn` or above or when available memory less the starts in flight is below the guest plus `reserveGB`. `FleetPlanning.checkBudget(hostMemory:)` does the same for a whole fleet. Tests pass `FixedHostMemory`. `VMManager.acquire` also takes `locks/<id>.op.lock` (`Store.operationLockPath`) for the whole of an action, so two servers never drive one VM at once. QEMU's QMP socket serves one client at a time, so every QEMU guest has two monitors, `qmp.sock` and `qmp2.sock` (`QEMULayout.secondaryQMPSocket`): the starting server holds the first, and `QEMUMachine.attach` connects to every monitor the guest has at once and keeps whichever greets (`connectFirst`), so a second server drives the guest through the other (each with its own events and dead-peer watchdog). A third concurrent server finds both held and gets `timeout`; the serial socket likewise serves the first server only. `Tests/IntegrationTests/TwoServersIntegrationTests.swift` runs two `vmlab serve` children over stdio.
`CloudInit` builds the NoCloud seed both engines attach: from a plain `CloudInitConfig` (hostname, user, SSH key, packages, optional `GUIStack` (R-504: Xfce, LightDM autologin with `logind-check-graphical=false` since the cloud kernel has no DRM and X runs on fbdev, and, only when a VNC password is given, x11vnc on port 5900 with X on the dummy driver at `GUIStack.vncScreen` (1280x800; `/etc/X11/xorg.conf.d/10-vmlab-dummy.conf`) because a VZ guest under the cloud kernel has no virtio-gpu driver and no EFI framebuffer; `GUIStack.inGuestVNC(vmDirectory:)` makes or reuses `<vm>/vnc.pass`), `SegmentNIC`, `GuestMount`s, `ConsoleDevice` (`ttyAMA0` on QEMU arm64, `ttyS0` on other QEMU arches, `hvc0` on VZ; a getty on it; with `rootConsole`, which both backends set when the plan grants `serial`, a `bootcmd` writes `serial-getty@<dev>.service.d/autologin.conf` (`ExecStart=-/sbin/agetty --autologin root ...`) and runs `daemon-reload` before getty first starts, so the console is a root shell even on first boot (`CloudInit.autologinBootCommand`); for `hvc0` also a first-boot `bootcmd` that writes a GRUB drop-in, `CloudInit.hvc0GrubDropIn`, and runs `update-grub`, putting `console=hvc0` on the kernel command line from the next boot), `rosetta` (mounts the `rosetta` virtiofs tag at `/mnt/rosetta`, writes `RosettaGuest.binfmtLine` to `/etc/binfmt.d/rosetta.conf` with a `systemd-binfmt` drop-in ordering it after the mount, and restarts `systemd-binfmt`), `dhcpIdentifierMAC` (a `network-config` NIC with `dhcp-identifier: mac`, so vmnet's lease file is keyed by the MAC), extra user-data merged last as a MIME part) it emits `user-data`, `meta-data` and `network-config` with a small hand-written YAML emitter (every string double-quoted; no YAML library, C5) and runs `hdiutil makehybrid` to make the `cidata` ISO. `FeatureDocs` renders `docs/FEATURES.md` from the matrix, with a last column from the committed slow-probe snapshot `docs/dev-host-facts.json` (never `VMLAB_HOME`). It depends on swift-log only.

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
`-S`. A segment member (R-901) gets a second NIC, `QEMULaunchOptions.segment` (`QEMUSegmentNIC`): `-netdev dgram` from its bound `segments/<name>/ports/<vm>.sock` to the switch's `switch.sock` (Homebrew QEMU 11.1.2 verified; a stale port socket is removed before launch). `BootSpec` picks the firmware arguments (R-305): `disk` edk2 pflash, `firmware` a custom pflash
image or `-bios` ROM, `kernel` `-kernel/-initrd/-append/-dtb` with no firmware, `binary`
`-device loader,...,cpu-num=0` with no firmware; `QEMUBackend` takes `VMRecord.boot`, fills a
missing kernel from the image (extracting it on first use) and attaches no disk to a kernel-only
image. `VMRecord.extra.qemuArgs` (R-306, `ExtraSpec` in `Core/ExtraSpec.swift`: `allowedQEMUOptions` maps each option QEMU may take to an `OptionRule` (flag, `key=value` options, a free word or a bare host path; its implied key, allowed, denied and host-code types), `refusedQEMUOptions` gives the reason for the ones vmlab owns or that are dangerous; `hostCodeUses` lists `-plugin`, `-semihosting`, passthrough devices and host-device chardevs, netdevs and objects, which `checkHostPaths(policy:vmlabHome:allowHostCode:)` refuses unless `VMLabConfig.allowHostCode`; host paths are checked against the `PathPolicy` and `VMLAB_HOME` at create and again at start, each as a read or a write (`HostPath.access`: anything not known to be only read is a write, and a disk is read only with `readonly=on`, `read-only=on`, `snapshot=on` or `media=cdrom`), where `QEMUBackend.checkImageChains` also holds every backing file (read) or data file (as its image) of a `file=` image, per `qemu-img info --backing-chain`, to the same rule) are used when the plan grants `custom_devices`: the request's `-cpu` replaces vmlab's (`checkCPU`: `host`/`max` only under HVF, `host` only there), its `-machine`/`-M` properties join vmlab's `-machine` (`machineArgument`: another board only under TCG), `-icount` is refused under HVF, and the rest (`appendedArguments`) go last. Networking (R-308): one
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
forked daemon otherwise aborts on its first `snapshot-save` under HVF; within `daemonizeDeadline`,
60 s, and cancellably, both of which kill the parent and the pid-file daemon), connects QMP and the `SerialChannel` while the CPU is
halted, then sends `cont` unless `haltAtStart`; `attach` reconnects from the pid file, `powerdown`
sends `system_powerdown` and waits for the process to exit, `kill` sends `quit` then `SIGKILL`.
`QEMUBackend` is the `Backend` for `qemu-hvf` and `qemu-tcg`: it keeps a `QEMUMachine` per running
guest (reattaching after a server restart, one attach in flight per VM), resets with QMP `system_reset` (after `stop` when
`boot.haltAtStart`, so the CPU waits at its first instruction again, R-703), builds the seed when R-400's `id_ed25519.pub` exists (with the desktop, no VNC server, when the stored plan provisions one, R-504),
and hands out `QEMURunningVM` (serial, VNC display, GDB, QMP `query-*` introspection,
checkpoints, memory dumps, exec over SSH through the forwarded loopback port (`SSHExecChannel`,
or `NoSSH`, never connected, without a network), and exec through qemu-guest-agent).
Shared directory (R-404): `SharedDirSpec.of(record)` becomes `-virtfs local,path=...,mount_tag=share0,
security_model=mapped-xattr` (refused unless the plan grants `shared_dir`) and a cloud-init
`mounts` entry (`9p`, `trans=virtio,version=9p2000.L,rw,nofail`); create and start check the host
directory exists. Debian's cloud kernel has no 9p (`CONFIG_NET_9P` unset), so the mount needs a
kernel with it, such as Ubuntu's cloud images.
Guest agent (R-403): when the plan grants `exec_agent` (and the arch has PCI defaults) the command
line adds a `virtio-serial-pci` with a `virtserialport` named `org.qemu.guest_agent.0` on a
`-chardev socket` at `<vm>/qga.sock` (QGA is not reachable through QMP). `GuestAgent` (an actor,
`QEMUMachine.agent`) opens a connection per command, sends 0xFF plus `guest-sync-delimited` to
discard anything a previous client left, then the command; commands from one process are
serialised, and an unanswered sync is `guest_unreachable` with `connected: false`.
`GuestAgentExecChannel` runs `RemoteShell.foreground` (as root, `sudo -n -u` for another user)
with `guest-exec` of `/bin/sh -c`, base64 stdin and a fixed PATH/HOME, polls `guest-exec-status`
(50 ms growing to 500 ms), writes the base64 output through `ExecFiles`/`ExecOutput.collect`
(same 64 KB cut and log as SSH), and at the deadline kills the job's process group with a second
`guest-exec` of `RemoteShell.kill`, returning `timeout` with what the agent reports. Debian's cloud
image does not ship qemu-guest-agent: cloud-init installs it on a first boot with a network, so a
guest created with `net_none` has an agent only when its image does. `QMPIntrospection`
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
`QEMUClone.swift` (R-803): a clone's `disk.qcow2` is `qemu-img create -b` over a frozen layer in the source's `backing/` directory that nothing writes again: an APFS clone of the stopped source's disk (`disk-<clone>.qcow2`), the same with the checkpoint applied (`<checkpoint>.qcow2`, shared by every clone of that checkpoint), or, while the source runs, `qemu-img convert -U -l snapshot.name=` of the immutable snapshot into a delta over the source's backing file; `efi-vars.bin` is copied, and the chain is read back with `qemu-img info --backing-chain`. The frozen layer is written into the clone's `backingChain` before it or the overlay is made (`recordIntent`), so `vmlab gc` never collects it after a crash. `VZClone.swift` clones `disk.raw` (or a checkpoint's `checkpoints/<id>/disk.raw`, which R-608 will make) with `clonefile(2)` and reruns `create` for the seed; its chain is empty.
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
console to `console.log` and `serial.sock`, the balloon, `Graphics` only when `gui` was granted,
the record's share (`SharedDirSpec.of`, R-404) as the virtiofs `DirectoryShare` `share0`, and Rosetta
(`rosettaTag`) only when the plan's `requested` holds `rosetta` (`wantsRosetta`)).
`VZRunnerConfig.nestedVirtualization` (R-609, only when the plan requested `nested_virt`) sets
`isNestedVirtualizationEnabled`; `vmlab-vz capabilities` prints the framework's
`isNestedVirtualizationSupported`, which `HostProbe` reads for the `nested_supported` fact (the
M3-and-macOS-15 inference is the fallback when the runner is absent).
`VZCheckpoints` (R-608) is the vz-linux `CheckpointProvider`, handed out by
`VZBackend.checkpoints(_:)` in any state and by `VZRunningVM.checkpoints`: each checkpoint is
`<vm>/checkpoints/<id>/` with `clonefile(2)` clones of `disk.raw`, `efi-vars.bin` and
`machine-id.bin`, plus the VM's first-boot record (`provisioned`, `provision.json`, `provision.log`)
and `provisioning.json` naming which of those it holds, so a restore brings back or removes them with
the disk they describe (CX-26: a pre-provisioning disk has no vmlab key, so the next start must
provision again; a checkpoint without the manifest leaves them alone). Files are replaced all or none
(`VZCheckpoints.replace`: copies to temporaries, then `RENAME_SWAP`s); a restore first writes
`<vm>/.vmlab-swap-journal.json` (`SwapJournal`: each swap with the destination's old and the copy's
inode) and removes it when every swap is made, and `VZCheckpoints.recover` swaps back whatever a dead
process left made, at the next checkpoint create or restore and at every VZ start (`startSuspended`); `disk` mode needs the guest not running; `live` pauses, has the runner
`saveMachineStateTo` `state.vzvmsave`, clones the files and the `vz-config.json` the machine was
built from, and resumes; a live restore ends the runner, clones the files back, starts a held
(`--hold`) runner from that configuration, restores and resumes (unless the VM was paused), then
writes the new runtime to `vm.json` and reconnects serial. A `suspended` VM's start
(`checkpoint_stop`) is that held runner (`startSuspended`, marked by `<vm>/vz-held-for`), so the
manager's restore only loads the state. `VZRunnerConfig.machineIdentifier` (`<vm>/machine-id.bin`)
keeps one `VZGenericMachineIdentifier` per VM, without which a saved state will not restore.
`VZLiveSnapshotProbe` (`vz_linux_live_snapshot`, registered by `Engines.registerProbes`) saves and
restores a throwaway machine on a clone of a pulled Linux raw disk (`unknown` when none is pulled);
`VZMacLiveSnapshotProbe` (`vz_macos_live_snapshot`) does the same on a throwaway `tart clone` of `macos-base` without network (`unknown` without tart, the image, or a free macOS slot). `VZMacBackend` hands out the same `VZCheckpoints`, which for a vz-macos guest clones the Tart clone's `disk.img` and `nvram.bin`, and starts a suspended macOS VM held the same way.
`SerialBridge` (R-602) is the runner's end of `<vm>/serial.sock`: the virtio console byte for byte,
one client at a time like QEMU's socket chardev (a second waits in the backlog), client bytes to the
guest's input pipe, and output made while nobody is connected kept (last 1 MB) for the next client,
so a channel that connects after start still sees boot; a client that blocks writes for 2 s is
dropped. `stop()` drops the client, ends the accept loop (polled beside a wake pipe) and closes the
listener; once it returns the bridge no longer writes to the guest's input descriptor. A segment member gets a `.segment(macAddress:attachSocket:)` NIC (R-901), which the runner builds as a `VZFileHandleNetworkDeviceAttachment` on a datagram `socketpair` whose other end it sends to the switch's `attach.sock`, closing its copy only after the switch's `ok`.
`MachineDecisions.swift` resolves a config against `VZMachineLimits` into `VZMachineDecisions`, the
plain device list the runner materialises one to one (snapshotted in `Tests/Fixtures/vz/`), and
holds `MACAddress.normalize`. Core's `DHCPLeases` parses `/var/db/dhcpd_leases` (macOS drops leading zeros
per octet, `normalizeMAC`) and finds the newest unexpired lease by MAC; `QEMUBackend.sshEndpoint` reads it too for a `net_fast` (vmnet) guest. A kernel-only image with `boot.mode: kernel` gets no disk and no seed (`VZRunnerConfig.linux(rootDisk:)`). Create reuses (or makes) Core's
`SSHKeys` pair for the seed. `VZRunnerLauncher` checks the runner's entitlement
(`host_missing_tool` with `signingHint`), writes the config and starts `vmlab-vz run <vm>` with
`Process` (own process group, stdin `/dev/null`, output appended to `vz.log`), then waits for
`status` to say `running` (or `stopped` with `hold`); a runner that dies first reports its error as
a `vmlab-vz-error: <json>` line in `vz.log`. `VMLabVZ.attach(socketPath:)` / `attach(runtime:)`
reconnect by socket path alone. `VZBackend` (profile `vz-linux`) conforms to Core's `Backend`:
create clones the pulled raw image to `<vm>/disk.raw`, extends it (sparse `ftruncate`, `VZDisk.grow`) to `resources.diskGB` GiB (Linux default 32; a size below the image's is `invalid_request` on `resources.diskGB`, disks only grow; the seed's `growpart`/`resize_rootfs` grow `/` on first boot) and writes the VM's key and `seed.iso`
(image login user, console `hvc0`, DHCP by MAC, and when the plan provisions a desktop the R-504 `GUIStack` with its x11vnc password in `<vm>/vnc.pass`, the share mounted over virtiofs, Rosetta when wanted; `SharedDirSpec.checkHostDirectory` at create and start), start resolves a kernel boot through `ImageStore.resolvingBoot` (R-604: `VZLinuxBootLoader`, default command line `console=hvc0 root=/dev/vda1 rw`) and stages a disk boot's kernel from the guest's own disk (`stageDiskKernel` over Core's `DiskBoot.stage`: boot `.linuxFromDisk` from `<vm>/boot-cache/`, an event naming what it boots and whether the cache was refreshed; on failure EFI with a start warning, returned through `Backend.start(_:warnings:)`), launches and waits up to `leaseTimeout` for
the lease, recorded as `runtime.ip` (and `runtime.serialSocket`); a lease that comes later is picked up by `sshEndpoint` (both VZ backends, `VZBackend.lateLease`, keyed by the NAT MAC in `vz-config.json`), which records it under the VM's lock, and `VMManager.refreshingAddress` asks for it without waiting before `attach`, `vm_inspect`, `vm_list` and `vm_computer`; stop/kill wait for the runner to exit. A guest granted `serial` gets one Core `SerialChannel` on `serial.sock` per backend (`VZSerialChannels`, connected at start, reconnected on attach when lost, dropped on stop/kill/destroy), reading the runner's `<vm>/console.log` with a `ConsolePanicWatch`; `VZRunningVM` offers that serial channel, exec over SSH to the leased address (`SSHExecChannel`), and no display or checkpoint channel yet (R-503, R-605; its display endpoint is Core's `DisplayEndpoint.forVM`, which `vm_computer` and `vm_inspect` use directly).
`VZMacBackend` (profile `vz-macos`, R-605) runs macOS guests in the same runner: `Tart.swift` wraps
the `tart` CLI (`Tart.locate`, `clone`, `setDiskSize`, `delete`, under `TART_HOME` or `~/.tart`) and reads a clone's
`config.json` (`TartVMConfig`, Tart 2.x `version: 1`; any other layout is `engine_error`). Create runs
`tart clone <ref> <vm-id>` from the ref the image record names (`PulledImage.tartVM`) and records the
clone's directory as `VMRecord.tartClone`, with `resources.cpus`/`memoryGB` raised to the clone's `cpuCountMin`/`memorySizeMin` where the request was below them so admission counts what the runner gives (CX-29) (a `resources.diskGB` larger than the clone's `disk.img` runs `tart set <vm-id> --disk-size`, decimal GB; smaller is `invalid_request`; the guest's APFS container is not grown); start builds `VZRunnerConfig.macOS` (boot `.macOS` with the
base64 hardware model and machine identifier and `nvram.bin` as auxiliary storage, `disk.img`, the
clone's MAC, no console, always a Mac display, and the record's share as a virtiofs device with the
automount tag `com.apple.virtio-fs.automount` (`VZRunnerConfig.macOSAutomountTag`), which macOS
mounts at `/Volumes/My Shared Files` by itself (`SharedDirSpec.macOSAutomountPath`, what
`vm_inspect` reports, CX-27); a `share.guest` elsewhere uses the tag `vmlab-share0`
(`MacProvisioner.shareTag`) and first boot installs the `io.vmlab.share` LaunchDaemon that runs
`mount_virtiofs` there at every boot, with sudo, so create refuses it before cloning unless the
image records the login password or the request gave `provision.sudoPassword`, which
`VMManager.create` moves out of the record into `<vm>/sudo.pass` (0600, Core `SudoPassword`)) and waits for that MAC's lease; stop, kill, pause and
resume are `VZBackend`'s; destroy also `tart delete`s the clone. The runner turns boot `.macOS` into
a `VZMacPlatformConfiguration`, `VZMacOSBootLoader` and `VZMacGraphicsDeviceConfiguration`.
`PasswordSSH` runs `ssh` with the image password through an askpass script
(`SSH_ASKPASS_REQUIRE=force`, the password only in its environment) for a guest whose key is not
installed yet; `HostCommand` is its subprocess with stdin and a deadline.
`MacProvisioner` (R-606) is a macOS guest's first boot, run by `VZMacBackend.start` once the lease
is known and `<vm>/provisioned` is absent: over `PasswordSSH` with the image login it waits for
sshd, appends `<vm>/id_ed25519.pub` (made at create by `VMManager`, R-400) to `~/.ssh/authorized_keys`,
sets the hostname with `scutil` (through `sudo -S`, the password on stdin), for a share off the
automount path checks `/sbin/mount_virtiofs` (`share_check`), installs and bootstraps the
LaunchDaemon (`share_plist`, `share_daemon`; the guest path is an argument of its `/bin/sh -c`, never
shell text) and waits for the mount (`share_mount`), and when a GUI feature was
granted sets the legacy VNC password from `<vm>/vnc.pass` (eight letters and digits, made at
create) with ARD's `kickstart`, sets `VNCAlwaysStartOnConsole` (without it macOS 26 shows a
password-only VNC viewer a lock screen of its own instead of the logged-in console), enables and
restarts Screen Sharing and checks that port 5900 answers RFB. The display is then the guest's
Screen Sharing (`DisplayEndpoint.forVM`, `hostSide: false`, R-607). Steps
go to `<vm>/provision.log` and, as `ProvisionStep`s (`ssh`, `authorized_keys`, `hostname`,
`screen_sharing`, the VNC password shown as `<vnc.pass>`), to `<vm>/provision.json`, so `vm_inspect`
surfaces a failed first boot as `provision_failed`; a failure is `provision_failed` naming the step,
and the runner is killed. A guest with network `none` (no NIC, so no lease) is not provisioned
and not marked: start returns it running, reachable only by checkpoints and lifecycle (CX-28). `SSHProvisioner` then appends the request's `runCommands` to that report
(`ProvisionReport.hasRequestedSteps` says whether they ran; nothing runs after a failed first boot). Password authentication stays enabled.

**`VMLabRFB`** (library). A VNC (RFB) client: framebuffer updates to PNG, pointer and key events. It
gives both engines a screen to look at and click on. `RFBClient` (an actor) speaks RFB 3.8 over an
`RFBTransport`: `SocketTransport` for a unix or TCP socket, `ReplayTransport` for recorded fixture
streams. It negotiates security None or VNC Authentication (`VNCAuth`, DES via CommonCrypto), sets
32-bit BGRX, requests Raw, CopyRect and DesktopSize, and a background loop of incremental update
requests keeps a `Framebuffer` current; `snapshot()` returns a `CGImage` (reading the pixels in
place) and `Framebuffer.pngData` encodes PNG with ImageIO. The guest is untrusted: a screen is at
most `Framebuffer.maxEdge` (8192) a side and `maxPixels` (2^25) in all, an update's rectangles are
applied to a working copy as they arrive (Raw in 1 MiB chunks) and swapped in at the end, and its
Raw data may cover the screen at most `maxScreenCoveragePerUpdate` (8) times; past any of these the
error is `protocolViolation` (`engine_error`). Input (`RFBInput.swift`, `Keysym.swift`): `pointer(x:y:buttons:)` with a
`PointerButtons` mask, `key(_:down:)`, `press(_:)` for a `KeyChord` parsed from `cmd+shift+4`-style
text (`cmd` is `Super_L`), and `type(_:gap:)`, which strikes each character with Shift where a US
layout needs it, 10 ms apart; with a `hold`, `press` and `type` send each key event on its own,
`hold` apart (macOS Screen Sharing drops strokes whose press and release arrive together).
`serverVersion` is the server's ProtocolVersion (`RFB 003.889` is Screen Sharing). Screenshots (`ScreenshotEncoder.swift`, `ScreenshotCache.swift`):
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
Replies carry no tag, so it keeps them in step: it waits for each command's `+`, takes in what
the stub sent while no command waited (QEMU's unasked stop reply when it stops a running guest
for a new debugger) before sending, records and skips stop replies that arrive while a command
other than `?` waits, and closes the connection (the session reconnects) on a reply of the wrong
shape for its command rather than take every later reply one behind.
`RegisterMap` comes from `qXfer:features:read` (`target.xml` and its `xi:include`s) or a built-in
arm64/x86_64 layout. Errors are the module's own `GDBError`. `GDBDebugTarget.swift` adapts the
client to Core's debugger seam: `GDBDebugConnector` opens a `GDBTCPTransport`, handshakes and loads
the register map (a handshake that times out or is hung up on is `debug_busy`, since QEMU leaves a
second client unanswered in its backlog; nothing listening is `guest_unreachable`), and
`GDBDebugTarget` maps points to `Z0`..`Z4` (breakpoint kind from the architecture), threads to
`Hg`/`vCont`, stops to `DebugStop`, and `GDBError.vmLabError(endpoint:)` maps every error to an
Appendix D code with the `endpoint`.

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
`vm_logs` (events rendered one per line, tails of `console.log` (`serial.log` when there is none) and `provision.log`; `all` is each
source in turn, prefixed), `vm_create` (plan, pull the image if missing, `VMManager.create`, then
start unless `autostart: false`; all or nothing: a cancelled or failed call destroys the VM),
`vm_lifecycle` (start/stop/kill/pause/resume/reset/destroy; clone waits for R-803; a start's
`ssh_unreachable` warning comes from `VMManager.Outcome`; after a reset the VM's debug session
inserts its points again, and a destroy drops the session), `vm_exec` (R-401: validates the
request into an `ExecRequest`, picks the channel by `via` (`Channel.execSSH`, `.execAgent`,
`.exec`) on `VMManager.attach`, runs it under a heartbeat and returns `exitCode`, `stdout`,
`stderr`, `durationMs`, `truncated`, `logPath`; `background: true` starts an `ExecJobs` job over
the VM's `SSHExecChannel` and returns `{ job }`), `vm_job` (read/wait/kill: `output`, `finished`,
`exitCode`, `more`, `logPath`), `vm_file` (R-404: push/pull through `SSHFileTransfer` over the VM's
SSH channel, absolute host paths only, returning `bytes` and `path`; `vm_inspect` and `vm_create`
endpoints carry `share` `{ host, guest }`), `vm_manifest` (R-801: `profile` defaults to the guest's OS,
`custom` needs `paths`; a running VM only; returns `{ id, path, profile, counts }` with the
manifest's warnings), `vm_checkpoint diff` (`Handlers/CheckpointDiff.swift`, R-802: each side
is `@now`, taken with the other side's profile and roots, a manifest id, or a checkpoint whose node
has a manifest; sections capped at 500 entries with the counts and `truncated`, the whole diff's
`path`), `vm_serial` (read/tail/write/wait on the backend's
`SerialChannel` via `channel(.serial)`; `since` defaults to 0 for `wait` as for `read`; `wait`
returns the text up to the match, at most 64 KB), `images`
(list/pull/remove), `vm_computer` (`Handlers/VMComputerHandler.swift`, R-502: resolves the VM's
`DisplayEndpoint`, gets its session from `ToolContext.displays` inside `DisplaySessions.exclusive(vm:)` (one call per VM at a time, so gestures and modifiers never interleave), checks every argument before sending input, and maps the computer-use actions
onto pointer, key and type events; clicks move first and hold the button 30 ms, double and triple clicks repeat 60 ms apart,
drags hold the left button over eight steps, scroll strikes wheel buttons; coordinates are checked
against the screen and, with `scaled: true`, mapped through the last screenshot as origin +
pixel / scale (a diff's origin is its `changedRegion`; an unchanged diff keeps the last frame); every acting action sleeps `settleMs` and returns a fresh screenshot; on `vz-macos`
a `key` chord with `cmd` adds the warning that it went out as `Super_L`, R-607), `vm_introspect` (an `IntrospectionQuery` to the attached VM's `introspection`
channel; `raw` takes exactly one of `qmp`/`hmp`; returns `{ query, json | text }`) and
`vm_debug` (R-701: `VMManager.attach`, the `.gdb` channel, then the VM's `DebugSession` from
`ToolContext.debug`, `DebugSessions.shared` by default; addresses are `0x` hex or decimal, memory
reads up to 64 KB with an ASCII column up to 256 bytes, `symbolFile` recorded for `info`, which
reports the endpoint and gdb/lldb commands without attaching), `vm_memory_dump` (the `memory_dump` channel writes to `<vm>/dumps/<UTC time>-0x<addr>-<size>.raw`
or `<UTC time>.elf`, or to `local` under the pull write policy, staged as `<vm>/dumps/.staging-*/<final>.part` and renamed in; a range over 256 MB without `confirm: true` is `confirm_required` with
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
non-zero status to stderr), `images pull|list|remove`, `computer <vm> <action>` (`--at x,y`, `--out` writes the image), `debug <vm> <action>`, `introspect`, `memory-dump`, `serve`, `--version`. It bootstraps logging and hands off to Core and `VMLabMCP`.
`destroy`, `exec`, `job` and `file` (`Sources/vmlab/ExecCommands.swift`: stdout to stdout, stderr and a
non-zero status to stderr), `images pull|list|remove`, `computer <vm> <action>` (`--at x,y`, `--out` writes the image), `introspect`, `memory-dump`, `serve`, `--version`, and `install-mcp --client claude-code|claude-desktop` (`Sources/vmlab/InstallMCP.swift`: prints the `mcpServers` entry that runs this `vmlab serve` with `VMLAB_HOME`, and for Claude Code the `claude mcp add` line; `--write` merges it into `~/.claude.json` or Claude Desktop's `claude_desktop_config.json`, keeping every other key; the entry and the merge are `MCPServerEntry`/`MCPClient` in `VMLabMCP/ClientInstall.swift`, which take the home directory as a parameter). It bootstraps logging and hands off to Core and `VMLabMCP`.

**`VMLabEngines`** (library). The engine wiring, and the only module that imports both Core and the
backends for that purpose: `Engines.registerAll(store:into:displays:debug:)` registers `QEMUBackend` for `qemu-hvf`
and `qemu-tcg`, `VZBackend` for `vz-linux` and `VZMacBackend` for `vz-macos` in `Backends.shared` (or a given `BackendRegistry`),
`RFBDisplayConnector` in `Displays.shared` and `GDBDebugConnector` in `DebugSessions.shared`. `RFBDisplay.swift` is Core's `DisplaySession` over
`VMLabRFB`: `RFBDisplaySession` (an actor) connects with the endpoint's password file, waits for the
first frame (and up to 3 s more while it is one colour: Screen Sharing opens with a black frame),
sends keys with a 20 ms hold, waits 3 s after connecting to Screen Sharing before the first input
(it ignores key events while a viewer settles in), keeps the VM's `ScreenshotCache` across reconnects (a dropped connection is reopened on
the next call, by one shared in-flight reconnect; a connection that fails before its first frame is closed) and maps `RFBError` to Appendix D codes (bad requests and key names
`invalid_request`, unreachable or refused displays `guest_unreachable`, protocol trouble
`engine_error`).
`vmlab` calls it once in `main`, before any command runs, so `serve` and every tool subcommand can
create and start guests; `Engines.registerProbes(into:)` likewise fills `SlowProbeRunners.shared`
with the engines' slow probes (`VMLabQEMU.probeRunners`, and `HVFGDBProbe`, `qemu_hvf_gdb`, R-702:
it starts a diskless, firmware-less arm64 `virt` machine under HVF halted with `-gdb`, writes a
`nop; nop; b` loop at 0x40000000, points `pc` at it, continues, halts, reads the registers, sets a
software breakpoint at `pc + 4` and expects the stop there; `unknown` without QEMU or HVF, and a
`no` makes `gdb` on `qemu-hvf` refuse with `SlowProbe.noReason`, so arm64 guests that need gdb go
to `qemu-tcg`).
`BoundariesTests` checks that it imports only Core, QEMU, VZ, RFB and GDB and that no library imports it.

**`vmlab-vz`** (executable). The VZ runner: one process per Virtualization.framework guest, so a
guest outlives the server. `vmlab-vz run <vm-dir> [--hold]` writes `vz.pid`, builds the machine from
`vz-config.json` (`ConfigurationBuilder` materialises `VZMachineDecisions`: generic platform,
`VZEFIBootLoader` with its variable store or `VZLinuxBootLoader`, virtio-blk raw disks, NAT
virtio-net with the MAC, a virtio console on two pipes (`ConsolePipes`; the runner appends guest
output to `console.log` and hands it to `SerialBridge` on `serial.sock`), entropy, the balloon, and with `gui`
virtio graphics plus USB keyboard and pointer; a missing entitlement at `validate()` is
`host_missing_tool`), owns the `VZVirtualMachine` on the main queue (`Runner`) and
serves `control.sock` (`ControlServer`: an accept thread and one thread per connection, each request
handed to the main queue). It ignores SIGHUP, treats SIGTERM/SIGINT as `exit`, logs `lifecycle`
events to `events.jsonl`, and once the guest has run and stops it removes its sockets and pid file and
exits. It is the only binary that needs `com.apple.security.virtualization`; `scripts/sign.sh`
ad-hoc signs it with `Sources/vmlab-vz/vmlab-vz.entitlements` after every build.

**`VMLabSwitch`** (library). The segment switch with no engine and no Core dependency.
`SwitchCore` is the forwarding logic on integer ports: a learning MAC table with aging, capped at
`maxMACs` (4096; a full table is swept of aged entries, then new sources go unlearned and their
traffic floods, counted as `unlearned`), flooding of
broadcast, multicast and unknown destinations, and counters (`SwitchStats`) for frames over 1600
bytes, malformed frames and congested ports. `SwitchServer` puts it on sockets in
`$VMLAB_HOME/segments/<name>/` (`SegmentPaths`): every sender to the unix datagram `switch.sock`
becomes a port with its own datagram socket connected back to the sender's bound path (how QEMU's
`-netdev dgram` attaches), `attach(fd:)` adds a port on one end of a `socketpair`, and a connection to `attach.sock` hands it one (`SCM_RIGHTS`, `UnixSocket.sendDescriptor`/`receiveDescriptor`; answered `ok`; the VZ runner's path, R-901),
a port whose peer is gone is removed on the next send, and a connection to `stats.sock` receives
the counters as one JSON line. One thread runs a `poll` loop; there is no host connectivity
through the switch.

**`vmlab-switch`** (executable). `vmlab-switch <name>`: one process per segment running
`SwitchServer`, with no root and no `vmnet` (C2). It writes `switch.pid`, refuses to start beside a
live switch for the same segment, and removes its sockets on SIGTERM or SIGINT.

**`UnitTests`** (Swift Testing). Fast tests with no engines; file paths mirror `Sources/`, and
fixtures come from `Tests/Fixtures/` through `#filePath`.

**`IntegrationTests`** (Swift Testing). Tests that boot real guests through QEMU or Tart and need
pulled images; each skips itself unless `VMLAB_INTEGRATION=1`, and they run serially (`VMLAB_INTEGRATION=1 swift test --no-parallel --filter Integration`). Their starts go through `IntegrationAdmission` (`IntegrationGate.swift`: a `StartGate` with the live `HostMemoryGuard`, reached through `VMManager.performAdmitted`/`runAdmitted` and the contexts' `startGate`), so an overcommitted run fails with `limit_memory` instead of swapping. `BareKernel.swift` (R-1200) writes the bare arm64 kernel the kernel-loop tests boot: `BareKernel.image(message:then:)` is a Linux arm64 `Image` header (`text_offset` 0x80000, magic at byte 56, `code0` branching over it) and hand-encoded instructions that print `message` (with a trailing `\n`) to the `virt` machine's PL011 at `0x09000000`, then PSCI `SYSTEM_OFF` through `hvc #0` (`.powerOff`) or `wfi` forever (`.halt`); `write(to:message:then:)` writes it to a file. A `qemu-hvf` guest booting it prints the line and powers off in well under a second, with no toolchain and no image (`QEMUBootIntegrationTests`).

## Scripts

`scripts/check.sh` (format lint, build, unit tests, sign, generated docs current), `build.sh`,
`sign.sh`, `release.sh` (R-1106: `swift build -c release` with the version from `VMLAB_VERSION` or `git describe --tags` baked into `VMLabMCP.version`'s line for that build only, `sign.sh release`, `dist/vmlab-<version>-arm64.tar.gz` plus `.sha256`, then unpacks it to a temp directory and checks `vmlab --version`, that `vmlab doctor` finds the signed `vmlab-vz` next to `vmlab`, and that the bundled `vmlab-match --self-test` prints `ok`), `bootstrap.sh` (Homebrew: qemu, tart), `gen-docs.sh` (`--check` for check.sh;
`--refresh-host-facts` copies this host's slow probes into `docs/dev-host-facts.json`, the only
input of FEATURES.md that is not code), and the process scripts
`board.mjs`, `tidy.mjs`, `review.mjs`, `retro.mjs` and `guard.mjs` (the worktree-rule hook)
described in CLAUDE.md.
