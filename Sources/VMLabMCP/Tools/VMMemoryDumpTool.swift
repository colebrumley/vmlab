import VMLabCore

extension ToolSpec {
  static let vmMemoryDump = ToolSpec(
    name: "vm_memory_dump",
    summary:
      "Write guest physical memory to a file on the host under the VM's dumps/ directory: the "
      + "range of size bytes at address as raw bytes, or, with neither, all memory as an ELF core "
      + "for crash or volatility. Ranges over 256 MB need confirm: true. Returns the path, size "
      + "and format; read it with host tools. Needs the memory_dump feature.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "address": Schema.string("Guest physical start address in 0x hex."),
        "size": Schema.integer("Bytes to dump from address.", minimum: 1),
        "confirm": Schema.boolean("Allow a dump the server asks to confirm (it states the size)."),
      ], required: ["vm"]),
    outputShape: "{ path, bytes, format: raw|elf }",
    errors: [
      .vmNotFound, .wrongState, .capabilityMissing, .invalidRequest, .confirmRequired,
      .engineError,
    ])
}
