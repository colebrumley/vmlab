import VMLabCore

extension ToolSpec {
  static let vmSerial = ToolSpec(
    name: "vm_serial",
    summary:
      "The guest's serial console, captured from the first byte of boot. Offsets are byte "
      + "offsets into the VM's console log, which keeps every run and is written whether or not "
      + "anyone is reading, so they hold across calls, CLI invocations and server restarts. read "
      + "returns text from byte offset since (default: where the VM's last start began; 0 reaches "
      + "earlier runs); tail returns the last lines lines; write sends text (include \\n to press "
      + "Enter); wait blocks until the regular expression pattern appears after since or "
      + "timeoutSeconds passes. Every result returns the offset to pass as since next time. Use "
      + "it to watch boot, kernel messages and panics, or to run commands when SSH is down: on a "
      + "Linux guest the console is a root shell (write \\n, wait for \"# \"). Needs the serial "
      + "feature.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "action": Schema.action(["read", "tail", "write", "wait"], "What to do."),
        "since": Schema.integer(
          "read, wait: the byte offset to start from (default: the start of this run).",
          minimum: 0),
        "lines": Schema.integer(
          "tail: how many lines.", minimum: 1, maximum: VMSerialHandler.maxTail, default: 50),
        "text": Schema.string("write: the text to send."),
        "pattern": Schema.string(
          "wait: a regular expression to wait for, at most \(SerialChannel.maxPatternBytes) "
            + "UTF-8 bytes.", maxLength: SerialChannel.maxPatternBytes),
        "timeoutSeconds": Schema.timeoutSeconds(
          "wait: the longest to block.", maximum: VMSerialHandler.maxTimeoutSeconds, default: 30),
      ], required: ["vm", "action"]),
    outputShape: "{ text, offset, matched?, truncated }",
    errors: [.vmNotFound, .wrongState, .capabilityMissing, .invalidRequest, .timeout])
}
