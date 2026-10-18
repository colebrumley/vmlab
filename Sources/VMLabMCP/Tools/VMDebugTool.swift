import VMLabCore

extension ToolSpec {
  static let vmDebug = ToolSpec(
    name: "vm_debug",
    summary:
      "Debug the guest CPU through its GDB stub. info gives the endpoint a human can attach to "
      + "and whether vmlab is attached; halt stops the CPU; continue resumes; step executes one "
      + "instruction; wait blocks until the CPU stops (breakpoint, watchpoint) or timeoutSeconds; "
      + "breakpoint_add sets one at address (kind software, hardware, or a watch_* watchpoint "
      + "over size bytes); breakpoint_remove clears it; breakpoints lists them; registers reads "
      + "them; read_memory returns size bytes at address as hex (with ASCII up to 256 bytes); "
      + "write_memory writes hex data. Addresses are numbers in 0x hex; no symbols. Needs gdb; "
      + "require halt_at_start to debug from the first instruction. The first action that "
      + "needs the stub attaches, and QEMU stops the guest when a debugger attaches; continue "
      + "resumes it. Breakpoints set on a running CPU leave it running.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "action": Schema.action(
          [
            "info", "halt", "continue", "step", "wait", "breakpoint_add", "breakpoint_remove",
            "breakpoints", "registers", "read_memory", "write_memory",
          ], "What to do."),
        "address": Schema.string("Guest address in 0x hex, e.g. 0xffff800010000000."),
        "size": Schema.integer(
          "read_memory: bytes to read; watchpoints: bytes to watch.", minimum: 1),
        "data": Schema.string("write_memory: the bytes as hex, e.g. 1f2003d5."),
        "kind": Schema.string(
          "breakpoint_add, breakpoint_remove: the kind of stop point.",
          enum: ["software", "hardware", "watch_write", "watch_read", "watch_access"],
          default: "software"),
        "timeoutSeconds": Schema.timeoutSeconds("wait: the longest to block.", default: 30),
        "thread": Schema.string(
          "step, continue, registers, read_memory, write_memory: the thread (CPU) to act on, "
            + "as a stop reports it (e.g. p01.02)."),
        "symbolFile": Schema.string(
          "A host path to the guest's symbol file (vmlinux, a kernel .debug), recorded for the "
            + "info output so a human can load it; vmlab resolves no symbols."),
      ], required: ["vm", "action"]),
    outputShape: """
      { stopped, reason?, pc?, registers?: { <name>: hex }, bytes?: hex, ascii?,
        breakpoints?: [ { address, kind, size? } ], endpoint, attached,
        info: connect: { gdb, lldb }, symbolFile, note }
      """,
    errors: [
      .vmNotFound, .wrongState, .capabilityMissing, .invalidRequest, .debugBusy, .timeout,
      .engineError,
    ])
}
