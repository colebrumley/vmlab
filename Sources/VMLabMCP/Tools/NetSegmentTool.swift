import VMLabCore

extension ToolSpec {
  static let netSegment = ToolSpec(
    name: "net_segment",
    summary:
      "Manage private host-local Ethernet segments that guests join with a second NIC "
      + "(requirements.network.segment), so guests on one Mac can reach each other by name. "
      + "create makes segment name with its own 10.n.0.0/24 subnet; list shows every segment and "
      + "its members; destroy removes one. Segments carry no internet; guests keep NAT for that.",
    inputSchema: Schema.input(
      [
        "action": Schema.action(["create", "list", "destroy"], "What to do."),
        "name": Schema.string("create, destroy: the segment's name."),
      ], required: ["action"]),
    outputShape: """
      { name, subnet, members: [ { vm, ip } ] }
      list: { segments: [ { name, subnet, members } ] }
      """,
    errors: [.invalidRequest, .wrongState])
}
