import VMLabCore

extension ToolSpec {
  static let vmExec = ToolSpec(
    name: "vm_exec",
    summary:
      "Run a shell command in the guest and return its exit code, stdout and stderr. Uses SSH, "
      + "or the guest agent when the VM has no network (via). Output over 64 KB keeps the head "
      + "and tail, sets truncated and saves the whole text at logPath. A command that outlives "
      + "timeoutSeconds is killed and fails with timeout carrying the partial output. For long "
      + "work pass background: true and poll the returned job with vm_job.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "command": Schema.string("The command, run by the guest's shell."),
        "timeoutSeconds": Schema.timeoutSeconds("Kill the command after this long.", default: 120),
        "cwd": Schema.string("Working directory in the guest."),
        "env": Schema.object(
          [:], description: "Extra environment variables.",
          additionalProperties: Schema.string("The variable's value.")),
        "stdin": Schema.string("Text fed to the command's standard input."),
        "user": Schema.string("Run as this guest user (sudo) instead of the login user."),
        "via": Schema.string(
          "Transport: auto prefers SSH, else the guest agent.", enum: ["auto", "ssh", "agent"],
          default: "auto"),
        "background": Schema.boolean("Return a job id at once instead of waiting."),
      ], required: ["vm", "command"]),
    outputShape: """
      { exitCode, stdout, stderr, durationMs, truncated, logPath? }
      background: { job }
      """,
    errors: [
      .vmNotFound, .wrongState, .capabilityMissing, .guestUnreachable, .timeout, .invalidRequest,
    ])
}
