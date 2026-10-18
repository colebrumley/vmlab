import VMLabCore

extension ToolSpec {
  static let vmLifecycle = ToolSpec(
    name: "vm_lifecycle",
    summary:
      "Change a VM's power state. start boots it and waits for SSH; stop shuts it down "
      + "gracefully (ACPI, then kill after the timeout); kill stops it at once; pause and "
      + "resume freeze and thaw it in memory; reset returns the CPU to its first instruction, "
      + "keeping breakpoints; destroy deletes the VM and its disk (force when another VM's disk "
      + "is backed by it); clone makes a new VM name from this one's current disk or from "
      + "checkpoint from. Illegal transitions fail with wrong_state listing the legal actions.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "action": Schema.action(
          ["start", "stop", "kill", "pause", "resume", "reset", "destroy", "clone"],
          "The transition."),
        "name": Schema.string("clone: the new VM's name."),
        "from": Schema.string("clone: a checkpoint name to clone from (default: current disk)."),
        "force": Schema.boolean("destroy: even when another VM's disk depends on this one."),
        "timeoutSeconds": Schema.timeoutSeconds(
          "start: how long to wait for SSH; stop: the grace period before kill."),
      ], required: ["vm", "action"]),
    outputShape: """
      { vm: { id, name }, state, durationMs }
      clone: { vm: { id, name } (the new VM), state, plan }
      """,
    errors: [
      .vmNotFound, .wrongState, .capabilityMissing, .limitMacOSGuests, .limitMemory, .timeout,
      .engineError,
    ])
}
