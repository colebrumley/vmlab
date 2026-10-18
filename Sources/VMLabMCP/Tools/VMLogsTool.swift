import VMLabCore

extension ToolSpec {
  static let vmLogs = ToolSpec(
    name: "vm_logs",
    summary:
      "Read a VM's logs on the host: events (lifecycle, panics, warnings), serial (the console "
      + "log), provision (first-boot steps), or all of them interleaved. Works for stopped VMs. "
      + "Use it to find out why a VM failed to boot or provision.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "source": Schema.string(
          "Which log.", enum: ["events", "serial", "provision", "all"], default: "all"),
        "tail": Schema.integer("Return only the last tail lines.", minimum: 1, default: 100),
      ], required: ["vm"]),
    outputShape: "{ lines: [String] }",
    errors: [.vmNotFound, .invalidRequest])
}
