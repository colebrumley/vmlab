import CryptoKit
import Foundation
import Testing
import VMLabCore
import VMLabMCP
import VMLabQEMU

@Suite struct ManifestIntegrationTests {
  static let features: [Feature] = [.serial, .execSSH, .netNAT]

  static func call(
    _ tool: String, _ arguments: [String: JSONValue], guest: QEMUGuest, context: ToolContext
  ) async throws(VMLabError) -> JSONValue {
    var arguments = arguments
    arguments["vm"] = .string(guest.record.id)
    return try await ToolHandlers.call(tool, arguments: .object(arguments), context: context)
      .value
  }

  /// R-801 Verify (integration): a Debian manifest lists `/etc/hostname` with the hash of what
  /// the guest's file holds, plus dpkg packages, enabled units and users.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(6)))
  func debianManifestHashesEtcHostname() async throws {
    let guest = try await QEMUGuest.boot(features: Self.features)
    let registry = BackendRegistry()
    registry.register(guest.backend)
    let context = ToolContext(
      home: guest.home, backends: registry, startGate: IntegrationAdmission.gate)
    do {
      let hostname = try await Self.call(
        "vm_exec", ["command": .string("cat /etc/hostname")], guest: guest, context: context)
      let text = try #require(hostname["stdout"]?.stringValue)
      let expected = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }
        .joined()
      let result = try await Self.call(
        "vm_manifest", ["paths": .array([.string("/home")])], guest: guest, context: context)
      let id = try #require(result["id"]?.stringValue)
      let manifest = try context.store.loadManifest(vm: guest.record.id, id: id)
      #expect(manifest.profile == .linux)
      #expect(manifest.files["/etc/hostname"]?.sha256 == expected, "\(result)")
      #expect(manifest.files["/etc/hostname"]?.kind == .file)
      // sudo -n works for the cloud-init user, so root-only files are hashed too.
      #expect(manifest.files["/etc/shadow"]?.sha256 != nil)
      #expect(manifest.files["/home/debian"]?.kind == .directory)
      #expect(manifest.packages["openssh-server"] != nil)
      #expect(manifest.services.keys.contains { $0.hasPrefix("ssh") })
      #expect(manifest.users["root"]?.hasPrefix("uid=0 ") == true)
      #expect(result["counts"]?["files"]?.numberValue ?? 0 > 100)
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// R-802 on Debian (the Verify line's guest is macOS, below): a file written and a package
  /// removed between a manifest and `@now` show in the diff; /etc/hostname does not.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(6)))
  func debianDiffAgainstNow() async throws {
    let guest = try await QEMUGuest.boot(features: Self.features)
    let registry = BackendRegistry()
    registry.register(guest.backend)
    let context = ToolContext(
      home: guest.home, backends: registry, startGate: IntegrationAdmission.gate)
    do {
      let base = try await Self.call("vm_manifest", [:], guest: guest, context: context)
      let id = try #require(base["id"]?.stringValue)
      let change = try await Self.call(
        "vm_exec",
        [
          "command": .string(
            "echo changed | sudo tee /etc/vmlab-diff >/dev/null && sudo chmod 600 /etc/motd")
        ], guest: guest, context: context)
      #expect(change["exitCode"] == .number(0), "\(change)")
      let diff = try await Self.call(
        "vm_checkpoint", ["action": .string("diff"), "from": .string(id), "to": .string("@now")],
        guest: guest, context: context)
      let files = diff["files"]?["entries"]?.arrayValue ?? []
      let byPath = Dictionary(
        files.compactMap { e in e["path"]?.stringValue.map { ($0, e) } },
        uniquingKeysWith: { a, _ in a })
      #expect(byPath["/etc/vmlab-diff"]?["change"] == .string("added"), "\(diff)")
      #expect(byPath["/etc/motd"]?["changes"]?["mode"]?["new"] == .string("0600"), "\(diff)")
      #expect(byPath["/etc/hostname"] == nil)
      #expect(diff["packages"]?["entries"]?.arrayValue?.isEmpty == true)
      let path = try #require(diff["path"]?.stringValue)
      #expect(FileManager.default.fileExists(atPath: path))
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// Calls `tool` on a macOS guest.
  static func call(
    _ tool: String, _ arguments: [String: JSONValue], mac: VZMacGuestIntegrationTests.Guest,
    context: ToolContext
  ) async throws(VMLabError) -> JSONValue {
    var arguments = arguments
    arguments["vm"] = .string(mac.record.id)
    return try await ToolHandlers.call(tool, arguments: .object(arguments), context: context)
      .value
  }

  /// R-801 Verify (integration, macOS): a macOS manifest lists `com.apple.dock`; and R-802 Verify:
  /// `defaults write com.apple.dock autohide -bool true` between two manifests shows the key with
  /// `0 → 1` in the diff. One guest for both (the host runs at most two macOS guests). The key is
  /// written `false` first so the base manifest holds `0` (the image leaves it unset).
  @Test(
    .enabled(if: VZMacGuestIntegrationTests.ready && VZMacGuestIntegrationTests.hostHasRoom()),
    .timeLimit(.minutes(12)))
  func macOSManifestListsTheDockAndDiffShowsAutohide() async throws {
    let mac = try await VZMacGuestIntegrationTests.makeGuest(features: [.execSSH], suffix: "f")
    do {
      _ = try await mac.manager.performAdmitted(.start, on: mac.record.id)
      let context = ToolContext(
        home: mac.home, backends: mac.registry, startGate: IntegrationAdmission.gate)
      let reset = try await Self.call(
        "vm_exec", ["command": .string("defaults write com.apple.dock autohide -bool false")],
        mac: mac, context: context)
      #expect(reset["exitCode"] == .number(0), "\(reset)")

      let base = try await Self.call("vm_manifest", [:], mac: mac, context: context)
      let id = try #require(base["id"]?.stringValue, "\(base)")
      let manifest = try context.store.loadManifest(vm: mac.record.id, id: id)
      #expect(manifest.profile == .macos)
      #expect(manifest.defaults["com.apple.dock"] != nil, "\(manifest.defaults.keys.sorted())")
      #expect(manifest.defaults["com.apple.dock"]?["autohide"] == "0")

      let change = try await Self.call(
        "vm_exec", ["command": .string("defaults write com.apple.dock autohide -bool true")],
        mac: mac, context: context)
      #expect(change["exitCode"] == .number(0), "\(change)")
      let after = try await Self.call("vm_manifest", [:], mac: mac, context: context)
      let afterID = try #require(after["id"]?.stringValue)
      let diff = try await Self.call(
        "vm_checkpoint",
        ["action": .string("diff"), "from": .string(id), "to": .string(afterID)], mac: mac,
        context: context)
      let entries = diff["defaults"]?["entries"]?.arrayValue ?? []
      let autohide = entries.first {
        $0["domain"] == .string("com.apple.dock") && $0["key"] == .string("autohide")
      }
      #expect(autohide?["old"] == .string("0"), "\(diff)")
      #expect(autohide?["new"] == .string("1"), "\(diff)")
      #expect(autohide?["change"] == .string("changed"))
    } catch {
      await mac.teardown()
      throw error
    }
    await mac.teardown()
  }
}
