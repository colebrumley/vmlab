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
