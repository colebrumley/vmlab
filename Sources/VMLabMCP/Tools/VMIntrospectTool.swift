import VMLabCore

extension ToolSpec {
  static let vmIntrospect = ToolSpec(
    name: "vm_introspect",
    summary:
      "Ask the engine about the machine rather than the guest OS: status (run state), block "
      + "(disks), pci (devices on the bus), cpus, memory_tree (the physical memory map), "
      + "registers (every CPU), devices (the device tree), or raw for a read-only QMP query-* "
      + "command (qmp) or HMP info command (hmp). Works even when the guest is hung. Returns the "
      + "engine's answer as JSON or text. Needs the introspection feature (QEMU profiles).",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "query": Schema.string(
          "What to ask.",
          enum: [
            "status", "block", "pci", "cpus", "memory_tree", "registers", "devices", "raw",
          ]),
        "qmp": Schema.string("raw: a read-only QMP command, e.g. query-chardev."),
        "hmp": Schema.string("raw: an HMP info command, e.g. info mtree."),
      ], required: ["vm", "query"]),
    outputShape: "{ query, json? | text? }",
    errors: [.vmNotFound, .wrongState, .capabilityMissing, .invalidRequest, .engineError])
}
