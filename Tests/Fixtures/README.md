# Test fixtures

Read by unit tests through `#filePath`; never written at test time.

- `vm-json/` — `vm.json` per schema version (constraint C4)
- `qmp/` — recorded QMP transcripts (`<` server line, `>` client line; QEMU 11.1)
- `qemu/` — VM records (`<name>.vm.json`) and the QEMU arguments built from them (`<name>.args`,
  one per line; regenerate with `VMLAB_UPDATE_SNAPSHOTS=1 swift test --filter QEMUCommandLine`)
- `rfb/` — recorded RFB captures
- `host-facts/` — `host-facts.json` samples
- `host-probe/` — recorded `sw_vers`, `sysctl`, `vm_stat`, `qemu-system-aarch64`, `tart` output
- `codesign/` — `codesign -d --entitlements -` output
- `features/` — the feature catalogue snapshot (Appendix A)
- `gdb/` — GDB target descriptions (`target.xml` and the annexes it includes) and recorded
  remote-protocol sessions (`->` client packet, `<-` stub reply). The `aarch64-*.xml` and other
  feature files are as served by QEMU's GDB stub, which takes them from GDB's feature
  descriptions (Free Software Foundation; copying and distribution are permitted with or without
  modification)
- `images/` — a two-entry image catalogue, a tiny disk file and the `SHA512SUMS`/`SHA256SUMS`
  that list it
- `tart/` — `config.json` of a Tart 2.32.1 macOS VM (`macos-tahoe-base`)
