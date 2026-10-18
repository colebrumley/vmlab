import VMLabCore

extension ToolSpec {
  static let vmSerial = ToolSpec(
    name: "vm_serial",
    summary:
      "The guest's serial console, captured from the first byte of boot. read returns text from "
      + "byte offset since (default: the start of the buffer); tail returns the last lines lines; "
      + "write sends text (include \\n to press Enter); wait blocks until the regular expression "
      + "pattern appears after since or timeoutSeconds passes. Every result returns the offset "
      + "to pass as since next time. Use it to watch boot, kernel messages and panics, or to log "
      + "in when SSH is down. Needs the serial feature.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "action": Schema.action(["read", "tail", "write", "wait"], "What to do."),
        "since": Schema.integer("read, wait: the byte offset to start from.", minimum: 0),
        "lines": Schema.integer("tail: how many lines.", minimum: 1, default: 50),
        "text": Schema.string("write: the text to send."),
        "pattern": Schema.string("wait: a regular expression to wait for."),
        "timeoutSeconds": Schema.timeoutSeconds("wait: the longest to block.", default: 30),
      ], required: ["vm", "action"]),
    outputShape: "{ text, offset, matched?, truncated }",
    errors: [.vmNotFound, .wrongState, .capabilityMissing, .invalidRequest, .timeout])
}
