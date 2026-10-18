import Foundation
import VMLabCore

/// `vm_manifest`: takes a guest manifest over the VM's exec channel (R-801) and stores it under
/// `<vm>/manifests/<id>.json`. `profile` defaults to the guest's OS; `custom` needs `paths`.
struct VMManifestHandler: ToolHandler {
  var spec: ToolSpec { .vmManifest }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let record = try context.store.find(try arguments.string("vm") ?? "")
    let (profile, paths) = try Self.options(arguments, guest: record.guest.os)
    let manifest = try await Self.take(record, profile: profile, paths: paths, context: context)
    return ToolResult(
      Self.summary(manifest, record: record, store: context.store),
      warnings: manifest.warnings)
  }

  /// The profile and roots the arguments name; `invalid_request` for a malformed field.
  static func options(_ arguments: ToolArguments, guest: GuestSpec.OS) throws(VMLabError)
    -> (ManifestProfile, [String])
  {
    var profile = ManifestProfile(os: guest)
    if let name = try arguments.string("profile") {
      guard let named = ManifestProfile(rawValue: name) else {
        throw VMLabError.invalidRequest(
          field: "profile", reason: "profile must be linux, macos or custom",
          hint: "Pick linux, macos or custom, or omit it to use the guest's OS.")
      }
      profile = named
    }
    var paths: [String] = []
    if let value = arguments["paths"] {
      guard let array = value.arrayValue else { throw ToolArguments.mismatch("paths", "an array") }
      for item in array {
        guard let path = item.stringValue else {
          throw ToolArguments.mismatch("paths", "an array of strings")
        }
        paths.append(path)
      }
    }
    try GuestManifests.validate(paths: paths)
    if profile == .custom, paths.isEmpty {
      throw VMLabError.invalidRequest(
        field: "paths", reason: "profile custom records only paths, and none were given",
        hint: "Pass paths, or use profile linux or macos.")
    }
    return (profile, paths)
  }

  /// Takes and stores a manifest of `record`, which must be running (`wrong_state` otherwise).
  static func take(
    _ record: VMRecord, profile: ManifestProfile, paths: [String], context: ToolContext
  ) async throws(VMLabError) -> GuestManifest {
    try GuestManifests.requireRunning(record)
    let vm = try await context.manager.attach(record.id)
    let channel = try GuestManifests.channel(of: vm)
    let manifests = GuestManifests(store: context.store)
    return try await context.progress.during(
      "taking a \(profile.rawValue) manifest of \(record.id)", every: context.heartbeat
    ) { () throws(VMLabError) -> GuestManifest in
      try await manifests.take(record, over: channel, profile: profile, paths: paths)
    }
  }

  static func summary(_ manifest: GuestManifest, record: VMRecord, store: Store)
    -> [String: JSONValue]
  {
    [
      "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
      "id": .string(manifest.id),
      "path": .string(store.manifestURL(of: record.id, id: manifest.id).path),
      "profile": .string(manifest.profile.rawValue),
      "counts": .object(manifest.counts.mapValues { .number(Double($0)) }),
    ]
  }
}
