import VMLabCore

extension ToolSpec {
  static let vmCreate = ToolSpec(
    name: "vm_create",
    summary:
      "Create a VM from requirements: plans it (as vm_plan), pulls the image if needed, "
      + "provisions it (SSH key, cloud-init) and by default starts it and waits for SSH. Ask in "
      + "require for every channel you will use (serial, gdb, gui, checkpoint_live, ...): tools "
      + "for channels the plan did not grant fail later with capability_missing. Returns the "
      + "resolved plan, so read it to know what you got, plus the VM, its state and endpoints. "
      + "Requested port forwards are QEMU loopback ports or, on VZ, the guest's own NAT address; "
      + "forwarding says which, and endpoints.forwards[].hostReachable is where to connect. "
      + "Slow (tens of seconds to minutes); sends progress.",
    inputSchema: Schema.input(
      [
        "requirements": Schema.requirements,
        "name": Schema.vmName("A unique name for the VM; defaults to its id."),
        "autostart": Schema.boolean("Start the VM once created.", default: true),
        "confirm": Schema.boolean("Allow a large image pull the server asks to confirm."),
        "allowUnverified": Schema.allowUnverified,
      ], required: ["requirements"]),
    outputShape: """
      { plan: Plan, vm: { id, name }, state,
        endpoints: { ssh?: "host:port", ip?, serial?, display?, gdb?,
          forwards?: [ { guest, host: "127.0.0.1:port" | null, hostReachable: "addr:port" } ] },
        forwarding: { mode: hostfwd | host_reachable, note } | null }
      """,
    errors: [
      .invalidRequest, .unsatisfiable, .unverifiedCapability, .limitMacOSGuests, .limitMemory,
      .hostMissingTool, .imageNotFound, .confirmRequired, .provisionFailed, .timeout, .engineError,
    ])
}
