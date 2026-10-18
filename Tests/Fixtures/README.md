# Test fixtures

Read by unit tests through `#filePath`; never written at test time.

- `vm-json/` — `vm.json` per schema version (constraint C4)
- `qmp/` — recorded QMP transcripts
- `rfb/` — recorded RFB captures
- `host-facts/` — `host-facts.json` samples
- `codesign/` — `codesign -d --entitlements -` output
- `gdb/` — GDB target descriptions (`target.xml` and the annexes it includes) and recorded
  remote-protocol sessions (`->` client packet, `<-` stub reply)
