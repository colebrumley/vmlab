import VMLabCore

extension ToolSpec {
  static let vmMemoryDump = ToolSpec(
    name: "vm_memory_dump",
    summary:
      "Write guest physical memory to a file on the host: the range of size bytes at address as "
      + "raw bytes, or, with neither, all memory as an ELF core for crash or volatility. It goes "
      + "under the VM's dumps/ directory, which destroy removes, or to local, a host path that "
      + "outlives the VM (the write rules of vm_file pull: under /tmp, $TMPDIR, ~/vmlab-files or "
      + "the owner's writeRoots; a directory gets the default name, a file is replaced). Ranges over \(VMMemoryDumpHandler.confirmAbove >> 20) MB need "
      + "confirm: true. Returns the path, size "
      + "and format; read it with host tools. Needs the memory_dump feature.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "address": Schema.string("Guest physical start address in 0x hex."),
        "size": Schema.integer("Bytes to dump from address.", minimum: 1),
        "local": Schema.string(
          "Absolute host path for the dump file, or an existing directory for it; default the "
            + "VM's dumps/ directory."),
        "confirm": Schema.boolean("Allow a dump the server asks to confirm (it states the size)."),
      ], required: ["vm"]),
    outputShape: "{ path, bytes, format: raw|elf }",
    errors: [
      .vmNotFound, .wrongState, .capabilityMissing, .invalidRequest, .confirmRequired,
      .engineError,
    ])
}
