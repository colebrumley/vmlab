import Foundation
import VMLabCore

/// `vm_create`: plans the request as `vm_plan` does (an impossible one is its refusal), pulls the
/// image when it is not pulled yet, has `VMManager` create the VM and, unless `autostart` is
/// false, starts it under the start gate. Each slow step reports progress. The call is all or
/// nothing: if it is cancelled or a later step fails, the VM is destroyed and no directory is left.
struct VMCreateHandler: ToolHandler {
  var spec: ToolSpec { .vmCreate }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let requirements = try Requirements.decode(json: arguments["requirements"]?.data ?? Data())
    let name = try arguments.string("name")
    let autostart = try arguments.bool("autostart", default: true)
    let allowUnverified = try arguments.bool("allowUnverified")

    let plan: Plan
    switch ProfileSelector.select(
      requirements, host: context.hostFacts(), running: context.store.inventory(),
      allowUnverified: allowUnverified, limits: context.limits)
    {
    case .success(let selected): plan = selected
    case .failure(let unsatisfiable): throw unsatisfiable.error
    }
    await context.progress.step("planned \(plan.profile.rawValue)")

    let images = context.images
    let image = try Self.image(
      for: requirements, catalogue: images.catalogue, guestOf: { images.guest(of: $0) })
    var warnings: [String] = []
    let confirm = try arguments.bool("confirm")
    if try await LongOperation.pullIfMissing(image, confirm: confirm, context: context) != nil {
      warnings.append("pulled image \(image) first")
    }
    try LongOperation.checkCancellation("vm_create")

    let draft = VMRecord(
      id: "", name: name, profile: plan.profile, guest: plan.guest, features: plan.features,
      resources: plan.resources, image: image, network: requirements.network,
      boot: requirements.boot, extra: requirements.extra, provision: requirements.provision,
      share: requirements.share)
    let manager = context.manager
    let created = try await context.progress.during(
      "creating the VM", every: context.heartbeat
    ) { () throws(VMLabError) -> VMRecord in
      try await manager.create(draft, plan: plan)
    }

    var record = created
    do throws(VMLabError) {
      try LongOperation.checkCancellation("vm_create", vm: created.id)
      if autostart {
        let started = try await LongOperation.start(created, context: context)
        record = started.record
        warnings += started.warnings
        try LongOperation.checkCancellation("vm_create", vm: created.id)
      }
    } catch {
      // Not under the cancelled task, so the destroy runs to the end.
      await Task { _ = try? await manager.perform(.destroy, on: created.id) }.value
      throw error
    }

    if let note = Self.forwardingNote(record) { warnings.append(note) }
    let object: [String: JSONValue] = [
      "plan": try JSONValue(encoding: plan),
      "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
      "state": .string(record.state.rawValue),
      "endpoints": .object(VMInspectHandler.endpoints(record, store: context.store)),
      "forwarding": Self.forwarding(record),
    ]
    return ToolResult(object, warnings: warnings)
  }

  /// How the requested forwards were given (R-905): `hostfwd` on QEMU (loopback ports in
  /// `endpoints.forwards[].host`), `host_reachable` on VZ (no mapping; connect to the guest's NAT
  /// address, `endpoints.forwards[].hostReachable`), null when nothing was asked for.
  static func forwarding(_ record: VMRecord) -> JSONValue {
    guard !record.network.forwards.isEmpty else { return .null }
    if record.profile.isVZ {
      return .object([
        "mode": .string("host_reachable"),
        "note": .string(
          "VZ guests get no port mapping: the host reaches the guest's NAT address directly, so "
            + "connect to endpoints.forwards[].hostReachable (<guest ip>:<guest port>)."),
      ])
    }
    return .object([
      "mode": .string("hostfwd"),
      "note": .string(
        "Each guest port is forwarded to a loopback port: connect to "
          + "endpoints.forwards[].hostReachable (127.0.0.1:<host port>)."),
    ])
  }

  /// A warning when a VZ guest was asked for a host port it cannot have.
  static func forwardingNote(_ record: VMRecord) -> String? {
    guard record.profile.isVZ else { return nil }
    let mapped = record.network.forwards.filter { $0.host != nil && $0.host != $0.guest }
    guard !mapped.isEmpty else { return nil }
    let ports = mapped.map { "\($0.guest)->\($0.host ?? 0)" }.joined(separator: ", ")
    return "forwards_not_mapped: \(record.profile.rawValue) cannot map host ports (\(ports)); "
      + "reach the guest ports at its NAT address (endpoints.forwards[].hostReachable)"
  }

  /// The image the VM boots: the request's, or the first catalogue image for its guest. A named
  /// image whose guest (`guestOf`, else the catalogue's) differs from the request's is refused,
  /// so an amd64 image never lands on a profile that cannot run it (R-1000).
  static func image(
    for requirements: Requirements, catalogue: ImageCatalogue,
    guestOf: (String) -> GuestSpec? = { _ in nil }
  ) throws(VMLabError) -> String {
    if let image = requirements.image {
      // Fleet sets `image` after decoding, so the name is checked here too (CR-4).
      try ImageStore.checkName(image, field: "image")
      let guest = guestOf(image) ?? catalogue.image(named: image)?.guest
      if let guest, guest != requirements.guest {
        throw VMLabError.invalidRequest(
          field: "image",
          reason:
            "\(image) is a \(guest.os.rawValue) \(guest.arch.rawValue) image but the request's "
            + "guest is \(requirements.guest.os.rawValue) \(requirements.guest.arch.rawValue)",
          hint:
            "Set guest to {os: \(guest.os.rawValue), arch: \(guest.arch.rawValue)}"
            + (guest.arch == .arm64 ? "" : " (it runs under qemu-tcg)")
            + ", or name an image for the guest you asked for.")
      }
      return image
    }
    guard let entry = catalogue.images.first(where: { $0.guest == requirements.guest }) else {
      throw VMLabError(
        code: .imageNotFound,
        message:
          "No catalogue image for a \(requirements.guest.os.rawValue) "
          + "\(requirements.guest.arch.rawValue) guest",
        hint: "Name one in requirements.image; images list shows them.",
        data: [
          "name": .null, "available": .array(catalogue.images.map { .string($0.name) }),
        ])
    }
    return entry.name
  }
}
