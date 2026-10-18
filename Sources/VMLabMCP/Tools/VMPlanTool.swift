import VMLabCore

extension ToolSpec {
  static let vmPlan = ToolSpec(
    name: "vm_plan",
    summary:
      "Dry-run the selector: given requirements (the guest plus the features you need and "
      + "prefer), say which engine profile would run the VM and what it would have, without "
      + "creating anything. Use it before vm_create when unsure a combination is possible. An "
      + "impossible request is not an error: the result is an Unsatisfiable object naming which "
      + "profiles each feature ruled out and the smallest sets of features to drop.",
    inputSchema: Schema.input(
      ["requirements": Schema.requirements, "allowUnverified": Schema.allowUnverified],
      required: ["requirements"]),
    outputShape: """
      Plan { profile, features, unverified, preferredDenied, estimatedStartupSeconds, notes }
      or Unsatisfiable { eliminated: { <feature>: [profile] },
                         suggestions: [ { drop: [feature], profile } ] }
      """,
    errors: [.invalidRequest])
}
