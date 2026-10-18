# Using vmlab from a model

Placeholder. R-1104 writes the agent guide: how to ask for a guest by features, read a refusal, and
use each channel.

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
