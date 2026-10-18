import Foundation
import Synchronization
import Testing

@testable import VMLabCore

/// Succeeds (or fails with `status`) and records every call; `convert` copies input to output.
final class RecordingRunner: CommandRunning {
  let status: Int32
  let calls = Mutex<[[String]]>([])

  init(status: Int32 = 0) { self.status = status }

  func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
    calls.withLock { $0.append([URL(filePath: executable).lastPathComponent] + arguments) }
    if arguments.first == "convert", status == 0 {
      try? FileManager.default.copyItem(
        at: URL(filePath: arguments[arguments.count - 2]),
        to: URL(filePath: arguments[arguments.count - 1]))
    }
    return CommandOutput(status: status, output: status == 0 ? "" : "boom")
  }
}

@Suite struct ImageRegistrationTests {
  static let qcow2Magic = Data([0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3])

  struct Sandbox {
    let root: URL
    let home: URL
    let bin: URL
    let runner: RecordingRunner
    let store: ImageStore

    init(tools: [String] = ["qemu-img", "tart"], status: Int32 = 0) throws {
      root = FileManager.default.temporaryDirectory.appending(path: "vmlab-register-\(UUID())")
      home = root.appending(path: "home")
      bin = root.appending(path: "bin")
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      for tool in tools {
        let url = bin.appending(path: tool)
        try TestScripts.install("#!/bin/sh\nexit 1\n", at: url)
      }
      runner = RecordingRunner(status: status)
      store = ImageStore(
        home: home, catalogue: try ImagesTests.catalogue(), runner: runner,
        searchPaths: [bin.path], now: { Date(timeIntervalSince1970: 1_800_000_000.7) })
    }

    func file(_ name: String, _ data: Data) throws -> URL {
      let url = root.appending(path: name)
      try data.write(to: url)
      return url
    }

    var calls: [[String]] { runner.calls.withLock { $0 } }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
  }

  @Test func detectsQcow2ByItsHeader() throws {
    let s = try Sandbox()
    defer { s.cleanUp() }
    #expect(ImageStore.detectFormat(of: try s.file("a.img", Self.qcow2Magic)) == .qcow2)
    #expect(ImageStore.detectFormat(of: try s.file("b.img", Data("raw!".utf8))) == .raw)
    #expect(ImageStore.detectFormat(of: try s.file("c.img", Data())) == .raw)
  }

  /// R-1002 Verify: the image.json of a registered raw arm64 disk, which also gains the qcow2
  /// QEMU overlays.
  @Test func rawArm64DiskRecordsImageJSON() async throws {
    let s = try Sandbox()
    defer { s.cleanUp() }
    let disk = try s.file("my.raw", Data(repeating: 7, count: 4096))
    let record = try await s.store.registerDisk(
      "mine", disk: disk, guest: GuestSpec(os: .linux, arch: .arm64))
    #expect(record.format == .raw)
    #expect(record.files == ["raw": "disk.raw", "qcow2": "disk.qcow2"])
    #expect(record.source == disk.resolvingSymlinksInPath().path)
    #expect(record.login == ImageLogin(user: "vmlab"))
    #expect(record.checksum?.algorithm == .sha256)
    #expect(record.checksum?.value == (try ChecksumAlgorithm.sha256.hexDigest(ofFileAt: disk)))
    #expect(s.calls.first?.prefix(5) == ["qemu-img", "convert", "-f", "raw", "-O"])
    #expect(s.calls.first?[5] == "qcow2")

    // image.json on disk is what pulled() and list() read back.
    let folder = s.store.imageDirectory("mine")
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "image.json")))
        as? [String: Any])
    #expect(json["schemaVersion"] as? Int == 1)
    #expect(json["format"] as? String == "raw")
    #expect((json["guest"] as? [String: String]) == ["os": "linux", "arch": "arm64"])
    #expect(json["pulledAt"] as? String == "2027-01-15T08:00:00Z")
    #expect(s.store.pulled("mine") == record)
    #expect(s.store.guest(of: "mine") == GuestSpec(os: .linux, arch: .arm64))
    #expect(s.store.list().contains { $0.name == "mine" && $0.pulled == record })
    #expect(try Data(contentsOf: folder.appending(path: "disk.raw")) == Data(contentsOf: disk))
  }

  @Test func qcow2DisksGainRawOnlyForArm64() async throws {
    let s = try Sandbox()
    defer { s.cleanUp() }
    let disk = try s.file("my.qcow2", Self.qcow2Magic)
    let arm = try await s.store.registerDisk(
      "arm", disk: disk, guest: GuestSpec(os: .linux, arch: .arm64), format: .qcow2)
    #expect(arm.files == ["qcow2": "disk.qcow2", "raw": "disk.raw"])
    let x86 = try await s.store.registerDisk(
      "x86", disk: disk, guest: GuestSpec(os: .linux, arch: .x86_64))
    #expect(x86.files == ["qcow2": "disk.qcow2"] && x86.format == .qcow2)
    #expect(s.calls.count == 1)
  }

  @Test func refusals() async throws {
    let s = try Sandbox()
    defer { s.cleanUp() }
    let raw = try s.file("my.raw", Data("raw".utf8))
    let linux = GuestSpec(os: .linux, arch: .arm64)
    func field(_ body: () async throws -> Void) async -> JSONValue? {
      do {
        try await body()
        return nil
      } catch let error as VMLabError {
        return error.data["field"]
      } catch { return .string("\(error)") }
    }
    #expect(
      await field {
        _ = try await s.store.registerDisk("m", disk: raw, guest: linux, format: .qcow2)
      }
        == .string("format"))
    #expect(
      await field {
        _ = try await s.store.registerDisk(
          "m", disk: raw, guest: GuestSpec(os: .macos, arch: .arm64))
      } == .string("guest"))
    #expect(
      await field { _ = try await s.store.registerDisk("tiny-arm64", disk: raw, guest: linux) }
        == .string("name"))
    #expect(
      await field {
        _ = try await s.store.registerDisk("m", disk: s.root.appending(path: "none"), guest: linux)
      } == .string("path"))
    #expect(
      await field { _ = try await s.store.registerDisk("a/b", disk: raw, guest: linux) }
        == .string("name"))
    _ = try await s.store.registerDisk("m", disk: raw, guest: linux)
    #expect(
      await field { _ = try await s.store.registerDisk("m", disk: raw, guest: linux) }
        == .string("name"))
    // A failed conversion leaves no directory behind.
    let failing = try Sandbox(status: 1)
    defer { failing.cleanUp() }
    await #expect(throws: VMLabError.self) {
      _ = try await failing.store.registerDisk(
        "m", disk: try failing.file("x.raw", Data("x".utf8)), guest: linux)
    }
    #expect(!FileManager.default.fileExists(atPath: failing.store.imageDirectory("m").path))
  }

  /// R-1002: `--ipsw` hands the installer to `tart create --from-ipsw` and records a Tart image.
  @Test func ipswHandsOffToTartCreate() async throws {
    let s = try Sandbox()
    defer { s.cleanUp() }
    let ipsw = try s.file("UniversalMac_26.0_Restore.ipsw", Data("ipsw".utf8))
    #expect(
      ImageStore.tartCreateArguments(ipsw: ipsw, vm: "vmlab-image-mac")
        == ["create", "--from-ipsw", ipsw.path, "vmlab-image-mac"])
    let record = try await s.store.registerIPSW("mac", ipsw: ipsw)
    #expect(
      s.calls == [
        ["tart", "create", "--from-ipsw", ipsw.resolvingSymlinksInPath().path, "vmlab-image-mac"]
      ])
    #expect(record.format == .tart && record.tartVM == "vmlab-image-mac")
    #expect(record.guest == GuestSpec(os: .macos, arch: .arm64))
    #expect(record.login == ImageLogin(user: "admin", password: "admin"))
    #expect(s.store.pulled("mac") == record)

    await #expect(throws: VMLabError.self) {
      _ = try await s.store.registerIPSW("other", ipsw: try s.file("disk.img", Data()))
    }
    let failing = try Sandbox(status: 1)
    defer { failing.cleanUp() }
    let failed = await #expect(throws: VMLabError.self) {
      _ = try await failing.store.registerIPSW("mac", ipsw: try failing.file("a.ipsw", Data()))
    }
    #expect(failed?.code == .engineError)
    #expect(failing.store.pulled("mac") == nil)
    let noTart = try Sandbox(tools: [])
    defer { noTart.cleanUp() }
    let missing = await #expect(throws: VMLabError.self) {
      _ = try await noTart.store.registerIPSW("mac", ipsw: try noTart.file("a.ipsw", Data()))
    }
    #expect(missing?.code == .hostMissingTool)
  }
}
