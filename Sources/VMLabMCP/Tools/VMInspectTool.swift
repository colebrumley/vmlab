import VMLabCore

extension ToolSpec {
  static let vmInspect = ToolSpec(
    name: "vm_inspect",
    summary:
      "Everything about one VM: its record, the plan and resolved features (what channels it "
      + "has), runtime endpoints (SSH, display, serial, GDB), segment addresses, the last 20 "
      + "events, warnings such as provisioning failures, and the latest kernel panic if one was "
      + "seen. Use it to rediscover a VM after losing context or when a channel misbehaves.",
    inputSchema: Schema.input(["vm": Schema.vm], required: ["vm"]),
    outputShape: """
      { vm: { id, name }, record: VMRecord, plan: Plan, features: [feature],
        endpoints: { ssh?, ip?, serial?, gdb?,
          display?: { kind, address, auth, passwordFile?, hostSide },
          forwards?: [ { guest, host: "127.0.0.1:port" | null, hostReachable: "addr:port" } ] },
        segments: [ { segment, subnet, ip, prefixLength, mac, names } ], events: [ Event ], panic?: { line, offset, at },
        provision?: { vm, finishedAt, steps: [ { name, command, status, exitCode?, durationMs?,
          error? } ] }, warnings }
      """,
    errors: [.vmNotFound])
}
