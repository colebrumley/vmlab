import VMLabCore

extension ToolSpec {
  static let vmManifest = ToolSpec(
    name: "vm_manifest",
    summary:
      "Take a manifest of the running guest over SSH: files under paths (size, mode, mtime, "
      + "sha256) and, for profile linux, packages, enabled services, users and /etc hashes; for "
      + "macos also defaults domains, Homebrew packages, launchd jobs, profiles and login items; "
      + "custom covers only paths. Stored on the host; returns its id (usable as vm_checkpoint "
      + "diff from or to), path and counts per section.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "profile": Schema.string(
          "What to record besides paths; defaults to the guest's OS.",
          enum: ["linux", "macos", "custom"]),
        "paths": Schema.array(
          Schema.string("A directory or file in the guest."), "Roots to walk for files."),
      ], required: ["vm"]),
    outputShape: "{ id, path, counts: { files, packages, services, defaults, users, loginItems } }",
    errors: [.vmNotFound, .wrongState, .capabilityMissing, .guestUnreachable, .timeout])
}
