import Foundation
import VMLabCore

/// `vm_plan`: the selector as a dry run. An impossible request is a result, not an error:
/// `satisfiable: false` with the `Unsatisfiable` detail and the refusal `vm_create` would give.
struct VMPlanHandler: ToolHandler {
  var spec: ToolSpec { .vmPlan }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let requirements = try Requirements.decode(json: arguments["requirements"]?.data ?? Data())
    let allowUnverified = try arguments.bool("allowUnverified")
    let outcome = ProfileSelector.select(
      requirements, host: await context.hostFacts(), running: context.store.inventory(),
      allowUnverified: allowUnverified, limits: context.limits)
    switch outcome {
    case .success(let plan):
      // What vm_create would refuse for the owner's allowNAT.
      let mode: NetworkSpec.Mode? =
        plan.requests(.netIsolated)
        ? .isolated : plan.requests(.netNone) ? .disabled : requirements.network.mode
      do {
        try VMLabConfig.load(home: context.store.home).checkNetwork(
          mode: mode, extra: requirements.extra, home: context.store.home)
      } catch {
        // A result like any other impossible request (R-204), with vm_create's refusal.
        var refusal = error.data
        refusal["satisfiable"] = .bool(false)
        refusal["code"] = .string(error.code.rawValue)
        refusal["message"] = .string(error.message)
        refusal["hint"] = .string(error.hint)
        return ToolResult(refusal)
      }
      var object = try JSONValue(encoding: plan).objectValue ?? [:]
      object["satisfiable"] = .bool(true)
      return ToolResult(object)
    case .failure(let unsatisfiable):
      return ToolResult(try Self.render(unsatisfiable))
    }
  }

  /// `Unsatisfiable` as the model sees it, with the refusal's code, message and hint.
  static func render(_ u: Unsatisfiable) throws(VMLabError) -> [String: JSONValue] {
    let error = u.error
    var object: [String: JSONValue] = [
      "satisfiable": .bool(false),
      "code": .string(error.code.rawValue),
      "message": .string(error.message),
      "hint": .string(error.hint),
      "guest": try JSONValue(encoding: u.guest),
      "eliminated": .object(
        Dictionary(
          uniqueKeysWithValues: u.eliminated.map { feature, profiles in
            (feature.rawValue, .array(profiles.map { .string($0.rawValue) }))
          })),
      "reasons": .object(
        Dictionary(
          uniqueKeysWithValues: u.reasons.map { feature, byProfile in
            (
              feature.rawValue,
              .object(
                Dictionary(
                  uniqueKeysWithValues: byProfile.map { ($0.key.rawValue, .string($0.value)) }))
            )
          })),
      "suggestions": try JSONValue(encoding: u.suggestions),
      "unverified": .object(
        Dictionary(
          uniqueKeysWithValues: u.unverified.map { feature, probes in
            (feature.rawValue, .array(probes.map { .string($0.rawValue) }))
          })),
    ]
    if let limit = u.limit { object["limit"] = try JSONValue(encoding: limit) }
    return object
  }
}
