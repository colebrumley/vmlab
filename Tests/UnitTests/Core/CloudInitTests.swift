import Foundation
import Testing

@testable import VMLabCore

/// Parses YAML with the system Ruby's Psych into JSON, so the test checks validity with a real
/// parser without vmlab depending on one (constraint C5). Tests skip when Ruby is absent.
enum RubyYAML {
  static let ruby = "/usr/bin/ruby"
  static var available: Bool { FileManager.default.isExecutableFile(atPath: ruby) }

  static func parse(_ text: String) throws -> Any {
    let file = FileManager.default.temporaryDirectory.appending(path: "vmlab-yaml-\(UUID()).yaml")
    try Data(text.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let script =
      "require 'yaml'; require 'json'; "
      + "puts JSON.generate([YAML.safe_load(File.read(ARGV[0]), permitted_classes: [], aliases: false)])"
    let result = try #require(ProcessRunner().run(ruby, ["-e", script, file.path]))
    #expect(result.status == 0, "YAML did not parse: \(result.output)")
    let array = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [Any]
    return try #require(array?.first)
  }
}

@Suite struct CloudInitTests {
  static let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample vmlab@host"

  static func base() -> CloudInitConfig {
    CloudInitConfig(
      instanceID: "vm-0001", hostname: "dev1", user: "debian", sshPublicKey: key)
  }

  @Test(.enabled(if: RubyYAML.available)) func userDataIsValidYAMLWithExpectedKeys() throws {
    let text = try CloudInit.userData(Self.base())
    #expect(text.hasPrefix("#cloud-config\n"))
    let doc = try #require(try RubyYAML.parse(text) as? [String: Any])
    #expect(doc["hostname"] as? String == "dev1")
    #expect(doc["ssh_pwauth"] as? Bool == false)
    let users = try #require(doc["users"] as? [[String: Any]])
    #expect(users.count == 1)
    #expect(users[0]["name"] as? String == "debian")
    #expect(users[0]["lock_passwd"] as? Bool == true)
    #expect(users[0]["ssh_authorized_keys"] as? [String] == [Self.key])
    #expect(doc["packages"] as? [String] == ["qemu-guest-agent"])
    let runcmd = try #require(doc["runcmd"] as? [[String]])
    #expect(runcmd.contains(["systemctl", "enable", "--now", "qemu-guest-agent"]))
    #expect(runcmd.contains(["systemctl", "enable", "--now", "serial-getty@ttyAMA0.service"]))
    #expect(doc["bootcmd"] == nil)
    #expect(doc["mounts"] == nil)
    #expect(doc["write_files"] == nil)
    #expect(CloudInit.networkConfig(Self.base()) == nil)
  }

  @Test(.enabled(if: RubyYAML.available)) func metaDataCarriesInstanceAndHostname() throws {
    let doc = try #require(try RubyYAML.parse(CloudInit.metaData(Self.base())) as? [String: String])
    #expect(doc == ["instance-id": "vm-0001", "local-hostname": "dev1"])
  }

  @Test(.enabled(if: RubyYAML.available)) func optionalPartsAppear() throws {
    var config = Self.base()
    config.packages = ["build-essential", "qemu-guest-agent"]
    config.gui = GUIStack(vncPassword: "s3cret\"x")
    config.console = .hvc0
    config.mounts = [
      GuestMount(tag: "share0", guestPath: "/mnt/share", kind: .ninep),
      GuestMount(tag: "share1", guestPath: "/mnt/ro", kind: .virtiofs, readOnly: true),
    ]
    let doc = try #require(try RubyYAML.parse(CloudInit.userData(config)) as? [String: Any])
    #expect(
      doc["packages"] as? [String] == ["qemu-guest-agent"] + GUIStack.desktopPackages + [
        "x11vnc", "build-essential",
      ])
    #expect(
      doc["mounts"] as? [[String]] == [
        ["share0", "/mnt/share", "9p", "trans=virtio,version=9p2000.L,rw,nofail", "0", "0"],
        ["share1", "/mnt/ro", "virtiofs", "ro,nofail", "0", "0"],
      ])
    let runcmd = try #require(doc["runcmd"] as? [[String]])
    #expect(runcmd.contains(["systemctl", "enable", "--now", "serial-getty@hvc0.service"]))
    #expect(doc["bootcmd"] as? [String] == [CloudInit.hvc0BootCommand])
    #expect(
      CloudInit.hvc0BootCommand
        == "test -e /etc/default/grub.d/99-vmlab-console.cfg || { mkdir -p /etc/default/grub.d && "
        + "printf '%s\\n' 'GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE_LINUX console=hvc0\"' "
        + "> /etc/default/grub.d/99-vmlab-console.cfg && update-grub; }")
    #expect(runcmd.contains(["x11vnc", "-storepasswd", "s3cret\"x", "/etc/x11vnc.pass"]))
    let files = try #require(doc["write_files"] as? [[String: String]])
    #expect(files.map { $0["path"] }.contains("/etc/systemd/system/vmlab-vnc.service"))
    let autologin = try #require(files.first { $0["path"]?.contains("lightdm") == true })
    #expect(autologin["content"]?.contains("autologin-user=debian") == true)
  }

  /// R-603: Rosetta is mounted over virtiofs and registered with binfmt_misc after the mount.
  @Test(.enabled(if: RubyYAML.available)) func rosettaIsMountedAndRegistered() throws {
    var config = Self.base()
    config.rosetta = true
    config.mounts = [GuestMount(tag: "share0", guestPath: "/mnt/share0", kind: .virtiofs)]
    let doc = try #require(try RubyYAML.parse(CloudInit.userData(config)) as? [String: Any])
    #expect(
      doc["mounts"] as? [[String]] == [
        ["share0", "/mnt/share0", "virtiofs", "rw,nofail", "0", "0"],
        ["rosetta", "/mnt/rosetta", "virtiofs", "ro,nofail", "0", "0"],
      ])
    let files = try #require(doc["write_files"] as? [[String: String]])
    let binfmt = try #require(files.first { $0["path"] == RosettaGuest.binfmtFile })
    #expect(
      binfmt["content"]
        == ":rosetta:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:"
        + "\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:"
        + "/mnt/rosetta/rosetta:CF\n")
    let dropIn = try #require(files.first { $0["path"] == RosettaGuest.binfmtDropIn })
    #expect(dropIn["content"] == "[Unit]\nRequiresMountsFor=/mnt/rosetta\n")
    let runcmd = try #require(doc["runcmd"] as? [[String]])
    #expect(runcmd.contains(["systemctl", "restart", "systemd-binfmt.service"]))
    #expect(!CloudInit.cloudConfig(Self.base()).contains("rosetta"))
  }

  /// R-504 on QEMU: the desktop without a VNC server, which QEMU's own VNC replaces.
  @Test(.enabled(if: RubyYAML.available)) func desktopWithoutVNCServer() throws {
    var config = Self.base()
    config.gui = GUIStack(vncPassword: nil)
    let doc = try #require(try RubyYAML.parse(CloudInit.userData(config)) as? [String: Any])
    let packages = try #require(doc["packages"] as? [String])
    #expect(packages.contains("xfce4") && packages.contains("xserver-xorg-video-fbdev"))
    #expect(!packages.contains("x11vnc"))
    let runcmd = try #require(doc["runcmd"] as? [[String]])
    #expect(runcmd.contains(["systemctl", "enable", "--now", "lightdm"]))
    #expect(runcmd.contains(["systemctl", "set-default", "graphical.target"]))
    #expect(!runcmd.contains { $0.first == "x11vnc" })
    let files = try #require(doc["write_files"] as? [[String: String]])
    #expect(!files.contains { $0["path"]?.contains("vmlab-vnc") == true })
    #expect(files.contains { $0["content"]?.contains("autologin-session=xfce") == true })
    #expect(files.contains { $0["content"]?.contains("logind-check-graphical=false") == true })
  }

  @Test func inGuestVNCWritesAndReusesThePasswordFile() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-gui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let stack = try GUIStack.inGuestVNC(vmDirectory: dir)
    let password = try #require(stack.vncPassword)
    #expect(password.count == 8)
    let file = dir.appending(path: "vnc.pass")
    #expect(try String(contentsOf: file, encoding: .utf8) == password + "\n")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
    #expect(mode as? Int == 0o600)
    #expect(try GUIStack.inGuestVNC(vmDirectory: dir) == stack)
    #expect(stack.packages.last == "x11vnc")
  }

  @Test(.enabled(if: RubyYAML.available)) func segmentNICGetsStaticNetworkConfig() throws {
    var config = Self.base()
    config.segment = SegmentNIC(
      primaryMAC: "52:54:00:AA:00:01", mac: "52:54:00:aa:00:02", address: "10.1.0.10")
    let text = try #require(CloudInit.networkConfig(config))
    let doc = try #require(try RubyYAML.parse(text) as? [String: Any])
    #expect(doc["version"] as? Int == 2)
    let ethernets = try #require(doc["ethernets"] as? [String: [String: Any]])
    #expect(
      (ethernets["nat0"]?["match"] as? [String: String])?["macaddress"] == "52:54:00:aa:00:01")
    #expect(ethernets["nat0"]?["dhcp4"] as? Bool == true)
    #expect(ethernets["seg0"]?["addresses"] as? [String] == ["10.1.0.10/24"])
    #expect(ethernets["seg0"]?["dhcp4"] as? Bool == false)
  }

  /// VZ finds the guest by MAC in vmnet's lease file, so the NAT NIC identifies itself by MAC.
  @Test(.enabled(if: RubyYAML.available)) func dhcpIdentifierMACGetsNetworkConfig() throws {
    var config = Self.base()
    config.dhcpIdentifierMAC = "02:AB:00:00:00:01"
    let text = try #require(CloudInit.networkConfig(config))
    let doc = try #require(try RubyYAML.parse(text) as? [String: Any])
    let ethernets = try #require(doc["ethernets"] as? [String: [String: Any]])
    #expect(ethernets.keys.sorted() == ["nat0"])
    #expect(
      (ethernets["nat0"]?["match"] as? [String: String])?["macaddress"] == "02:ab:00:00:00:01")
    #expect(ethernets["nat0"]?["dhcp4"] as? Bool == true)
    #expect(ethernets["nat0"]?["dhcp-identifier"] as? String == "mac")
  }

  @Test(.enabled(if: RubyYAML.available)) func hostileStringsRoundTrip() throws {
    let values = [
      "yes", "no", "null", "~", "123", "0o17", "- a", ": b", "#c", "a: b", "'q'", "\"dq\"",
      "back\\slash", "line\nbreak", "tab\there", "\u{1}ctl", "é ü 日本", "", " lead", "trail ",
      "&anchor", "*alias", "!tag", "%dir", "@at", "`tick`", "{x}", "[y]", "|", ">",
    ]
    let node = YAML.map([
      ("list", .list(values.map(YAML.string))),
      (
        "nested", .list([.list(["a", .list(["b", "c"])]), .map([("k", "v"), ("e", .list([]))])])
      ),
      ("Odd Key: x", "v"),
    ])
    let doc = try #require(try RubyYAML.parse(node.render()) as? [String: Any])
    #expect(doc["list"] as? [String] == values)
    let nested = try #require(doc["nested"] as? [Any])
    #expect((nested[0] as? [Any])?.first as? String == "a")
    #expect(((nested[0] as? [Any])?[1] as? [String]) == ["b", "c"])
    #expect((nested[1] as? [String: Any])?["k"] as? String == "v")
    #expect(((nested[1] as? [String: Any])?["e"] as? [Any])?.isEmpty == true)
    #expect(doc["Odd Key: x"] as? String == "v")
  }

  @Test func extraUserDataIsMergedLastAsMultipart() throws {
    var config = Self.base()
    config.extraUserData = "#cloud-config\npackages: [htop]\n"
    let text = try CloudInit.userData(config)
    #expect(text.hasPrefix("Content-Type: multipart/mixed;"))
    let ours = try #require(text.range(of: "filename=\"vmlab.cfg\""))
    let theirs = try #require(text.range(of: "packages: [htop]"))
    #expect(ours.lowerBound < theirs.lowerBound)
    #expect(text.contains("Merge-Type: \(CloudInit.mergeType)"))
    #expect(text.hasSuffix("--\(CloudInit.boundary)--\n"))

    config.extraUserData = "#!/bin/sh\necho hi\n"
    let script = try CloudInit.userData(config)
    #expect(script.contains("Content-Type: text/x-shellscript"))
    #expect(!script.contains("Merge-Type"))

    config.extraUserData = "packages: [htop]"
    #expect(throws: VMLabError.self) { try CloudInit.userData(config) }
  }

  @Test func reportsHdiutilFailure() throws {
    struct Failing: CommandRunning {
      func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
        CommandOutput(status: 1, output: "boom")
      }
    }
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-seed-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let error = try #require(
      throws: VMLabError.self,
      performing: {
        try CloudInit.makeSeed(
          Self.base(), directory: dir.appending(path: "seed"), iso: dir.appending(path: "s.iso"),
          runner: Failing())
      })
    #expect(error.code == .provisionFailed)
  }

  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")))
  func buildsISOContainingSeedFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-seed-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let iso = dir.appending(path: "seed.iso")
    var config = Self.base()
    config.segment = SegmentNIC(
      primaryMAC: "52:54:00:00:00:01", mac: "52:54:00:00:00:02", address: "10.1.0.10")
    try CloudInit.makeSeed(config, directory: dir.appending(path: "seed"), iso: iso)
    #expect(FileManager.default.fileExists(atPath: iso.path))

    let mount = dir.appending(path: "mnt")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let runner = ProcessRunner()
    let attach = try #require(
      runner.run(
        "/usr/bin/hdiutil",
        ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, iso.path]))
    #expect(attach.status == 0, "\(attach.output)")
    defer { _ = runner.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
    let names = try FileManager.default.contentsOfDirectory(atPath: mount.path)
    #expect(Set(names).isSuperset(of: ["user-data", "meta-data", "network-config"]))
    let userData = try String(contentsOf: mount.appending(path: "user-data"), encoding: .utf8)
    #expect(userData == (try CloudInit.userData(config)))
  }
}
