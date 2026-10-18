# Using vmlab from a model

This guide is for the model connected to vmlab's MCP server. It says how to ask for a virtual
machine, how to read the answer, which channel to use for which job, and how to work safely with
checkpoints and fleets. It ends with five worked sessions, each a list of real tool calls with the
shape of each answer. Every call in those sessions is run against the server by
`Tests/IntegrationTests/AgentGuideTests.swift`, so they show what the server actually returns.

The tool reference is [TOOLS.md](TOOLS.md) (generated from the schemas the server serves) and what
each engine can do is [FEATURES.md](FEATURES.md).

## Ask by features, not by engine

You never name an engine. You describe the guest and the features you need, and the selector picks
one of four engine profiles: `vz-macos`, `vz-linux` (Apple's Virtualization.framework), `qemu-hvf`
(QEMU with hardware acceleration) and `qemu-tcg` (QEMU emulating the CPU, slow). A request is a
`requirements` object:

```json
{
  "guest": { "os": "linux", "arch": "arm64" },
  "require": ["serial", "checkpoint_live"],
  "prefer": ["net_fast"],
  "resources": { "cpus": 2, "memoryGB": 2, "diskGB": 16 },
  "network": { "mode": "nat", "segment": "lab", "forwards": [{ "guest": 8080 }] },
  "image": "debian-13-arm64",
  "provision": { "packages": ["jq"], "runCommands": ["systemctl enable --now nginx"] }
}
```

Only `guest` is required. `require` lists features the VM must have; a profile lacking any of them
is ruled out. `prefer` lists features you would like; they rank profiles but never rule one out.
With `require: []` a Linux arm64 guest lands on `vz-linux`, the fastest to boot.

**Ask for every feature you might need, up front.** A VM cannot change engine. If you create a
VM without `gdb` and later need to halt its CPU, `vm_debug` fails with `capability_missing` and
the only fix is a new VM. Think through the whole task before `vm_create`: will you need the serial
console, a debugger, live checkpoints, the screen before the OS is up, a private network? Put each
in `require`. A feature you only might use and that costs nothing to have is still worth
requiring; one that would force a slow engine (anything only `qemu-tcg` has on arm64, such as
`nested_virt` on an M1) belongs in `prefer` until you know you need it.

Call `vm_plan` with the same `requirements` when you are unsure a combination is possible. It
creates nothing.

## Reading a plan

A satisfiable plan looks like this (fields trimmed):

```json
{
  "satisfiable": true,
  "profile": "qemu-hvf",
  "features": ["checkpoint_disk", "checkpoint_live", "exec_agent", "exec_ssh", "gdb", "serial", "..."],
  "requested": ["gdb", "serial"],
  "unverified": [],
  "preferredDenied": [],
  "estimatedStartupSeconds": 20,
  "notes": []
}
```

- `profile` is the engine you will get.
- `features` is everything the VM will have, not just what you asked for: your `require` plus
  every feature the chosen engine always provides. Read it to learn what else you can use.
- `preferredDenied` lists the `prefer` features you will not get.
- `unverified` lists features whose host probe has not run. Planning fails on them with
  `unverified_capability` unless you pass `allowUnverified: true`; the better fix is
  `host_doctor` with `probe: true`, which runs the probes (minutes) and records the answers.
- `notes` carries warnings worth reading: emulation is slow, a desktop install takes minutes, a
  forwarded port on VZ is the guest's own address rather than a loopback port.

`vm_create` returns the same plan under `plan`, plus the VM's id and name, its state and its
endpoints. Refer to a VM by the `name` you gave it or by its `vm-xxxxxx` id in every later call.

## Reading an unsatisfiable answer

An impossible request is not an error from `vm_plan`; it is an answer with `satisfiable: false`:

```json
{
  "satisfiable": false,
  "code": "unsatisfiable",
  "eliminated": { "rosetta": ["qemu-hvf", "qemu-tcg"], "gdb": ["vz-linux"] },
  "reasons": { "gdb": { "vz-linux": "Virtualization.framework exposes no public GDB stub." } },
  "suggestions": [ { "drop": ["gdb"], "profile": "vz-linux" }, { "drop": ["rosetta"], "profile": "qemu-hvf" } ]
}
```

`eliminated` says which profiles each required feature ruled out, and `reasons` says why.
`suggestions` are the smallest sets of features to drop, each with the profile that would then
run. Pick the suggestion whose dropped features you can live without, or split the task across two
VMs (one for the debugger, one for Rosetta). `vm_create` with the same request fails with the error
`unsatisfiable`, carrying the same `eliminated` and `suggestions` in `data`.

A few requests are contradictions rather than impossibilities and fail with `invalid_request`
before selection: `serial` on a macOS guest, `net_port_forward` with `network.mode: none`.

## Which channel for which job

| Job | Channel | Why |
|---|---|---|
| Anything scripted: install, build, run tests, read logs | `vm_exec` over SSH | Exit codes and clean stdout; 64 KB inline, the rest in `logPath` |
| Long commands (builds, test suites) | `vm_exec` with `background: true`, then `vm_job wait` | No call blocks for minutes; output is collected as it comes |
| Moving files | `vm_file` push and pull | Recursive, binary-safe |
| A guest with no network | `vm_exec` with `via: agent` (`exec_agent`, QEMU only) | Goes through qemu-guest-agent on a virtio-serial port |
| Boot messages, kernel logs, panics, a hung or unbootable guest | `vm_serial` (`serial`) | Captured from the first byte of boot; works when SSH and the display are dead |
| Firmware and bootloaders, CPU state | `vm_debug` (`gdb`, `halt_at_start`) | Halt, step, breakpoints, registers, memory |
| Machine state the guest cannot report | `vm_introspect` (`introspection`) | Asks QEMU directly; works when the guest is hung |
| Something only a person at the screen would see or do | `vm_computer` (`gui`) | Screenshots and input, like a computer-use tool |

Prefer text channels. Use the screen only when the task is about the screen (a GUI app, a desktop
session, a dialog no command can answer). A screenshot costs far more than `vm_exec` and tells you
less: to check whether a window manager runs, `pgrep` it; to read an error, read the log.

When the display is dead, use serial. A desktop that crashed, a guest stuck before its network
came up, a kernel panic: `vm_serial tail` shows what happened, and `vm_serial write` lets you log
in on the console. On VZ Linux guests the screen is an in-guest VNC server, so it dies with the
guest's X session; on QEMU (`gui_preboot`) the screen is the virtual hardware and shows the text
console even when X is gone.

Every `vm_serial` and `vm_computer` result tells you how to continue: `vm_serial` returns an
`offset` to pass as `since` next time, so you read only new text; `vm_computer screenshot` returns
an `id` to pass as `diffFrom`, so the next one returns only the region that changed.

**Host paths.** vmlab reads host files you name (`vm_file push`, `images register`, `boot`, disk
images and ROMs in `extra.qemuArgs`) under your home, `/tmp` or `$TMPDIR`. It writes them
(`vm_file pull`'s `local`, a `share.host` directory, which the guest writes too, and QEMU's logs,
traces, chardev files and writable disks) only under `/tmp`, `$TMPDIR` or `~/vmlab-files` (made
when first used), or folders the owner lists. A dotfile or dot-directory in the home (`~/.zshrc`,
`~/.ssh`), `~/Library` and `VMLAB_HOME` are never written. A refusal is `invalid_request` naming
the path, why, and the folders you may write; pull into one of those, or omit `local` to land in
the VM's `pulled/`.

## Checkpoint discipline

Checkpoint before every risky step: before a package upgrade, a config change you are not sure
of, a kernel or bootloader change, a script you are testing, anything that could leave the guest
unbootable. Restoring a checkpoint takes seconds; rebuilding a guest takes minutes.

- `vm_checkpoint create` with `mode: auto` takes a live checkpoint (memory included) when the VM
  has `checkpoint_live`, and otherwise needs the guest stopped. It never stops the guest for you.
  Require `checkpoint_live` up front if you want to checkpoint a running guest.
- Name checkpoints after what they protect: `before-upgrade`, `good`, `step-2`. Names are unique
  per VM; checkpoints form a tree, so restoring an older one and checkpointing again branches.
- `manifest: true` records what is installed (files, packages, services, users, and on macOS
  defaults and login items). `vm_checkpoint diff` from one checkpoint to another, or to `@now`,
  then tells you exactly what a script changed.
- `vm_checkpoint restore` returns the guest to that state; a live checkpoint resumes it running.
- To bisect, checkpoint after each step that is known good, then restore and replay from the
  midpoint. Session 5 does this.

## Fleets and segments

`fleet create` makes `count` identical VMs named `<name>-1` to `<name>-n` from one `requirements`
(or one template image) and waits for SSH on each. Members on a segment reach each other by name.

- `net_segment create` makes a private Ethernet segment with its own `10.n.0.0/24`; pass it as
  `segment` to `fleet create` (or `auto` to make one), or as `requirements.network.segment` to
  `vm_create`. Segments carry no internet; every guest keeps NAT for that.
- `fleet exec` runs one command on every member (or on `members`) in parallel and returns each
  member's result plus `allSucceeded`.
- Some members can fail while others start; each failed member has an `error`. Read `members`
  before assuming three nodes.
- For many guests, build one VM the way you want it, stop it, turn it into a template with
  `images template_create`, and create the fleet from `image`: provisioning then happens once.
- The host runs at most two macOS guests, across every session on the Mac, and keeps 4 GB of
  memory free. `host_facts` (`runningMacOSGuests`, `freeMemoryGB`) and `vm_list` show where you
  stand before creating more; `limit_macos_guests` and `limit_memory` say how far over you are.
- `limit_memory` also comes when the Mac itself is short of memory: the kernel reports memory
  pressure (`data.pressureLevel` `warn` or `critical`), or `data.availableGB` is below the guest's
  memory plus the reserve. Guests started by other sessions and servers count too
  (`data.hostGuests`). Stop or destroy guests you no longer need, or ask for less memory; retrying
  the same start without freeing memory will be refused again.

## Errors and hints

Every error is `{ code, message, hint, data }`. Read the `hint` first: it names the next call. The
codes you will meet most:

| Code | What it means | What to do |
|---|---|---|
| `invalid_request` | A field is malformed or the request contradicts itself (`data.field`, `data.reason`) | Fix that field |
| `unsatisfiable` | No profile has every required feature | Read `data.suggestions`; drop a feature or split the work |
| `unverified_capability` | A feature depends on a host probe not yet run | `host_doctor` with `probe: true`, or `allowUnverified: true` |
| `capability_missing` | The VM's plan did not grant this channel | Recreate the VM with the feature in `require` |
| `wrong_state` | The action is illegal now; `data.legalActions` lists what is | Do one of those first (often `start`) |
| `guest_unreachable` | SSH or the agent did not answer | `vm_serial tail` or `vm_logs` to see why; the guest may still be booting |
| `timeout` | A call hit its deadline; `data` has partial output | Raise `timeoutSeconds`, or use `background: true` |
| `provision_failed` | A first-boot step failed (`data.step`, `data.log`) | `vm_logs source: provision`; the VM still runs |
| `limit_macos_guests`, `limit_memory` | Host limits | Stop or destroy another guest, or ask for less memory |
| `host_missing_tool` | QEMU, Tart or the signed runner is missing (`data.fix`) | Tell the person the fix command; you cannot install it |
| `confirm_required` | A large pull or dump (`data.bytes`) | Repeat with `confirm: true` if the size is acceptable |
| `debug_busy` | Another client holds the GDB stub | Ask the person to detach their debugger |
| `engine_error` | QEMU or VZ refused (`data.raw`) | Read `raw`; `vm_inspect` and `vm_logs` for context |

Results also carry `warnings`. A warning is not a failure, but read it: it says a provisioning step
failed, a stop fell back to kill, or `cmd` was sent as the Super key.

`vm_inspect` is how you recover your bearings after losing context: the record, the plan, the
endpoints, the last 20 events, any provisioning failure and the latest kernel panic.

## Guest caveats

**Debian and Ubuntu cloud images** (`debian-13-arm64`, `ubuntu-24.04-arm64`, and the amd64 ones):

- `vm_exec` logs in as the image's user (`debian` on Debian, `ubuntu` on Ubuntu, `vmlab` on an
  image you registered) with the VM's own key. `sudo` needs no password, and `vm_exec` with
  `user: root` runs the command as root.
- qemu-guest-agent is not preinstalled. vmlab's cloud-init installs it on first boot, which needs
  network. A guest created with `network.mode: none` has no agent and so no `exec_agent`. Create it
  with NAT first, let cloud-init finish, stop it, make it a template (`images template_create`), and
  create the network-less VM from that template.
- The Debian cloud kernel has no 9p, so `share` (`shared_dir`) does not mount under QEMU. Use a VZ
  profile (virtiofs) or copy with `vm_file`.
- On QEMU the display is `ramfb` at 800x600. Coordinates in `vm_computer` are in that space.
- First boot runs cloud-init after SSH is up. Packages you asked for (and a desktop, for
  `gui_desktop`) may still be installing when `vm_create` returns: run
  `cloud-init status --wait` with a generous `timeoutSeconds` before relying on them.
- A desktop (`gui_desktop`) is Xfce under LightDM with autologin; installing it takes several
  minutes on first boot.

**macOS guests** (`vz-macos`, cloned from `macos-base`):

- The user is `admin` with the password `admin`; SSH is on. There is no serial console, no
  debugger and no introspection under VZ. At most two run at once on the host.
- The screen is the guest's own Screen Sharing. It ignores keys for about three seconds after a
  viewer connects, and drops a key whose press and release arrive together; vmlab waits and spaces
  the events for you, so keep `settleMs` at 1000 or more after keys and expect the first action
  of a session to be slow.
- `cmd` in a `key` chord is sent as `Super_L`, which Screen Sharing maps to Command (`cmd+space`
  opens Spotlight). The result carries a warning saying so.
- The first Spotlight on a fresh image shows an introduction that takes the keyboard until its
  Continue button is clicked; click it, press Escape, and open Spotlight again.
- The image restores windows from its last session at login, so take a screenshot before you act
  instead of assuming an empty desktop.
- Prefer `vm_exec` for anything `defaults`, `launchctl`, `osascript` or a shell script can do.

## Custom QEMU arguments (custom_devices)

`extra.qemuArgs` hands QEMU arguments of your own; naming any implies `custom_devices`, so the
plan is QEMU. Give each value as the argument after its option (`["-device", "virtio-rng-pci"]`,
not `-device=...`), in QEMU's `key=value,...` form (`,,` is a literal comma; no JSON).

- **Allowed:** `-device`, `-global`, `-drive`, `-blockdev`, `-object`, `-chardev`, `-netdev`,
  `-nic` and `-net` (user, socket, stream, dgram, hubport), `-cdrom`, `-hda`..`-hdd`, `-sd`,
  `-option-rom`, `-acpitable`, `-smbios`, `-fw_cfg`, `-rtc`, `-boot`, `-action`, `-icount`, `-d`,
  `-dfilter`, `-D`, `-trace`, `-numa`, `-overcommit`, `-mem-prealloc`, `-mem-path`, `-audiodev` and
  `-audio` (none or wav), `-tpmdev emulator`, `-vga`, `-usbdevice`, `-virtfs` and `-fsdev` (local),
  `-iscsi`, `-msg`, `-compat`, `-uuid`, `-k`, `-seed`, `-watchdog-action`, `-usb`, `-no-reboot`,
  `-no-shutdown` and a few more flags.
- **`-cpu`** replaces vmlab's CPU model: `max,sve=on` or a named model such as `cortex-a72,pmu=on`
  under `qemu-tcg`; only `host` or `max` (with properties) under `qemu-hvf`, and `host` only there.
- **`-machine` / `-M`** properties join vmlab's own `-machine` (`["-machine", "highmem=off"]`).
  Under `qemu-tcg` you may also name another board (`sbsa-ref`); under `qemu-hvf` the board stays
  `virt`. `accel=` and the boot keys (`kernel=`, `dtb=`, ...) are refused: use `boot`.
  `-icount` needs `qemu-tcg`.
- **Another serial port:** vmlab keeps `-serial` (it is `vm_serial`'s console). Add
  `["-chardev", "socket,id=s1,path=/tmp/s1.sock,server=on,wait=off", "-device",
  "pci-serial,chardev=s1"]` (`isa-serial` on x86_64), or a `virtconsole` on a virtio-serial bus.
- **Host paths** (`file=`, `path=`, `-D`, `-cdrom`, `-trace file=`, ...) must be absolute, outside
  `VMLAB_HOME`, and not an existing unix socket. A path QEMU only reads (`-cdrom`, `romfile=`,
  `-device loader,file=`, a disk with `readonly=on` or `snapshot=on`, a backing file) may be under
  your home or `/tmp`; a path it writes (`-D`, `-trace file=`, chardev `path=` and `logfile=`,
  sockets it creates, a writable disk, `-virtfs`/`-fsdev` directories) only under `/tmp`,
  `$TMPDIR` or `~/vmlab-files`, never a home dotfile or `~/Library`.
- **Refused:** monitors (`-monitor`, `-qmp`, `-mon`, `mon:`), `-incoming`, `-add-fd`,
  `-sandbox`, `-readconfig`, `-set`, `exec:` and `cmd:`, `fd=`/`script=`/`helper=`/`smb=` keys,
  `tap`, `bridge` and `vmnet-*` netdevs, and what vmlab owns: `-smp` and `-m` (use `resources`),
  `-kernel`, `-bios`, `-pflash` and friends (use `boot`), `-vnc`/`-display`, `-gdb` (use
  `vm_debug`), `-snapshot`/`-loadvm` (use `vm_checkpoint`), `-accel`, `-name`, `-daemonize`.
  The error names the argument (`field: extra.qemuArgs[i]`) and says why.
- **The owner's opt-in:** `-plugin`, `-semihosting`, `-semihosting-config`, passthrough devices
  (`usb-host`, `vfio-*`, `vhost-*`, `u2f-passthru`), host serial or parallel chardevs, `vhost-user`
  netdevs and `-audiodev coreaudio` run host code or reach host hardware. They are refused unless
  the owner sets `"allowHostCode": true` in `VMLAB_HOME/config.json`; no tool argument can, so
  ask the owner rather than retrying. Their host paths still follow the path rule.

## Reading the result blocks

In the sessions below, each ` ```json call ` block is one `tools/call` (`tool` is the tool's name,
`arguments` its arguments), and the ` ```json result ` block after it is the shape of the answer.
A result block lists only the fields that matter; the real answer has more. Placeholders stand for
values that change from run to run: `<string>`, `<number>`, `<bool>`, `<array>`, `<object>`,
`<hex>` (a `0x` address) and `<any>`. `<~text>` matches a string containing that regular
expression. `<hex:pc>` also remembers the value as `pc`, and `{{pc}}` in a later call means that
value. A list in a result block names elements the answer contains, in any order; `[]` means
empty. An ` ```json error ` block is the error the call returns.

## Local images (R-1002)

A disk image you already have becomes an image name that `vm_create` takes in `image`:

```bash
vmlab images register my-debian --disk ~/Downloads/debian.raw --guest linux --arch arm64
vmlab images register my-x86 --disk ./ubuntu-amd64.img --guest linux --arch x86_64 --format qcow2
```

The disk is copied (an APFS clone) into `~/.vmlab/images/<name>/`; `qemu-img` adds the qcow2 that
QEMU overlays and, for arm64, the raw disk that Virtualization.framework boots. The format is read
from the file's header when `--format` is left out. The guest logs in as `vmlab`, which cloud-init
creates with the VM's key, so the image needs cloud-init (every distribution cloud image has it).
An x86_64 image only runs under `qemu-tcg`, and `vm_create` refuses an image whose guest differs
from the request's `guest`.

### A macOS base from an IPSW (attended)

```bash
vmlab images register macos-local --ipsw ~/Downloads/UniversalMac_26.0_Restore.ipsw
```

This runs `tart create --from-ipsw <ipsw> vmlab-image-macos-local`, which installs macOS into a
local Tart VM unattended (tens of minutes, about 60 GB free), and records `macos-local` as a Tart
image that vz-macos clones. The installed system has not been through Setup Assistant yet; that
part is yours, once:

1. `tart run vmlab-image-macos-local` and finish Setup Assistant. Create the account `admin` with
   the password `admin` (vmlab logs in with it on first boot, as with the Cirrus Labs images).
2. In System Settings > General > Sharing, turn on Remote Login (and Screen Sharing if you will
   ask for `gui`).
3. Shut the VM down. `vm_create` with `guest: {os: macos, arch: arm64}, image: "macos-local"` now
   clones it.

Remove it with `vmlab images remove macos-local` and `tart delete vmlab-image-macos-local`.

## Worked sessions

### Session 1: Fix a crashing window manager

The task: a Debian desktop's window manager keeps crashing after an update; find out why and fix
it. You need the screen (`gui`) and a desktop (`gui_desktop`). Ask for `gui_preboot` too: it puts
the VM on QEMU, whose screen is the virtual hardware and keeps working when X dies, where a VZ
guest's screen is a VNC server inside the X session. `serial` is the console to fall back on.

```json call
{
  "tool": "vm_create",
  "arguments": {
    "name": "wm",
    "requirements": {
      "guest": { "os": "linux", "arch": "arm64" },
      "require": ["gui", "gui_desktop", "gui_preboot", "serial", "exec_ssh"],
      "resources": { "cpus": 2, "memoryGB": 4, "diskGB": 12 },
      "image": "debian-13-arm64"
    }
  }
}
```

```json result
{
  "plan": { "profile": "qemu-hvf", "features": ["gui", "gui_desktop", "gui_preboot", "serial", "checkpoint_live"] },
  "vm": { "name": "wm" },
  "state": "running",
  "endpoints": { "ssh": "<string>", "display": "<object>" }
}
```

SSH answers before cloud-init has installed the desktop. Wait for it, then for the window manager
to be up, with a timeout long enough for the install:

```json call
{ "tool": "vm_exec", "arguments": { "vm": "wm", "command": "cloud-init status --wait >/dev/null; until pgrep -x xfwm4 >/dev/null; do sleep 2; done; echo desktop up", "timeoutSeconds": 900 } }
```

```json result
{ "exitCode": 0, "stdout": "desktop up\n" }
```

One screenshot to see the desktop. QEMU's display is `ramfb` at 800x600:

```json call
{ "tool": "vm_computer", "arguments": { "vm": "wm", "action": "screenshot" } }
```

```json result
{ "width": 800, "height": 600, "scale": 1, "id": "<string:healthy>" }
```

Checkpoint before anything risky. The plan granted `checkpoint_live`, so this one keeps the running
desktop, memory and all:

```json call
{ "tool": "vm_checkpoint", "arguments": { "vm": "wm", "action": "create", "name": "desktop-ok" } }
```

```json result
{ "checkpoint": { "name": "desktop-ok", "mode": "live" } }
```

To make the session reproducible, this call breaks the window manager the way a bad update would:
it replaces the `xfwm4` binary with one that crashes, and kills the running one.

```json call
{
  "tool": "vm_exec",
  "arguments": {
    "vm": "wm", "user": "root",
    "command": "printf '#!/bin/sh\\necho \"xfwm4: Segmentation fault (core dumped)\" >&2\\nexit 139\\n' > /usr/bin/xfwm4.new && chmod 755 /usr/bin/xfwm4.new && mv /usr/bin/xfwm4.new /usr/bin/xfwm4 && pkill -x xfwm4 && sleep 5 && echo broken"
  }
}
```

```json result
{ "exitCode": 0, "stdout": "broken\n", "stderr": "" }
```

Now the investigation. Do not start with the screen: a desktop without a window manager still
draws its wallpaper and panel. Ask the guest:

```json call
{ "tool": "vm_exec", "arguments": { "vm": "wm", "command": "pgrep -a xfwm4 || echo 'no window manager'; DISPLAY=:0 xfwm4 --replace; echo \"exit $?\"" } }
```

```json result
{ "exitCode": 0, "stdout": "no window manager\nexit 139\n", "stderr": "<~Segmentation fault>" }
```

Started by hand in the session's display, it crashes at once; the session's own restarts end the
same way (they land in `~/.xsession-errors`). Check the package's files against what dpkg installed:

```json call
{ "tool": "vm_exec", "arguments": { "vm": "wm", "command": "dpkg -V xfwm4" } }
```

```json result
{ "exitCode": "<number>", "stdout": "<~/usr/bin/xfwm4>" }
```

The binary is not the packaged one. Reinstall the package, verify it, and start the window manager
in the running session:

```json call
{
  "tool": "vm_exec",
  "arguments": {
    "vm": "wm", "user": "root", "timeoutSeconds": 300,
    "command": "DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y -q xfwm4 >/dev/null 2>&1 && dpkg -V xfwm4 && echo reinstalled"
  }
}
```

```json result
{ "exitCode": 0, "stdout": "reinstalled\n" }
```

```json call
{ "tool": "vm_exec", "arguments": { "vm": "wm", "command": "DISPLAY=:0 setsid xfwm4 --replace </dev/null >/dev/null 2>&1 & sleep 5; pgrep -x xfwm4 >/dev/null && echo running" } }
```

```json result
{ "exitCode": 0, "stdout": "running\n" }
```

A last screenshot to confirm the desktop as a person would see it. `diffFrom` the healthy one
returns only the region that changed, if any, which is cheaper to look at:

```json call
{ "tool": "vm_computer", "arguments": { "vm": "wm", "action": "screenshot", "diffFrom": "{{healthy}}" } }
```

```json result
{ "width": 800, "height": 600, "id": "<string>", "unchanged": "<bool>" }
```

The checkpoint is no longer needed:

```json call
{ "tool": "vm_checkpoint", "arguments": { "vm": "wm", "action": "delete", "name": "desktop-ok" } }
```

```json result
{ "deleted": ["desktop-ok"] }
```

```json call
{ "tool": "vm_lifecycle", "arguments": { "vm": "wm", "action": "destroy" } }
```

```json result
{ "state": "destroyed" }
```

### Session 2: Step a bootloader

The task: watch the arm64 firmware take its first instructions, then let it boot. The CPU must
start halted, so `halt_at_start` and `gdb` go in `require` along with `serial` to see the firmware
print. A guest that boots halted runs nothing until you continue it, so `vm_create` does not wait
for SSH and returns as soon as QEMU is up (no `ssh_unreachable` warning).

```json call
{
  "tool": "vm_create",
  "arguments": {
    "name": "boot",
    "requirements": {
      "guest": { "os": "linux", "arch": "arm64" },
      "require": ["gdb", "halt_at_start", "serial"],
      "boot": { "haltAtStart": true },
      "resources": { "cpus": 1, "memoryGB": 1, "diskGB": 8 },
      "image": "debian-13-arm64"
    }
  }
}
```

```json result
{
  "plan": { "profile": "qemu-hvf", "requested": ["gdb", "halt_at_start", "serial"] },
  "vm": { "name": "boot", "id": "<string>" },
  "state": "running",
  "endpoints": { "gdb": "<string>", "serial": "<string>" },
  "warnings": []
}
```

The VM is `running` but its CPU waits at the reset vector. The first `vm_debug` call attaches to
the stub. Read the registers to learn where the CPU starts:

```json call
{ "tool": "vm_debug", "arguments": { "vm": "boot", "action": "registers" } }
```

```json result
{ "stopped": true, "pc": "<hex:reset>", "registers": { "pc": "<hex>", "sp": "<hex>" } }
```

Nothing has run yet, so the serial console is empty:

```json call
{ "tool": "vm_serial", "arguments": { "vm": "boot", "action": "read" } }
```

```json result
{ "text": "", "offset": 0 }
```

Read the first instructions (aarch64 instructions are four bytes each):

```json call
{ "tool": "vm_debug", "arguments": { "vm": "boot", "action": "read_memory", "address": "{{reset}}", "size": 16 } }
```

```json result
{ "bytes": "<~^[0-9a-f]{32}$>" }
```

Execute one instruction and see where it went:

```json call
{ "tool": "vm_debug", "arguments": { "vm": "boot", "action": "step" } }
```

```json result
{ "stopped": true, "reason": "step", "pc": "<hex:next>" }
```

Let the firmware run, and wait on serial for its boot manager:

```json call
{ "tool": "vm_debug", "arguments": { "vm": "boot", "action": "continue" } }
```

```json result
{ "stopped": false }
```

```json call
{ "tool": "vm_serial", "arguments": { "vm": "boot", "action": "wait", "pattern": "BdsDxe|UEFI|GRUB|Booting", "since": 0, "timeoutSeconds": 60 } }
```

```json result
{ "matched": "<string>", "offset": "<number>" }
```

Now set a breakpoint at the second instruction and reset the machine. The flash the firmware
runs from is read-only, so the breakpoint must be `hardware`. A reset returns the CPU to its first
instruction and keeps the breakpoints.

```json call
{ "tool": "vm_debug", "arguments": { "vm": "boot", "action": "breakpoint_add", "address": "{{next}}", "kind": "hardware" } }
```

```json result
{ "breakpoints": [ { "address": "<hex>", "kind": "hardware" } ] }
```

```json call
{ "tool": "vm_lifecycle", "arguments": { "vm": "boot", "action": "reset" } }
```

```json result
{ "vm": { "name": "boot" }, "state": "running" }
```

```json call
{ "tool": "vm_debug", "arguments": { "vm": "boot", "action": "halt" } }
```

```json result
{ "stopped": true, "reason": "halted", "pc": "{{reset}}" }
```

```json call
{ "tool": "vm_debug", "arguments": { "vm": "boot", "action": "continue" } }
```

```json result
{ "stopped": false }
```

```json call
{ "tool": "vm_debug", "arguments": { "vm": "boot", "action": "wait", "timeoutSeconds": 10 } }
```

```json result
{ "stopped": true, "reason": "breakpoint", "pc": "{{next}}" }
```

QEMU can also say what the machine is, independent of the debugger. `introspection` was not
required but the plan's `features` lists it, because every QEMU profile has it:

```json call
{ "tool": "vm_introspect", "arguments": { "vm": "boot", "query": "status" } }
```

```json result
{ "query": "status", "json": { "running": false, "status": "debug" } }
```

Clear the breakpoint, let it boot, and see the kernel start on serial:

```json call
{ "tool": "vm_debug", "arguments": { "vm": "boot", "action": "breakpoint_remove", "address": "{{next}}", "kind": "hardware" } }
```

```json result
{ "breakpoints": [] }
```

```json call
{ "tool": "vm_debug", "arguments": { "vm": "boot", "action": "continue" } }
```

```json result
{ "stopped": false }
```

```json call
{ "tool": "vm_serial", "arguments": { "vm": "boot", "action": "wait", "pattern": "Linux version|EFI stub|Booting Linux", "since": 0, "timeoutSeconds": 120 } }
```

```json result
{ "matched": "<string>" }
```

```json call
{ "tool": "vm_lifecycle", "arguments": { "vm": "boot", "action": "destroy" } }
```

```json result
{ "vm": { "name": "boot" } }
```

### Session 3: Test a macOS setup script and diff

The task: find out exactly what a setup script changes on a clean Mac, then put the Mac back. The
host runs at most two macOS guests and a macOS guest takes 8 GB, so look before creating one (a
guest another session started elsewhere still counts; `vm_create` then fails with
`limit_macos_guests`):

```json call
{ "tool": "host_facts", "arguments": {} }
```

```json result
{ "runningMacOSGuests": "<number>", "freeMemoryGB": "<number>", "tart": { "present": true } }
```

A macOS guest always lands on `vz-macos`. `checkpoint_live` lets you checkpoint it while it runs
(otherwise a checkpoint needs it stopped). `vm_create` clones the image, boots it and waits for SSH,
which takes a minute or two.

```json call
{
  "tool": "vm_create",
  "arguments": {
    "name": "mac",
    "requirements": {
      "guest": { "os": "macos", "arch": "arm64" },
      "require": ["exec_ssh", "checkpoint_live"]
    }
  }
}
```

```json result
{
  "plan": { "profile": "vz-macos", "requested": ["exec_ssh", "checkpoint_live"] },
  "vm": { "name": "mac" },
  "state": "running",
  "endpoints": { "ip": "<string>" }
}
```

macOS has no serial console under VZ, and asking for one on this VM says so:

```json call
{ "tool": "vm_serial", "arguments": { "vm": "mac", "action": "tail" } }
```

```json error
{ "code": "capability_missing", "hint": "<string>", "data": { "feature": "serial", "profile": "vz-macos" } }
```

Checkpoint the clean state with a manifest, so there is something to diff against:

```json call
{ "tool": "vm_checkpoint", "arguments": { "vm": "mac", "action": "create", "name": "clean", "manifest": true, "note": "before setup.sh" } }
```

```json result
{ "checkpoint": { "name": "clean", "mode": "live", "manifestPath": "<string>" } }
```

Run the script under test. Feeding it on `stdin` to `bash -s` avoids quoting it into `command`:

```json call
{
  "tool": "vm_exec",
  "arguments": {
    "vm": "mac",
    "command": "bash -s",
    "stdin": "set -e\ndefaults write com.example.setup greeting -string hello\necho 'export EDITOR=vim' >> ~/.zshrc\nmkdir -p ~/Library/LaunchAgents\ncat > ~/Library/LaunchAgents/com.example.setup.plist <<'EOF'\n<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>Label</key><string>com.example.setup</string><key>ProgramArguments</key><array><string>/usr/bin/true</string></array></dict></plist>\nEOF\necho setup done\n"
  }
}
```

```json result
{ "exitCode": 0, "stdout": "setup done\n", "truncated": false }
```

Diff the clean checkpoint against the guest as it is now:

```json call
{ "tool": "vm_checkpoint", "arguments": { "vm": "mac", "action": "diff", "from": "clean", "to": "@now" } }
```

```json result
{
  "from": "<string>",
  "to": "<string>",
  "path": "<string>",
  "files": { "added": 1, "entries": [ { "path": "/Users/admin/.zshrc", "change": "added" } ] },
  "defaults": { "entries": [ { "domain": "com.example.setup", "key": "greeting", "change": "added", "new": "hello" } ] },
  "loginItems": { "entries": [ { "name": "/Users/admin/Library/LaunchAgents/com.example.setup.plist", "change": "added" } ] }
}
```

`from` and `to` come back as the manifest ids the names resolved to. The file, the setting and the
launch agent are what the script did. Expect noise beside them: macOS rewrites some of its own
defaults domains and launchd jobs while it runs, so a diff of a live Mac also lists changes in
`com.apple.*` domains and `services` that no script made. Filter by the domains and paths your
script touches; `path` is the full diff on the host if you need all of it. Restore the clean state and check the setting is
gone; a live checkpoint resumes running:

```json call
{ "tool": "vm_checkpoint", "arguments": { "vm": "mac", "action": "restore", "name": "clean" } }
```

```json result
{ "checkpoint": { "name": "clean" }, "state": "running" }
```

```json call
{ "tool": "vm_exec", "arguments": { "vm": "mac", "command": "defaults read com.example.setup greeting; test ! -e ~/Library/LaunchAgents/com.example.setup.plist" } }
```

```json result
{ "exitCode": 0, "stderr": "<~does not exist>" }
```

Destroying the VM also deletes its Tart clone and frees the macOS slot:

```json call
{ "tool": "vm_lifecycle", "arguments": { "vm": "mac", "action": "destroy" } }
```

```json result
{ "vm": { "name": "mac" }, "state": "destroyed" }
```

### Session 4: Three-node cluster

The task: three Debian nodes that reach each other by name. Make the segment first so its name
is yours, then the fleet on it. Nothing here needs QEMU, so the plan lands on `vz-linux`.

```json call
{ "tool": "net_segment", "arguments": { "action": "create", "name": "lab" } }
```

```json result
{ "name": "lab", "subnet": "<~^10\\.[0-9]+\\.0\\.0/24$>", "members": [] }
```

```json call
{
  "tool": "fleet",
  "arguments": {
    "action": "create",
    "name": "node",
    "count": 3,
    "segment": "lab",
    "requirements": {
      "guest": { "os": "linux", "arch": "arm64" },
      "require": ["net_segment", "exec_ssh"],
      "resources": { "cpus": 1, "memoryGB": 1, "diskGB": 8 },
      "image": "debian-13-arm64"
    }
  }
}
```

```json result
{
  "name": "node",
  "segment": "lab",
  "plan": { "profile": "vz-linux" },
  "members": [
    { "vm": "node-1", "state": "running", "ip": "<~^10\\.>" },
    { "vm": "node-2", "state": "running", "ip": "<~^10\\.>" },
    { "vm": "node-3", "state": "running", "ip": "<~^10\\.>" }
  ]
}
```

Check every member's name and login user in one call:

```json call
{ "tool": "fleet", "arguments": { "action": "exec", "name": "node", "command": "echo $(hostname) $(whoami)" } }
```

```json result
{
  "allSucceeded": true,
  "results": {
    "node-1": { "exitCode": 0, "stdout": "node-1 debian\n" },
    "node-2": { "exitCode": 0, "stdout": "node-2 debian\n" },
    "node-3": { "exitCode": 0, "stdout": "node-3 debian\n" }
  }
}
```

Start a service on one node and reach it from another by name over the segment:

```json call
{
  "tool": "fleet",
  "arguments": {
    "action": "exec", "name": "node", "members": ["node-1"],
    "command": "mkdir -p /tmp/www && echo hello-from-node-1 > /tmp/www/index.html && cd /tmp/www && (setsid nohup python3 -m http.server 8000 </dev/null >/dev/null 2>&1 &) && sleep 1"
  }
}
```

```json result
{ "allSucceeded": true }
```

```json call
{
  "tool": "fleet",
  "arguments": {
    "action": "exec", "name": "node", "members": ["node-2", "node-3"],
    "command": "ping -c 1 -W 5 node-1 >/dev/null && python3 -c 'import urllib.request; print(urllib.request.urlopen(\"http://node-1:8000/\").read().decode().strip())'"
  }
}
```

```json result
{
  "allSucceeded": true,
  "results": {
    "node-2": { "stdout": "hello-from-node-1\n" },
    "node-3": { "stdout": "hello-from-node-1\n" }
  }
}
```

The segment lists its members with their addresses:

```json call
{ "tool": "net_segment", "arguments": { "action": "list" } }
```

```json result
{ "segments": [ { "name": "lab", "members": [ { "vm": "<string>", "ip": "<string>" } ] } ] }
```

Tear down the fleet, then the segment you made:

```json call
{ "tool": "fleet", "arguments": { "action": "destroy", "name": "node" } }
```

```json result
{ "destroyed": ["node-1", "node-2", "node-3"] }
```

```json call
{ "tool": "net_segment", "arguments": { "action": "destroy", "name": "lab" } }
```

```json result
{ "name": "lab" }
```

### Session 5: Bisect a kernel panic with checkpoints

The task: a four-step setup panics the kernel somewhere; find the step. You need `serial` (a
panicked kernel answers nothing else), `checkpoint_live` (to rewind a running guest in seconds)
and `introspection` (to ask QEMU about a machine whose guest is dead).

```json call
{
  "tool": "vm_create",
  "arguments": {
    "name": "bisect",
    "requirements": {
      "guest": { "os": "linux", "arch": "arm64" },
      "require": ["serial", "checkpoint_live", "introspection", "exec_ssh"],
      "resources": { "cpus": 2, "memoryGB": 2, "diskGB": 8 },
      "image": "debian-13-arm64"
    }
  }
}
```

```json result
{ "plan": { "profile": "qemu-hvf" }, "vm": { "name": "bisect" }, "state": "running" }
```

Put the four steps in the guest. Step 3 stands for the change that crashes the kernel; here it is
`echo c > /proc/sysrq-trigger`, which panics on purpose, so the session is deterministic.

```json call
{
  "tool": "vm_exec",
  "arguments": {
    "vm": "bisect", "user": "root", "command": "bash -s",
    "stdin": "set -e\nmkdir -p /opt/steps\necho 'echo one > /var/tmp/step1' > /opt/steps/1.sh\necho 'sysctl -q -w vm.swappiness=10' > /opt/steps/2.sh\necho 'echo c > /proc/sysrq-trigger' > /opt/steps/3.sh\necho 'touch /var/tmp/step4' > /opt/steps/4.sh\nsync\nls /opt/steps\n"
  }
}
```

```json result
{ "exitCode": 0, "stdout": "1.sh\n2.sh\n3.sh\n4.sh\n" }
```

The known-good state, before any step:

```json call
{ "tool": "vm_checkpoint", "arguments": { "vm": "bisect", "action": "create", "name": "base", "note": "before the steps" } }
```

```json result
{ "checkpoint": { "name": "base", "mode": "live", "state": "running" } }
```

Reproduce: run all four. A command that may take the kernel down goes in the background, since
its SSH connection will die with the guest; the serial console is where the panic shows. Note
the serial offset first so the wait reads only what comes after:

```json call
{ "tool": "vm_serial", "arguments": { "vm": "bisect", "action": "tail", "lines": 1 } }
```

```json result
{ "offset": "<number:start>" }
```

```json call
{ "tool": "vm_exec", "arguments": { "vm": "bisect", "user": "root", "background": true, "command": "for s in 1 2 3 4; do sh /opt/steps/$s.sh; done" } }
```

```json result
{ "job": "<string>" }
```

```json call
{ "tool": "vm_serial", "arguments": { "vm": "bisect", "action": "wait", "pattern": "Kernel panic - not syncing", "since": "{{start}}", "timeoutSeconds": 60 } }
```

```json result
{ "matched": "Kernel panic - not syncing" }
```

vmlab watches the serial console for panics and records them as events; `vm_inspect` shows the
latest. SSH is gone now (a `vm_exec` would fail with `guest_unreachable`), but the engine still
answers. To QEMU the machine may still be `running`: the vCPUs are spinning in the kernel's panic
loop, which is why the serial console, not the run state, is how you notice a panic. The panic's
`data.offset` is where its line starts in the serial stream: `vm_serial read` with `since` a little
before it shows the trace around it.

```json call
{ "tool": "vm_inspect", "arguments": { "vm": "bisect" } }
```

```json result
{
  "record": { "state": "running" },
  "panic": {
    "kind": "panic", "level": "critical",
    "message": "<~Kernel panic - not syncing: sysrq triggered crash>",
    "data": { "pattern": "Kernel panic - not syncing", "source": "serial", "offset": "<number>" }
  }
}
```

```json call
{ "tool": "vm_introspect", "arguments": { "vm": "bisect", "query": "status" } }
```

```json result
{ "query": "status", "json": { "running": true, "status": "running" } }
```

Bisect. Rewind to `base` and run the first half, steps 1 and 2:

```json call
{ "tool": "vm_checkpoint", "arguments": { "vm": "bisect", "action": "restore", "name": "base" } }
```

```json result
{ "checkpoint": { "name": "base" }, "state": "running" }
```

```json call
{ "tool": "vm_exec", "arguments": { "vm": "bisect", "user": "root", "command": "sh /opt/steps/1.sh && sh /opt/steps/2.sh && echo steps 1-2 ok" } }
```

```json result
{ "exitCode": 0, "stdout": "steps 1-2 ok\n" }
```

The first half is good, so the panic is in step 3 or 4. Checkpoint here, so each later probe
starts after step 2 instead of replaying it:

```json call
{ "tool": "vm_checkpoint", "arguments": { "vm": "bisect", "action": "create", "name": "after-2" } }
```

```json result
{ "checkpoint": { "name": "after-2", "mode": "live" } }
```

```json call
{ "tool": "vm_serial", "arguments": { "vm": "bisect", "action": "tail", "lines": 1 } }
```

```json result
{ "offset": "<number:before3>" }
```

```json call
{ "tool": "vm_exec", "arguments": { "vm": "bisect", "user": "root", "background": true, "command": "sh /opt/steps/3.sh" } }
```

```json result
{ "job": "<string>" }
```

```json call
{ "tool": "vm_serial", "arguments": { "vm": "bisect", "action": "wait", "pattern": "Kernel panic - not syncing", "since": "{{before3}}", "timeoutSeconds": 60 } }
```

```json result
{ "matched": "Kernel panic - not syncing" }
```

Step 3 alone panics. To be sure step 4 is innocent, rewind once more and run it alone:

```json call
{ "tool": "vm_checkpoint", "arguments": { "vm": "bisect", "action": "restore", "name": "after-2" } }
```

```json result
{ "checkpoint": { "name": "after-2" }, "state": "running" }
```

```json call
{ "tool": "vm_exec", "arguments": { "vm": "bisect", "user": "root", "command": "sh /opt/steps/4.sh && cat /var/tmp/step1 && echo step 4 ok" } }
```

```json result
{ "exitCode": 0, "stdout": "one\nstep 4 ok\n" }
```

The checkpoints form a tree: `after-2` is a child of `base`.

```json call
{ "tool": "vm_checkpoint", "arguments": { "vm": "bisect", "action": "list" } }
```

```json result
{ "current": "<any>", "nodes": [ { "name": "base" }, { "name": "after-2", "parent": "<string>" } ] }
```

The event log keeps every panic seen, for the report:

```json call
{ "tool": "vm_logs", "arguments": { "vm": "bisect", "source": "events", "tail": 50 } }
```

```json result
{ "lines": [ "<~Kernel panic - not syncing>", "<~Kernel panic - not syncing>" ] }
```

```json call
{ "tool": "vm_lifecycle", "arguments": { "vm": "bisect", "action": "destroy" } }
```

```json result
{ "state": "destroyed" }
```
