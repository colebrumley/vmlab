# vmlab

Virtual machines for a language model, on an Apple Silicon Mac, over MCP.

vmlab is an MCP server (and a CLI with the same tools) that lets a model create, drive, debug and
throw away virtual machines on your Mac. The model does not pick an engine. It describes the guest
and the features it needs (a serial console, a GDB stub, live checkpoints, a screen to click on, a
private network) and vmlab chooses Apple's Virtualization.framework or QEMU, whichever can provide
them, or explains exactly why no engine can. Linux guests boot from cloud images or straight from a
kernel you just built; macOS guests are cloned from a prebuilt image in seconds.

## Who it is for

- **Kernel and low-level work.** Boot a kernel you just built, watch the serial console from the
  first byte, halt the CPU at its first instruction, set breakpoints, read registers and memory,
  dump guest memory, and rewind to a checkpoint when the kernel panics.
- **macOS setup testing.** Run a setup script against a clean macOS guest, then diff what it
  changed: files, packages, services, defaults, launchd jobs, login items.
- **GUI automation.** Take screenshots of a guest's display and send clicks and keystrokes, like a
  computer-use tool, on Linux desktops or macOS.
- **Fleets.** Start several identical guests on a private network where they reach each other by
  name, and run one command on all of them.

## What a model gets

| Channel | Tools | Notes |
|---|---|---|
| Shell | `vm_exec`, `vm_job`, `vm_file` | SSH with a per-VM key; background jobs that survive a server restart; file copy both ways |
| Guest agent | `vm_exec` with `via: agent` | qemu-guest-agent on a virtio-serial port, for a QEMU guest SSH cannot reach |
| Serial console | `vm_serial` | Captured from the first byte of boot and kept on disk, so a powered-off guest can still be read; on Linux guests it is a root shell |
| Debugger | `vm_debug` | The engine's GDB stub: halt, step, breakpoints, watchpoints, registers, memory; can start halted at the first instruction |
| Machine state | `vm_introspect`, `vm_memory_dump` | QEMU's view of the machine (disks, PCI, CPUs, memory map, registers) and guest physical memory as raw bytes or an ELF core |
| Screen | `vm_computer` | Screenshots (with diffs against an earlier frame) and mouse and keyboard input over VNC |
| Checkpoints | `vm_checkpoint`, `vm_lifecycle clone` | A tree of disk or live (memory included) snapshots; restore, delete, clone a new VM from one |
| Manifests | `vm_manifest`, `vm_checkpoint diff` | What is installed in a guest, and what changed between two points |
| Fleets | `fleet`, `net_segment` | Groups of identical VMs on a private Ethernet segment with names in `/etc/hosts` |
| Lifecycle and logs | `vm_create`, `vm_lifecycle`, `vm_list`, `vm_inspect`, `vm_logs` | Start, stop, pause, reset, destroy; an event log per VM |
| Host | `host_facts`, `host_doctor`, `images`, `vm_plan` | What the Mac can run, image cache, and a dry run of engine selection |

vmlab watches every serial console for kernel panics (`Kernel panic - not syncing`, `Oops:`,
`BUG:` and a few more) and QEMU's `GUEST_PANICKED` event, records them as events, and shows the
latest in `vm_inspect`.

Four engine profiles back these: `vz-macos` and `vz-linux` (Virtualization.framework), `qemu-hvf`
(QEMU with hardware acceleration) and `qemu-tcg` (QEMU emulating the CPU: slow, but any
architecture QEMU has, such as x86_64 or riscv64). Which feature each profile offers, and why not
when it does not, is in [docs/FEATURES.md](docs/FEATURES.md).

## Requirements

- A Mac with Apple Silicon. Intel Macs, Linux and Windows hosts are not supported.
- macOS 15 or later.
- Xcode 26 or later (the Swift 6.2 toolchain) to build.
- [Homebrew](https://brew.sh) `qemu`, for every QEMU profile.
- [Tart](https://tart.run), only for macOS guests. On Homebrew 7 and later,
  `brew install cirruslabs/cli/tart` currently fails because the cirruslabs tap's formula has not
  been updated. `scripts/bootstrap.sh` prints a workaround: a local tap holding the same formula
  without its `depends_on :macos` and `depends_on "softnet"` lines. Linux guests work without Tart.

vmlab needs no root. It does not use private Apple APIs.

## Quick start

```bash
git clone <this repository> vmlab && cd vmlab
scripts/bootstrap.sh                          # brew install qemu and tart if missing; print versions
scripts/build.sh                              # swift build, then sign the VZ runner
.build/debug/vmlab doctor                     # what works on this Mac, and how to fix what does not
.build/debug/vmlab images pull debian-13-arm64
.build/debug/vmlab install-mcp --client claude-code --write
claude mcp list                               # vmlab: ... serve - Connected
```

`install-mcp` adds a `vmlab` entry to `~/.claude.json` (user scope) that runs `vmlab serve` from
the executable you ran it from, keeping every other entry. Without `--write` it only prints the
JSON and the equivalent `claude mcp add` line. `--client claude-desktop --write` writes Claude
Desktop's `claude_desktop_config.json` instead (restart Claude Desktop afterwards).

Some features depend on a slow probe of this host (GDB under HVF, live snapshots, vmnet). Until a
probe has run, a request that needs it is refused with `unverified_capability`. Run them once; each
boots a throwaway guest and takes minutes:

```bash
.build/debug/vmlab doctor --probe
```

Then try a prompt in Claude Code:

> Create a Debian arm64 VM with a serial console and live checkpoints. Checkpoint it, install
> nginx, show me what changed on disk, then restore the checkpoint and destroy the VM.

For a build that does not live inside the source tree, see [Installing elsewhere](#installing-elsewhere).

## Example: the kernel loop

A model working on a Linux kernel built on the host. It asks for a serial console, a debugger and
live checkpoints, which lands the guest on `qemu-hvf`, and boots the kernel directly over the Debian
image's root disk. Results are trimmed to the fields that matter; [docs/TOOLS.md](docs/TOOLS.md)
has every field.

Create the VM. No initrd is passed, so the kernel needs virtio-blk and ext4 built in to mount the
Debian root disk; `nokaslr` keeps `System.map` addresses valid:

```json
{ "tool": "vm_create", "arguments": {
    "name": "k",
    "requirements": {
      "guest": { "os": "linux", "arch": "arm64" },
      "require": ["serial", "gdb", "checkpoint_live"],
      "boot": { "mode": "kernel", "kernel": "/Users/you/linux/arch/arm64/boot/Image",
                "cmdline": "console=ttyAMA0 root=/dev/vda1 rw nokaslr" } } } }
```

```json
{ "plan": { "profile": "qemu-hvf" }, "vm": { "id": "vm-3hf5fm", "name": "k" }, "state": "running" }
```

Watch it boot, then save the booted state:

```json
{ "tool": "vm_serial", "arguments": { "vm": "k", "action": "wait", "pattern": "login:", "since": 0, "timeoutSeconds": 120 } }
{ "tool": "vm_checkpoint", "arguments": { "vm": "k", "action": "create", "name": "booted" } }
```

```json
{ "checkpoint": { "name": "booted", "mode": "live", "state": "running" } }
```

Stop on the kernel's `panic` (its address from `System.map`) and crash the kernel from the serial
console, which is a root shell:

```json
{ "tool": "vm_debug", "arguments": { "vm": "k", "action": "breakpoint_add", "address": "0xffff800080a1c2d0" } }
{ "tool": "vm_serial", "arguments": { "vm": "k", "action": "write", "text": "echo c > /proc/sysrq-trigger\n" } }
{ "tool": "vm_debug", "arguments": { "vm": "k", "action": "wait", "timeoutSeconds": 30 } }
```

```json
{ "stopped": true, "reason": "breakpoint", "pc": "0xffff800080a1c2d0" }
```

Read the registers, let the panic finish, and see what vmlab recorded:

```json
{ "tool": "vm_debug", "arguments": { "vm": "k", "action": "registers" } }
{ "tool": "vm_debug", "arguments": { "vm": "k", "action": "continue" } }
{ "tool": "vm_serial", "arguments": { "vm": "k", "action": "wait", "pattern": "Kernel panic - not syncing", "timeoutSeconds": 30 } }
{ "tool": "vm_inspect", "arguments": { "vm": "k" } }
```

```json
{ "panic": { "kind": "panic", "message": "Kernel panic - not syncing: sysrq triggered crash",
             "data": { "source": "serial", "pattern": "Kernel panic - not syncing", "offset": 48211 } } }
```

Rewind to the booted guest in seconds instead of rebooting:

```json
{ "tool": "vm_checkpoint", "arguments": { "vm": "k", "action": "restore", "name": "booted" } }
```

```json
{ "checkpoint": { "name": "booted" }, "state": "running" }
```

After a rebuild, `vm_lifecycle stop` and `start` boot the new kernel file. For a kernel that needs
no root disk at all, `"image": "none"` gives a bare machine with no disk, no cloud-init and no SSH
(and so no checkpoints). [docs/AGENT.md](docs/AGENT.md) has longer worked sessions, each run
against the real server by the integration tests.

## The CLI

Every MCP tool is also a `vmlab` subcommand, running the same handler, with `--json` for the
tool's result object. `vmlab --help` lists them; `vmlab help <subcommand>` explains each.

```bash
vmlab plan --guest linux --require serial,gdb          # which engine, without creating anything
vmlab create --guest linux --require serial --name k   # create and start
vmlab list
vmlab serial k wait 'login:' --timeout 120
vmlab exec k 'uname -a'
vmlab checkpoint k create booted
vmlab computer k screenshot --out /tmp/screen.png
vmlab destroy k
vmlab create --requirements "$(cat requirements.json)" # the whole requirements object as JSON
vmlab gc --dry-run                                     # orphaned engines, old dumps, stale locks
```

`vmlab serve` runs the MCP server on stdin and stdout; `vmlab install-mcp` writes a client's
configuration for it.

## Configuration

| Setting | Default | Meaning |
|---|---|---|
| `VMLAB_HOME` | `~/.vmlab` | Where VMs, images, segments, fleets and locks live. |
| `VMLAB_LOG` | `info` | Log level on stderr (a swift-log level name). |
| `VMLAB_IGNORE_MEMORY_PRESSURE=1` | off | Start guests even when the Mac is under memory pressure. |

`VMLAB_HOME/config.json` holds the owner's settings. A missing or malformed file means the safe
defaults. No tool can change it.

```json
{
  "writeRoots": ["~/vmlab-files", "~/scratch"],
  "allowAnyPath": false,
  "allowHostCode": false,
  "ignoreMemoryPressure": false
}
```

- `writeRoots`: folders a tool may write host files in, besides `/tmp` and `$TMPDIR`. Default
  `~/vmlab-files`, created when first used.
- `allowAnyPath`: lift the read and write roots. Home dotfiles, `~/Library` and `VMLAB_HOME` are
  still never written.
- `allowHostCode`: let `extra.qemuArgs` use options that run host code or pass host hardware
  through (`-plugin`, `-semihosting`, `usb-host`, `vfio-*`).
- `ignoreMemoryPressure`: as `VMLAB_IGNORE_MEMORY_PRESSURE=1`.

Slow-probe answers are host facts and live in `~/.vmlab/host-facts.json` whatever `VMLAB_HOME`
says.

## Security model

vmlab gives a model real machines on your Mac. Know what that means.

- **Host files the model can read.** Tools that take a host path to read (`vm_file push`,
  `images register`, `boot` files, disk images and ROMs in `extra.qemuArgs`) accept any absolute
  path under your home, `/tmp` or `$TMPDIR`, dotfiles included. A model can copy `~/.ssh` into a
  guest. Run vmlab only for a model you would let read your home directory.
- **Host files the model can write.** `vm_file pull`'s `local`, `vm_memory_dump`'s `local`, a
  shared directory (`share.host`, which the guest writes) and files QEMU writes go only under
  `/tmp`, `$TMPDIR` and `~/vmlab-files` (or your `writeRoots`). A dotfile or dot-directory in your
  home, `~/Library` and `VMLAB_HOME` are refused even with `allowAnyPath`. Paths are resolved
  through symlinks before the check, and a pulled file is renamed into place without following a
  symlink planted after it.
- **QEMU arguments.** `extra.qemuArgs` is checked against an allowlist of options and keys.
  Monitors, `-serial`, `-incoming`, `-readconfig`, `exec:` and similar are refused; options that run
  host code or reach host hardware need `allowHostCode`.
- **No host shell.** Every host process vmlab starts is an argument array, never `sh -c` with
  model input; a unit test checks the sources for it. Shell text runs only inside guests, with
  model values quoted.
- **Guests are disposable and fully open to the model.** On a Linux guest with `serial`, the
  console logs in as root with no password. Each VM has its own SSH key; the cloud images allow
  passwordless `sudo`. Do not put anything in a guest you would not hand to the model.
- **Guest output is untrusted.** Framebuffer sizes, VNC updates, ext4 images read on the host and
  serial patterns are bounded; a regular expression on serial output runs in a helper process
  that is killed when the wait ends.
- **Networks.** Guests get NAT to the internet by default (`network.mode: none` for no NIC).
  Segments are host-local and carry no host connectivity. QEMU port forwards bind `127.0.0.1`
  only; a VZ guest's NAT address is reachable from the Mac itself.
- **Resources.** Starts are admitted against a 4 GB host memory reserve, the Mac's memory pressure,
  four concurrent starts and Apple's limit of two macOS guests, across every vmlab server on the
  Mac.

## Limitations

- **Hosts:** Apple Silicon Macs only.
- **macOS guests:** at most two at once (Apple's limit). They need Tart (see the Homebrew 7 caveat
  above), have no serial console, debugger, introspection or memory dump, and their screen is the
  guest's own Screen Sharing, so there is no screen before the OS is up.
- **Debugging and introspection** exist only on QEMU. Virtualization.framework exposes no public
  GDB stub or machine-state API.
- **Nested virtualization** needs an M3 or newer under `vz-linux`; otherwise only `qemu-tcg`
  offers it, slowly.
- **Early boot on `vz-linux`:** the serial console is the virtio console, so output before its
  driver loads (an early panic) is not captured. `qemu-hvf` has a PL011 with `earlycon`; require
  `gdb` or `introspection` to land there.
- **Shared directories** use 9p under QEMU, and Debian's cloud kernel has no 9p: use an Ubuntu
  image, a VZ profile (virtiofs), or `vm_file`.
- **Display:** QEMU guests have no GPU; their screen is `ramfb`. VZ Linux guests show a desktop
  through an in-guest VNC server that vmlab installs on first boot, which takes minutes.
- **Fast networking** (`net_fast`, vmnet) on QEMU needs root or a host where the vmnet probe
  passes; the VZ profiles always have it. Other QEMU guests use user-mode NAT.
- **Performance:** `qemu-tcg` (any non-arm64 guest, and `cpu_emulation`) emulates the CPU and is
  many times slower than the other profiles.

[docs/FEATURES.md](docs/FEATURES.md) is the full matrix, with the reason for every "no".

## Installing elsewhere

QEMU (and Tart, for macOS guests) still come from Homebrew; vmlab itself needs only the Xcode
toolchain:

```bash
swift build -c release
scripts/sign.sh release                     # the VZ runner's virtualization entitlement
mkdir -p ~/.local/bin
cp .build/release/vmlab .build/release/vmlab-vz .build/release/vmlab-switch .build/release/vmlab-match \
  ~/.local/bin/
~/.local/bin/vmlab doctor
~/.local/bin/vmlab install-mcp --client claude-code --write
```

Keep the four binaries in one directory: `vmlab` finds `vmlab-vz` (the Virtualization.framework
runner), `vmlab-switch` (the segment switch) and `vmlab-match` (which runs serial wait patterns in
a process it can kill) next to itself.

`scripts/release.sh` builds the same four binaries into `dist/vmlab-<version>-arm64.tar.gz` with a
`.sha256` beside it, the version from `git describe --tags` (or `VMLAB_VERSION=0.0.0-dry` for a dry
run), and checks the unpacked tarball before it finishes. Unpack it anywhere and put the directory
on `PATH`.

## Documentation

- [docs/AGENT.md](docs/AGENT.md): the guide for the model. How to ask for a VM, read a plan, pick
  a channel, use checkpoints and fleets, with worked sessions.
- [docs/TOOLS.md](docs/TOOLS.md): every MCP tool's input schema, result and errors (generated).
- [docs/FEATURES.md](docs/FEATURES.md): the capability matrix by engine profile (generated).
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the processes, the data on disk and one section
  per module.
- [REQUIREMENTS.md](REQUIREMENTS.md): the constraints, the backlog the project was built from, and
  the appendices (features, errors, layout, defaults, images) that the code follows.

## Project layout

```
Sources/
  VMLabCore/      engine-free model: features, matrix, selector, store, lifecycle, channels, policy
  VMLabQEMU/      QEMU backend: command line, QMP, guest agent, snapshots
  VMLabVZ/        Virtualization.framework backend as seen from the server (never imports VZ)
  VMLabRFB/       VNC client: framebuffer, screenshots, input
  VMLabGDB/       GDB remote protocol client
  VMLabSwitch/    the segment switch
  VMLabEngines/   registers the backends, the display connector and the debugger
  VMLabMCP/       tool schemas, handlers, the MCP server
  vmlab/          the CLI and `vmlab serve`
  vmlab-vz/       the VZ runner, one process per VZ guest
  vmlab-switch/   one process per segment
  vmlab-match/    the serial pattern helper
Tests/            UnitTests (no engines) and IntegrationTests (real guests)
scripts/          build, check, sign, release, docs generation, and the development process
docs/             the documents above; specs/ for planned work
```

## Contributing

```bash
scripts/check.sh      # format lint, build, unit tests, sign, generated docs current
swift test --filter SelectorTests
```

`scripts/check.sh` must pass before every commit. `docs/FEATURES.md` and `docs/TOOLS.md` are
generated from the code by `scripts/gen-docs.sh`; edit `Capabilities.swift` or a tool's schema,
then regenerate.

Integration tests boot real guests. They need `scripts/bootstrap.sh`, pulled images
(`vmlab images pull debian-13-arm64`; the macOS image is over 20 GB and only some tests need it)
and free memory, and they must run one at a time:

```bash
VMLAB_INTEGRATION=1 swift test --no-parallel --filter Integration
```

They create guests in temporary homes named `vmlab-test-*` under `/tmp` or `$TMPDIR`, never under
`~/.vmlab`, and destroy them in teardown. A killed run can leave an engine behind: `vmlab gc` or `pkill -f vmlab-test` cleans up.

vmlab is a single-owner project, built mostly by coding agents. The process they follow is in
[CLAUDE.md](CLAUDE.md): each change is one backlog item from [REQUIREMENTS.md](REQUIREMENTS.md) or
one item of a spec under [docs/specs/](docs/specs/), built with its tests in a git worktree of its
own and merged as one commit. The owner decides what goes in.

## License

License: see LICENSE.
