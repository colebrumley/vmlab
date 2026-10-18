import VMLabCore

extension ToolSpec {
  static let hostDoctor = ToolSpec(
    name: "host_doctor",
    summary:
      "Check the host's prerequisites (QEMU, Tart, Rosetta, the signed VZ runner and its "
      + "entitlement, free memory and disk, running guest counts) and report each as ok, missing "
      + "or unknown with the command that fixes it, plus the persisted slow-probe results with "
      + "their dates. Use it when a tool reports host_missing_tool or unverified_capability. "
      + "probe: true also runs the slow probes, each booting a throwaway guest (minutes), and "
      + "records their answers so later plans can rely on them.",
    inputSchema: Schema.input([
      "probe": Schema.boolean(
        "Also run the slow probes (live snapshots, GDB under HVF, vmnet); takes minutes.")
    ]),
    outputShape: """
      { checks: [ { check, status: ok|missing|unknown, fix? } ],
        probes: { <probe>: { result: yes|no|unknown, probedAt? } } }
      """,
    errors: [.hostMissingTool, .limitMemory, .timeout])
}
