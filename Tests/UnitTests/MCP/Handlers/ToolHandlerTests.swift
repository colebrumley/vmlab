import Foundation
import Testing
import VMLabCore
import VMLabMCP

/// The shared handler layer: the registry, argument checks, and the five tools R-200 builds, run
/// against a temporary `VMLAB_HOME` and recorded host output.
@Suite struct ToolHandlerTests {
  /// A context on a fresh temporary home whose host facts come from the M1 Max fixtures.
  static func context() throws -> ToolContext {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-test-\(UUID())")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let runner = FixtureRunner(outputs: [
      "sw_vers": try HostProbeTests.fixture("host-probe/sw_vers.txt"),
      "sysctl machdep.cpu.brand_string hw.memsize": try HostProbeTests.fixture(
        "host-probe/sysctl.txt"),
      "vm_stat": try HostProbeTests.fixture("host-probe/vm_stat.txt"),
      "qemu-system-aarch64 --version": try HostProbeTests.fixture("host-probe/qemu-version.txt"),
      "qemu-system-aarch64 -accel help": try HostProbeTests.fixture(
        "host-probe/qemu-accel-help.txt"),
    ])
    let present: Set<String> = ["/opt/homebrew/bin/qemu-system-aarch64"]
    let probe = HostProbe(
      home: home, runner: runner, runnerPath: nil, searchPaths: ["/opt/homebrew/bin"],
      fileExists: { present.contains($0) }, isRoot: { false })
    return ToolContext(home: home, probe: probe)
  }

  static func call(_ name: String, _ arguments: JSONValue = .object([:]), in context: ToolContext)
    async throws(VMLabError) -> ToolResult
  {
    try await ToolHandlers.call(name, arguments: arguments, context: context)
  }

  static func refusal(
    _ name: String, _ arguments: JSONValue = .object([:]), in context: ToolContext
  ) async -> VMLabError? {
    do {
      _ = try await call(name, arguments, in: context)
      return nil
    } catch { return error }
  }

  static func record(_ name: String) -> VMRecord {
    VMRecord(
      id: "", name: name, profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [.execSSH, .serial], resources: ResourceSpec(cpus: 2, memoryGB: 4, diskGB: 32),
      image: "debian-13-arm64", network: NetworkSpec(mode: .nat),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000))
  }

  @Test func registryHoldsBuiltToolsInCatalogOrder() {
    #expect(
      ToolHandlers.specs.map(\.name) == [
        "host_facts", "host_doctor", "images", "vm_plan", "vm_create", "vm_list", "vm_inspect",
        "vm_lifecycle", "vm_exec", "vm_job", "vm_introspect", "vm_memory_dump", "vm_logs",
      ])
    for handler in ToolHandlers.all {
      #expect(ToolCatalog.spec(named: handler.spec.name) == handler.spec)
      #expect(ToolHandlers.handler(named: handler.spec.name) != nil)
    }
    #expect(ToolHandlers.handler(named: "vm_file") == nil)
  }

  @Test func argumentsAreCheckedAgainstTheSchema() async throws {
    let context = try Self.context()
    defer { try? FileManager.default.removeItem(at: context.home) }
    let unknownTool = await Self.refusal("no_such_tool", in: context)
    #expect(unknownTool?.code == .invalidRequest && unknownTool?.data["field"] == .string("name"))
    let unknownField = await Self.refusal("host_facts", .object(["x": .bool(true)]), in: context)
    #expect(unknownField?.code == .invalidRequest && unknownField?.data["field"] == .string("x"))
    let missing = await Self.refusal("vm_inspect", in: context)
    #expect(missing?.code == .invalidRequest && missing?.data["field"] == .string("vm"))
    let notObject = await Self.refusal("host_facts", .array([]), in: context)
    #expect(notObject?.data["field"] == .string("arguments"))
    let wrongType = await Self.refusal("host_doctor", .object(["probe": .string("y")]), in: context)
    #expect(wrongType?.data["field"] == .string("probe"))
    // A null argument list is no arguments.
    _ = try await Self.call("host_facts", .null, in: context)
  }

  @Test func hostFactsDecodesAsHostFacts() async throws {
    let context = try Self.context()
    defer { try? FileManager.default.removeItem(at: context.home) }
    let result = try await Self.call("host_facts", in: context)
    let facts = try JSONDecoder().decode(HostFacts.self, from: result.value.data)
    #expect(facts.osVersion == "26.6.2")
    #expect(facts.qemu.accelerators == ["hvf", "tcg"])
    #expect(result.warnings.isEmpty)
    #expect(result.value["warnings"] == .array([]))
    // The MCP text is the same object as compact JSON.
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8)) == result.value)
  }

  @Test func doctorReportsEachPrerequisiteWithItsFix() async throws {
    let context = try Self.context()
    defer { try? FileManager.default.removeItem(at: context.home) }
    let result = try await Self.call("host_doctor", .object(["probe": .bool(true)]), in: context)
    let checks = result.value["checks"]?.arrayValue ?? []
    let byName = Dictionary(
      uniqueKeysWithValues: checks.map { ($0["check"]?.stringValue ?? "", $0) })
    #expect(
      Set(byName.keys) == ["qemu", "qemu_hvf", "tart", "rosetta", "runner_entitlement"])
    #expect(byName["qemu"]?["status"] == .string("ok") && byName["qemu"]?["fix"] == nil)
    #expect(byName["tart"]?["fix"] == .string("brew install cirruslabs/cli/tart"))
    #expect(byName["rosetta"]?["status"] == .string("missing"))
    #expect(result.value["probes"]?.objectValue?.count == SlowProbe.allCases.count)
    #expect(byName["runner_entitlement"]?["status"] == .string("missing"))
    #expect(result.warnings.contains { $0.contains("not built yet") })
  }

  @Test func planReturnsAPlan() async throws {
    let context = try Self.context()
    defer { try? FileManager.default.removeItem(at: context.home) }
    let requirements: JSONValue = .object([
      "guest": .object(["os": .string("linux"), "arch": .string("arm64")]),
      "require": .array([.string("serial"), .string("gdb")]),
    ])
    let result = try await Self.call(
      "vm_plan", .object(["requirements": requirements, "allowUnverified": .bool(true)]),
      in: context)
    #expect(result.value["satisfiable"] == .bool(true))
    let plan = try JSONDecoder().decode(Plan.self, from: result.value.data)
    #expect(plan.profile == .qemuHVF)
    #expect(plan.grants(.serial) && plan.grants(.gdb))
  }

  @Test func impossiblePlanIsAResultWithSuggestions() async throws {
    let context = try Self.context()
    defer { try? FileManager.default.removeItem(at: context.home) }
    let requirements: JSONValue = .object([
      "guest": .object(["os": .string("linux"), "arch": .string("arm64")]),
      "require": .array([.string("rosetta"), .string("gdb")]),
    ])
    let result = try await Self.call(
      "vm_plan", .object(["requirements": requirements]), in: context)
    #expect(result.value["satisfiable"] == .bool(false))
    #expect(result.value["code"] == .string("unsatisfiable"))
    #expect(result.value["eliminated"]?["rosetta"]?.arrayValue?.isEmpty == false)
    #expect(result.value["suggestions"]?.arrayValue?.isEmpty == false)
  }

  @Test func malformedRequirementsAreInvalidRequest() async throws {
    let context = try Self.context()
    defer { try? FileManager.default.removeItem(at: context.home) }
    let error = await Self.refusal(
      "vm_plan",
      .object([
        "requirements": .object([
          "guest": .object(["os": .string("linux"), "arch": .string("arm64")]),
          "require": .array([.string("bogus")]),
        ])
      ]), in: context)
    #expect(error?.code == .invalidRequest)
  }

  @Test func listAndInspectReadTheStore() async throws {
    let context = try Self.context()
    defer { try? FileManager.default.removeItem(at: context.home) }
    var record = try context.store.create(Self.record("web"))
    record.state = .running
    record.runtime = VMRuntime(
      pid: 1, controlSocket: "/tmp/c.sock", serialSocket: "/tmp/s.sock", sshPort: 2222,
      ip: "192.168.64.5")
    try context.store.save(record)
    _ = try context.store.create(Self.record("db"))
    let log = EventLog(vmDirectory: context.store.directory(of: record.id))
    for index in 0..<25 { try await log.append(.lifecycle, "event \(index)") }

    let all = try await Self.call("vm_list", in: context)
    let names = all.value["vms"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    #expect(Set(names) == ["web", "db"] && names.count == 2)
    let running = try await Self.call(
      "vm_list", .object(["state": .string("running")]), in: context)
    let row = running.value["vms"]?.arrayValue?.first
    #expect(running.value["vms"]?.arrayValue?.count == 1)
    #expect(row?["sshPort"] == .number(2222) && row?["ip"] == .string("192.168.64.5"))
    #expect(row?["guest"]?["os"] == .string("linux"))
    let badState = await Self.refusal("vm_list", .object(["state": .string("x")]), in: context)
    #expect(badState?.code == .invalidRequest)

    let inspect = try await Self.call("vm_inspect", .object(["vm": .string("web")]), in: context)
    #expect(inspect.value["vm"]?["id"] == .string(record.id))
    #expect(
      try JSONDecoder.iso.decode(VMRecord.self, from: inspect.value["record"]!.data) == record)
    let events = inspect.value["events"]?.arrayValue ?? []
    #expect(events.count == 20)
    #expect(events.last?["message"] == .string("event 24"))
    #expect(inspect.value["endpoints"]?["ssh"] == .string("127.0.0.1:2222"))
    #expect(inspect.value["endpoints"]?["serial"] == .string("/tmp/s.sock"))
    #expect(inspect.value["features"] == .array([.string("exec_ssh"), .string("serial")]))
    #expect(inspect.value["panic"] == .null)

    let missing = await Self.refusal("vm_inspect", .object(["vm": .string("nope")]), in: context)
    #expect(missing?.code == .vmNotFound)
  }

  @Test func logsListPanicsAndInspectSurfacesTheLatest() async throws {
    let context = try Self.context()
    defer { try? FileManager.default.removeItem(at: context.home) }
    let record = try context.store.create(Self.record("web"))
    let directory = context.store.directory(of: record.id)
    let log = EventLog(vmDirectory: directory)
    try await log.append(.lifecycle, "started")
    let detector = PanicDetector(log: log)
    detector.observe(
      SerialLine(
        text: "[ 2.5] Kernel panic - not syncing: Attempted to kill init!", start: 812, end: 870))
    await detector.finish()
    try await log.append(.lifecycle, "stopped")
    try Data("login: root\r\nPassword:\nKernel panic - not syncing: Attempted to kill init!\n".utf8)
      .write(to: directory.appending(path: "serial.log"))

    let inspect = try await Self.call("vm_inspect", .object(["vm": .string("web")]), in: context)
    #expect(inspect.value["panic"]?["kind"] == .string("panic"))
    #expect(inspect.value["panic"]?["data"]?["offset"] == .number(812))

    let events = try await Self.call(
      "vm_logs", .object(["vm": .string("web"), "source": .string("events")]), in: context)
    let lines = events.value["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(lines.count == 3)
    #expect(lines[1].contains("critical panic: [ 2.5] Kernel panic - not syncing"))
    #expect(lines[1].contains("\"offset\":812"))

    let serial = try await Self.call(
      "vm_logs", .object(["vm": .string("web"), "source": .string("serial"), "tail": .number(2)]),
      in: context)
    #expect(
      serial.value["lines"]
        == .array([
          .string("Password:"), .string("Kernel panic - not syncing: Attempted to kill init!"),
        ]))

    let all = try await Self.call("vm_logs", .object(["vm": .string("web")]), in: context)
    let allLines = all.value["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(allLines.count == 6)
    #expect(allLines.first?.hasPrefix("[events] ") == true)
    #expect(allLines.last == "[serial] Kernel panic - not syncing: Attempted to kill init!")

    let badTail = await Self.refusal(
      "vm_logs", .object(["vm": .string("web"), "tail": .number(0)]), in: context)
    #expect(badTail?.code == .invalidRequest)
    let missing = await Self.refusal("vm_logs", .object(["vm": .string("nope")]), in: context)
    #expect(missing?.code == .vmNotFound)
  }

  @Test func refusalsRenderAsAppendixDObjects() throws {
    let error = VMLabError(
      code: .vmNotFound, message: "No VM nope", hint: "Call vm_list.", data: ["vm": .string("nope")]
    )
    let object = try JSONDecoder().decode(
      JSONValue.self, from: Data(ToolRendering.json(error).utf8))
    #expect(object["code"] == .string("vm_not_found"))
    #expect(object["data"]?["vm"] == .string("nope"))
    #expect(ToolRendering.text(error) == "error[vm_not_found]: No VM nope\nhint: Call vm_list.")
  }
}

extension JSONDecoder {
  static var iso: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
