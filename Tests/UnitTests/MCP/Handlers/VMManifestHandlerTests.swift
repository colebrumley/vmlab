import Foundation
import Synchronization
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_manifest` against the fake backend, with an exec channel that prints a fixture output.
@Suite struct VMManifestHandlerTests {
  typealias Fixture = VMCreateHandlerTests.Fixture

  /// Prints `output` for every command and records the commands.
  final class ScriptedExec: ExecChannel {
    let output: String
    let commands = Mutex<[String]>([])
    init(_ output: String) { self.output = output }
    func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult {
      commands.withLock { $0.append(request.command) }
      return ExecResult(exitCode: 0, stdout: output, stderr: "")
    }
  }

  /// `FakeBackend` whose running VMs run commands through `exec`.
  struct ScriptedBackend: Backend {
    let base: FakeBackend
    let exec: any ExecChannel
    var profile: Profile { base.profile }
    func create(_ record: VMRecord, plan: Plan) async throws(VMLabError) {
      try await base.create(record, plan: plan)
    }
    func start(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
      try await base.start(record)
    }
    func stop(_ record: VMRecord) async throws(VMLabError) { try await base.stop(record) }
    func kill(_ record: VMRecord) async throws(VMLabError) { try await base.kill(record) }
    func pause(_ record: VMRecord) async throws(VMLabError) { try await base.pause(record) }
    func resume(_ record: VMRecord) async throws(VMLabError) { try await base.resume(record) }
    func destroy(_ record: VMRecord) async throws(VMLabError) { try await base.destroy(record) }
    func attach(_ record: VMRecord) async throws(VMLabError) -> any RunningVM {
      guard var vm = try await base.attach(record) as? FakeRunningVM else {
        throw VMLabError(code: .internal, message: "not a fake VM", hint: "")
      }
      vm.exec = exec
      return vm
    }
  }

  static func manifest(_ arguments: [String: JSONValue], in f: Fixture) async throws(VMLabError)
    -> ToolResult
  {
    var arguments = arguments
    arguments["vm"] = arguments["vm"] ?? .string("web")
    return try await ToolHandlers.call(
      "vm_manifest", arguments: .object(arguments), context: f.context)
  }

  static func scripted(_ output: String, in f: Fixture) -> ScriptedExec {
    let exec = ScriptedExec(output)
    f.context.backends.register(ScriptedBackend(base: f.backend, exec: exec))
    return exec
  }

  @Test func takesAndStoresALinuxManifest() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let exec = Self.scripted(ManifestTests.linuxOutput, in: f)
    let result = try await Self.manifest(["paths": .array([.string("/srv/data")])], in: f)
    let id = try #require(result.value["id"]?.stringValue)
    #expect(GuestManifest.isValidID(id))
    #expect(result.value["profile"] == .string("linux"))
    #expect(result.value["counts"]?["files"] == .number(6))
    #expect(result.value["counts"]?["packages"] == .number(3))
    #expect(result.value["counts"]?["users"] == .number(2))
    #expect(result.value["vm"]?["name"] == .string("web"))
    #expect(result.warnings.contains("/srv/data does not exist in the guest"))
    let path = try #require(result.value["path"]?.stringValue)
    #expect(FileManager.default.fileExists(atPath: path))
    let record = try f.context.store.find("web")
    let stored = try f.context.store.loadManifest(vm: record.id, id: id)
    #expect(stored.files["/etc/hostname"]?.size == 7)
    #expect(stored.roots == ["/srv/data"])
    let command = try #require(exec.commands.withLock { $0.first })
    #expect(command.hasSuffix(#"vmlab-manifest 'linux' '/srv/data'"#))
    #expect(f.progress.messages.contains { $0.contains("manifest") })
  }

  @Test func profileOverridesTheGuestOS() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let exec = Self.scripted(ManifestTests.macOutput, in: f)
    let result = try await Self.manifest(["profile": .string("macos")], in: f)
    #expect(result.value["counts"]?["defaults"] == .number(8))
    #expect(exec.commands.withLock { $0.first?.hasSuffix("'macos'") } == true)
  }

  @Test func anUnfinishedScriptIsEngineError() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    _ = Self.scripted("@@vmlab manifest 1 Linux\n@@vmlab section files\n", in: f)
    let error = await #expect(throws: VMLabError.self) { try await Self.manifest([:], in: f) }
    #expect(error?.code == .engineError)
  }

  @Test func theEchoedScriptIsNotAFinishedManifest() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    // FakeExec echoes the command, which contains the end marker inside the script text.
    let error = await #expect(throws: VMLabError.self) { try await Self.manifest([:], in: f) }
    #expect(error?.code == .engineError)
  }

  @Test func aStoppedVMIsWrongState() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["autostart": .bool(false)])
    let error = await #expect(throws: VMLabError.self) { try await Self.manifest([:], in: f) }
    #expect(error?.code == .wrongState)
    #expect(error?.data["state"] == .string("created"))
  }

  @Test func malformedFieldsAreInvalidRequest() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let cases: [([String: JSONValue], String)] = [
      (["profile": .string("windows")], "profile"),
      (["profile": .string("custom")], "paths"),
      (["paths": .string("/etc")], "paths"),
      (["paths": .array([.number(1)])], "paths"),
      (["paths": .array([.string("relative")])], "paths"),
    ]
    for (arguments, field) in cases {
      let error = await #expect(throws: VMLabError.self) {
        try await Self.manifest(arguments, in: f)
      }
      #expect(error?.code == .invalidRequest, "\(arguments)")
      #expect(error?.data["field"] == .string(field), "\(arguments)")
    }
  }

  @Test func anUnknownVMIsNotFound() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let error = await #expect(throws: VMLabError.self) {
      try await Self.manifest(["vm": .string("nope")], in: f)
    }
    #expect(error?.code == .vmNotFound)
  }
}
