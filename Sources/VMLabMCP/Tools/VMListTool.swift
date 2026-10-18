import VMLabCore

extension ToolSpec {
  static let vmList = ToolSpec(
    name: "vm_list",
    summary:
      "List the VMs vmlab knows, optionally only those in one state or one fleet, with each "
      + "one's id, name, profile, state, guest, fleet, IP and SSH port. Use it to find a VM's id "
      + "or to see what is running before creating more (the host runs at most two macOS guests).",
    inputSchema: Schema.input([
      "state": Schema.string(
        "Only VMs in this state.", enum: VMState.allCases.map(\.rawValue)),
      "fleet": Schema.string("Only members of this fleet."),
    ]),
    outputShape: """
      { vms: [ { id, name, profile, state, guest: { os, arch }, fleet?, ip?, sshPort? } ] }
      """,
    errors: [.invalidRequest])
}
