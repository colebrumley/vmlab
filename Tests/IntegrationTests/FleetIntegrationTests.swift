import Foundation
import Testing
import VMLabCore
import VMLabMCP

@Suite(.serialized) struct FleetIntegrationTests {
  /// A tool context over a `LabHome`: its backends and its manager (whose switch is the built one).
  static func context(_ lab: LabHome) -> ToolContext {
    var context = ToolContext(
      home: lab.home, backends: lab.registry, startGate: IntegrationAdmission.gate)
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

      // R-904 Verify (integration): `fleet exec "hostname"` returns each member's name.
      let exec = try await Self.fleet(
        context,
        ["action": .string("exec"), "name": .string("node"), "command": .string("hostname")])
      #expect(exec["allSucceeded"] == .bool(true), "\(exec)")
      for member in ["node-1", "node-2", "node-3"] {
        #expect(exec["results"]?[member]?["stdout"] == .string(member + "\n"), "\(exec)")
      }

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

extension FleetIntegrationTests {
  /// The fleet requirements per engine: introspection keeps QEMU, serial alone lands on VZ.
  static func reachRequirements(_ profile: Profile) -> JSONValue {
    .object([
      "guest": .object(["os": .string("linux"), "arch": .string("arm64")]),
      "require": .array(
        (profile == .qemuHVF ? ["serial", "exec_ssh", "introspection"] : ["serial", "exec_ssh"])
          .map(JSONValue.string)),
      "resources": .object(["cpus": .number(2), "memoryGB": .number(2), "diskGB": .number(8)]),
      "network": .object(["forwards": .array([.object(["guest": .number(8000)])])]),
      "image": .string("debian-13-arm64"),
    ])
  }

  /// A GET from the host; the body, or nil.
  static func fetch(_ address: String) async -> String? {
    guard let url = URL(string: "http://\(address)/") else { return nil }
    for _ in 0..<10 {
      if let (data, response) = try? await URLSession.shared.data(from: url),
        (response as? HTTPURLResponse)?.statusCode == 200
      {
        return String(decoding: data, as: UTF8.self)
      }
      try? await Task.sleep(for: .seconds(1))
    }
    return nil
  }

  /// R-905 Verify (integration), on both engines: a fleet of three, `python3 -m http.server` on
  /// node-1, fetched from node-2 by name over the segment and from the host at the address the
  /// fleet reports (a loopback port on QEMU, the guest's NAT address on VZ).
  @Test(
    .enabled(if: integrationEnabled), .timeLimit(.minutes(10)),
    arguments: [Profile.qemuHVF, Profile.vzLinux])
  func httpServerReachableByNameAndFromTheHost(profile: Profile) async throws {
    guard profile == .qemuHVF || VZRunnerIntegrationTests.ready else { return }
    let lab = try LabHome(tag: profile == .qemuHVF ? "r" : "z")
    let context = Self.context(lab)
    do {
      let created = try await Self.fleet(
        context,
        [
          "action": .string("create"), "name": .string("web"), "count": .number(3),
          "requirements": Self.reachRequirements(profile),
        ])
      #expect(created["plan"]?["profile"] == .string(profile.rawValue))
      let members = try #require(created["members"]?.arrayValue)
      #expect(members.allSatisfy { $0["state"] == .string("running") }, "\(members)")

      let serve = try await Self.fleet(
        context,
        [
          "action": .string("exec"), "name": .string("web"), "members": .array([.string("web-1")]),
          "command": .string(
            "mkdir -p /tmp/www && echo hello-from-web-1 > /tmp/www/index.html && cd /tmp/www && "
              + "(setsid nohup python3 -m http.server 8000 </dev/null >/dev/null 2>&1 &) && sleep 1"
          ),
        ])
      #expect(serve["allSucceeded"] == .bool(true), "\(serve)")

      let byName = try await Self.fleet(
        context,
        [
          "action": .string("exec"), "name": .string("web"), "members": .array([.string("web-2")]),
          "command": .string(
            "for i in 1 2 3 4 5; do curl -sf http://web-1.web:8000/ && exit 0 || "
              + "python3 -c \"import urllib.request as u; "
              + "print(u.urlopen('http://web-1.web:8000/').read().decode(), end='')\" && exit 0; "
              + "sleep 1; done; exit 1"),
        ])
      #expect(
        byName["results"]?["web-2"]?["stdout"] == .string("hello-from-web-1\n"), "\(byName)")

      let status = try await Self.fleet(
        context, ["action": .string("status"), "name": .string("web")])
      let first = try #require(
        status["members"]?.arrayValue?.first { $0["vm"] == .string("web-1") })
      let address = try #require(
        first["forwards"]?.arrayValue?.first?["hostReachable"]?.stringValue, "\(first)")
      if profile == .vzLinux {
        #expect(first["forwards"]?.arrayValue?.first?["host"] == .null)
        #expect(address.hasSuffix(":8000") && !address.hasPrefix("127."), "\(address)")
      } else {
        #expect(address.hasPrefix("127.0.0.1:"), "\(address)")
      }
      #expect(await Self.fetch(address) == "hello-from-web-1\n", "from the host at \(address)")

      _ = try await Self.fleet(context, ["action": .string("destroy"), "name": .string("web")])
    } catch {
      await lab.shutdown()
      throw error
    }
    await lab.shutdown()
  }
}
