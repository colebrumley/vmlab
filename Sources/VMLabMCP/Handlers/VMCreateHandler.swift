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

    let image = try Self.image(for: requirements, catalogue: context.images.catalogue)
    var warnings: [String] = []
    if try await LongOperation.pullIfMissing(image, context: context) != nil {
      warnings.append("pulled image \(image) first")
    }
    try LongOperation.checkCancellation("vm_create")

    let draft = VMRecord(
      id: "", name: name, profile: plan.profile, guest: plan.guest, features: plan.features,
      resources: plan.resources, image: image, network: requirements.network,
      boot: requirements.boot, extra: requirements.extra)
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

    let object: [String: JSONValue] = [
      "plan": try JSONValue(encoding: plan),
      "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
      "state": .string(record.state.rawValue),
      "endpoints": .object(VMInspectHandler.endpoints(record.runtime)),
    ]
    return ToolResult(object, warnings: warnings)
  }

  /// The image the VM boots: the request's, or the first catalogue image for its guest.
  static func image(for requirements: Requirements, catalogue: ImageCatalogue)
    throws(VMLabError) -> String
  {
    if let image = requirements.image { return image }
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
