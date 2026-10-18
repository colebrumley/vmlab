import Foundation
import Synchronization
import Testing
import VMLabCore

@testable import VMLabVZ

/// Stands in for `tart`: `clone <src> <name>` makes `<home>/vms/<name>/` from the fixture
/// `config.json` plus empty `disk.img` and `nvram.bin`; `delete <name>` removes it.
final class FakeTart: CommandRunning {
  let home: URL
  let config: URL
  let calls = Mutex<[[String]]>([])

  init(home: URL, config: URL = TartTests.fixture) {
    self.home = home
    self.config = config
  }

  func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
    calls.withLock { $0.append(arguments) }
    let fm = FileManager.default
    switch arguments.first {
    case "clone" where arguments.count == 3:
      let dir = home.appending(path: "vms").appending(path: arguments[2])
      do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.copyItem(at: config, to: dir.appending(path: "config.json"))
        try Data().write(to: dir.appending(path: "disk.img"))
        try Data().write(to: dir.appending(path: "nvram.bin"))
      } catch { return CommandOutput(status: 1, output: "\(error)") }
      return CommandOutput(status: 0, output: "")
    case "delete" where arguments.count == 2:
      try? fm.removeItem(at: home.appending(path: "vms").appending(path: arguments[1]))
      return CommandOutput(status: 0, output: "")
    default:
      return CommandOutput(status: 1, output: "unexpected")
    }
  }
}

@Suite struct TartTests {
  static let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")
  /// The `config.json` of `ghcr.io/cirruslabs/macos-tahoe-base:latest` under Tart 2.32.1.
  static let fixture = fixtures.appending(path: "tart/config.json")

  static func temporary() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "vmlab-tart-\(UUID())")
  }

  @Test func parsesTheFixtureConfig() throws {
    let config = try TartVMConfig.read(from: Self.fixture.deletingLastPathComponent())
    #expect(config.version == 1)
    #expect(config.os == "darwin" && config.arch == "arm64")
    #expect(config.cpuCountMin == 2 && config.cpuCount == 4)
    #expect(config.memorySizeMin == 4 << 30 && config.memorySize == 8 << 30)
    #expect(config.macAddress == "72:76:f4:5e:d8:14")
    #expect(config.display == .init(width: 1024, height: 768))
    #expect(config.diskFormat == "raw")
    #expect(config.hardwareModel.flatMap { Data(base64Encoded: $0) } != nil)
    #expect(config.ecid.flatMap { Data(base64Encoded: $0) } != nil)
  }

  @Test func refusesAnUnreadableLayout() throws {
    let dir = Self.temporary()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let missing = #expect(throws: VMLabError.self) { try TartVMConfig.read(from: dir) }
    #expect(missing?.code == .engineError)
    #expect(missing?.data["engine"] == .string("tart"))

    var object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as? [String: Any])
    for (key, value) in [("version", 2 as Any), ("os", "linux"), ("ecid", NSNull())] {
      var broken = object
      broken[key] = value is NSNull ? nil : value
      try JSONSerialization.data(withJSONObject: broken).write(
        to: dir.appending(path: "config.json"))
      let error = #expect(throws: VMLabError.self) { try TartVMConfig.read(from: dir) }
      #expect(error?.code == .engineError, "\(key)")
    }
    object["macAddress"] = "not-a-mac"
    try JSONSerialization.data(withJSONObject: object).write(to: dir.appending(path: "config.json"))
    #expect(throws: VMLabError.self) { try TartVMConfig.read(from: dir) }
  }

  @Test func homeHonoursTartHome() {
    #expect(Tart.defaultHome(environment: ["TART_HOME": "/tmp/t"]).path == "/tmp/t")
    #expect(Tart.defaultHome(environment: [:]).lastPathComponent == ".tart")
  }

  @Test func locateFailsWithTheInstallHint() {
    let error = #expect(throws: VMLabError.self) { try Tart.locate(searchPaths: []) }
    #expect(error?.code == .hostMissingTool)
    #expect(error?.data["tool"] == .string("tart"))
  }

  @Test func cloneAndDeleteRunTart() throws {
    let home = Self.temporary()
    defer { try? FileManager.default.removeItem(at: home) }
    let fake = FakeTart(home: home)
    let tart = Tart(executable: "/opt/homebrew/bin/tart", home: home, commands: fake)
    let clone = try tart.clone("ghcr.io/x/y:latest", to: "vm-abc123")
    #expect(clone.directory == home.appending(path: "vms/vm-abc123"))
    #expect(FileManager.default.fileExists(atPath: clone.nvram.path))
    try tart.delete("vm-abc123")
    try tart.delete("vm-abc123")  // already gone: no second call
    #expect(
      fake.calls.withLock { $0 } == [
        ["clone", "ghcr.io/x/y:latest", "vm-abc123"], ["delete", "vm-abc123"],
      ])
  }

  @Test func failedCloneIsEngineError() {
    struct Failing: CommandRunning {
      func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
        CommandOutput(status: 1, output: "no space left\n")
      }
    }
    let tart = Tart(executable: "/bin/false", home: Self.temporary(), commands: Failing())
    let error = #expect(throws: VMLabError.self) { try tart.clone("a", to: "b") }
    #expect(error?.code == .engineError)
    #expect(error?.data["raw"] == .string("no space left"))
  }
}
