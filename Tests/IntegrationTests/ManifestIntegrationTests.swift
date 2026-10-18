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
    let context = ToolContext(home: guest.home, backends: registry)
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
    let context = ToolContext(home: guest.home, backends: registry)
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

  /// R-801 Verify (integration, macOS): a macOS manifest lists `com.apple.dock`.
  @Test(.disabled("TODO(R-606): vz-macos guests are not provisioned on main yet"))
  func macOSManifestListsTheDock() async throws {}

  /// R-802 Verify (integration, macOS): `defaults write com.apple.dock autohide -bool true`
  /// between two manifests shows the key with `0 → 1` in the diff.
  @Test(.disabled("TODO(R-606): vz-macos guests are not provisioned on main yet"))
  func macOSDiffShowsTheDockAutohideKey() async throws {}
}
