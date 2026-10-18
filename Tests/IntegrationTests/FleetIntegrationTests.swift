import Foundation
import Testing
import VMLabCore
import VMLabMCP

@Suite(.serialized) struct FleetIntegrationTests {
  /// A tool context over a `LabHome`: its backends and its manager (whose switch is the built one).
  static func context(_ lab: LabHome) -> ToolContext {
    var context = ToolContext(home: lab.home, backends: lab.registry, startGate: StartGate())
    context.manager = lab.manager
    return context
  }

  static func fleet(_ context: ToolContext, _ arguments: [String: JSONValue]) async throws
    -> JSONValue
  {
    try await ToolHandlers.call("fleet", arguments: .object(arguments), context: context).value
  }

  static let requirements: JSONValue = .object([
    "guest": .object(["os": .string("linux"), "arch": .string("arm64")]),
    // introspection keeps the plan on QEMU, as the Verify line asks for qemu-hvf.
    "require": .array([.string("serial"), .string("exec_ssh"), .string("introspection")]),
    "resources": .object(["cpus": .number(2), "memoryGB": .number(2), "diskGB": .number(8)]),
    "image": .string("debian-13-arm64"),
  ])

  /// R-903 Verify (integration): a fleet of three Debian guests on `qemu-hvf` is up with
  /// `fleet status` all `running` within 5 minutes, then destroyed with no directories left.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(10)))
  func threeDebianGuestsUpThenGone() async throws {
    let lab = try LabHome(tag: "f")
    let context = Self.context(lab)
    do {
      let started = ContinuousClock.now
      let created = try await Self.fleet(
        context,
        [
          "action": .string("create"), "name": .string("node"), "count": .number(3),
          "requirements": Self.requirements,
        ])
      #expect(created["plan"]?["profile"] == .string("qemu-hvf"))
      let status = try await Self.fleet(
        context, ["action": .string("status"), "name": .string("node")])
      let members = try #require(status["members"]?.arrayValue)
      #expect(members.count == 3)
      #expect(
        members.allSatisfy { $0["state"] == .string("running") && $0["error"] == nil },
        "\(members)")
      #expect(ContinuousClock.now - started < .seconds(300))

      let destroyed = try await Self.fleet(
        context, ["action": .string("destroy"), "name": .string("node")])
      #expect(destroyed["destroyed"]?.arrayValue?.count == 3)
      let vms =
        (try? FileManager.default.contentsOfDirectory(atPath: lab.store.vmsDirectory.path)) ?? []
      #expect(vms.isEmpty, "\(vms)")
      let segments =
        (try? FileManager.default.contentsOfDirectory(atPath: lab.segments.directory.path)) ?? []
      #expect(segments.isEmpty, "\(segments)")
      #expect(FleetStore(home: lab.home).list().isEmpty)
    } catch {
      await lab.shutdown()
      throw error
    }
    await lab.shutdown()
  }
}
