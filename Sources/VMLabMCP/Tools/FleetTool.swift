import VMLabCore

extension ToolSpec {
  static let fleet = ToolSpec(
    name: "fleet",
    summary:
      "Run several identical VMs as a group. create makes count members named <name>-1 to "
      + "<name>-n from one plan of requirements (or image, a template), joins them to segment "
      + "(auto makes one) and waits for SSH on each; some members may fail and are listed with "
      + "their error. status reports each member; list shows fleets; exec runs command on every "
      + "member, or on members, in parallel, with vm_exec's options, and returns each member's result "
      + "and allSucceeded; destroy removes the fleet and its VMs, keeping (and listing in failed) any "
      + "member it could not destroy, such as one whose disk backs another VM.",
    inputSchema: Schema.input(
      [
        "action": Schema.action(["create", "list", "status", "exec", "destroy"], "What to do."),
        "name": Schema.string("The fleet's name (every action but list)."),
        "count": Schema.integer("create: how many members.", minimum: 1),
        "requirements": Schema.requirements,
        "allowUnverified": Schema.allowUnverified,
        "image": Schema.string("create: image or template; overrides requirements.image."),
        "segment": Schema.string("create: segment to join, or auto to make one for the fleet."),
        "command": Schema.string("exec: the command, as for vm_exec."),
        "cwd": Schema.string("exec: working directory in each guest."),
        "env": Schema.object(
          [:], description: "exec: extra environment variables.",
          additionalProperties: Schema.string("The variable's value.")),
        "stdin": Schema.string("exec: text fed to each member's command."),
        "user": Schema.string("exec: run as this guest user (sudo) instead of the login user."),
        "via": Schema.string(
          "exec: transport, as for vm_exec.", enum: ["auto", "ssh", "agent"], default: "auto"),
        "members": Schema.array(
          Schema.string("A member's name."), "exec: only these members.", unique: true),
        "timeoutSeconds": Schema.timeoutSeconds(
          "create: per-member wait for SSH; exec: per-member command timeout."),
      ], required: ["action"]),
    outputShape: """
      create, status: { name, segment, subnet, members: [ { vm, id, state, ip?, natIP?,
        forwards?: [ { guest, host, hostReachable } ], error? } ] }
      list: { fleets: [ { name, members } ] }
      exec: { results: { <member>: ExecResult }, allSucceeded }
      destroy: { destroyed: [vm], failed: [ { vm, id, error } ] }
      """,
    errors: [
      .invalidRequest, .unsatisfiable, .unverifiedCapability, .limitMacOSGuests, .limitMemory,
      .imageNotFound, .vmNotFound, .timeout, .wrongState,
    ])
}
