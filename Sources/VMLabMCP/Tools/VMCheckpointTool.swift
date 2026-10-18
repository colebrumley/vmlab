import VMLabCore

extension ToolSpec {
  static let vmCheckpoint = ToolSpec(
    name: "vm_checkpoint",
    summary:
      "Named snapshots of a VM, kept as a tree. create saves one (mode live includes memory and "
      + "needs checkpoint_live; disk needs a stopped guest; auto picks live when it can, and "
      + "never stops the guest for you); manifest: true also records what is installed so diff "
      + "can compare. list returns the tree; restore returns the VM to name; delete removes it "
      + "(recursive for one with children). diff compares from and to, each a checkpoint name, "
      + "a manifest id or @now, and lists changed files, packages, services, defaults, users "
      + "and login items. @latest names the newest checkpoint.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "action": Schema.action(["create", "list", "restore", "delete", "diff"], "What to do."),
        "name": Schema.vmName("create, restore, delete: the checkpoint's name; unique per VM."),
        "mode": Schema.string(
          "create: what to save.", enum: ["auto", "disk", "live"], default: "auto"),
        "manifest": Schema.boolean("create: also take a guest manifest for diff."),
        "note": Schema.string("create: a note kept with the checkpoint."),
        "recursive": Schema.boolean("delete: also delete its descendants."),
        "from": Schema.string("diff: the older side (checkpoint, manifest id or @now)."),
        "to": Schema.string("diff: the newer side (checkpoint, manifest id or @now)."),
      ], required: ["vm", "action"]),
    outputShape: """
      create: { checkpoint: { id, name, parent?, mode, createdAt, state, manifestPath?, note? } }
      list: { current?, nodes: [ checkpoint ] }; restore: { checkpoint, state }; delete: { deleted }
      diff: { from, to, path, files, packages, services, defaults, users, loginItems, profiles },
      each section { added, removed, changed, truncated, entries (at most 500) }: files
      { path, change, kind, changes: { size|mode|sha256|kind|mtime: { old, new } } }, defaults
      { domain, key, change, old, new }, the others { name, change, old, new }
      """,
    errors: [
      .vmNotFound, .wrongState, .capabilityMissing, .invalidRequest, .unverifiedCapability,
      .guestUnreachable, .engineError,
    ])
}
