import VMLabCore

extension ToolSpec {
  static let vmFile = ToolSpec(
    name: "vm_file",
    summary:
      "Copy files between the host and the guest over SSH. push copies the host path local to "
      + "the guest path remote; pull copies remote to local, or into the VM's pulled/ directory "
      + "when local is omitted. Directories copy recursively. Returns the bytes copied and the "
      + "destination path.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "action": Schema.action(["push", "pull"], "Direction of the copy."),
        "remote": Schema.string("Path in the guest."),
        "local": Schema.string(
          "Absolute path on the host (push: required, under your home or /tmp; pull: optional, "
            + "under /tmp, $TMPDIR or ~/vmlab-files, never a home dotfile or ~/Library)."),
      ], required: ["vm", "action", "remote"]),
    outputShape: "{ bytes, path }",
    errors: [
      .vmNotFound, .wrongState, .capabilityMissing, .guestUnreachable, .invalidRequest, .timeout,
    ])
}
