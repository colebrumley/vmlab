import VMLabCore

extension ToolSpec {
  static let vmJob = ToolSpec(
    name: "vm_job",
    summary:
      "Follow a background command started by vm_exec with background: true. read returns the "
      + "output written since the last read and whether the job finished; wait blocks until it "
      + "finishes or timeoutSeconds passes, then returns like read; kill stops it. Jobs survive "
      + "a server restart.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "job": Schema.string("The job id vm_exec returned."),
        "action": Schema.action(["read", "wait", "kill"], "What to do with the job."),
        "timeoutSeconds": Schema.timeoutSeconds("wait: the longest to block."),
      ], required: ["vm", "job", "action"]),
    outputShape: "{ output, finished, exitCode? }",
    errors: [.vmNotFound, .invalidRequest, .guestUnreachable, .timeout])
}
