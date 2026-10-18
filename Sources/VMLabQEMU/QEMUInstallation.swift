import Foundation
import VMLabCore

/// Where the host's QEMU lives: the `qemu-system-*` and `qemu-img` binaries and the share directory
/// that holds Homebrew's edk2 firmware (`<prefix>/share/qemu`).
public struct QEMUInstallation: Sendable, Hashable {
  /// The directory holding `qemu-system-aarch64`, `qemu-system-x86_64` and `qemu-img`.
  public var binDirectory: URL
  /// `<prefix>/share/qemu`, where `edk2-*-code.fd` and the vars templates are.
  public var shareDirectory: URL

  public init(binDirectory: URL, shareDirectory: URL) {
    self.binDirectory = binDirectory
    self.shareDirectory = shareDirectory
  }

  /// The first directory in `searchPaths` with `qemu-system-aarch64`, its symlinks resolved so
  /// the share directory is found beside the real prefix (Homebrew links `bin` into the Cellar).
  public static func locate(
    searchPaths: [String] = HostProbe.defaultSearchPaths()
  ) throws(VMLabError) -> QEMUInstallation {
    let files = FileManager.default
    for dir in searchPaths {
      let binary = URL(filePath: dir).appending(path: "qemu-system-aarch64")
      guard files.isExecutableFile(atPath: binary.path) else { continue }
      let real = binary.resolvingSymlinksInPath()
      let bin = real.deletingLastPathComponent()
      let share = bin.deletingLastPathComponent().appending(path: "share/qemu")
      let linkedShare = URL(filePath: dir).deletingLastPathComponent().appending(
        path: "share/qemu")
      let shareDirectory = files.fileExists(atPath: share.path) ? share : linkedShare
      return QEMUInstallation(binDirectory: bin, shareDirectory: shareDirectory)
    }
    throw missingTool("qemu-system-aarch64")
  }

  /// `qemu-system-<target>` for `arch`: aarch64 for arm64, x86_64, riscv64, or the architecture's
  /// own QEMU name (R-310).
  public func systemBinary(for arch: GuestSpec.Arch) -> URL {
    binDirectory.appending(path: "qemu-system-\(QEMUCommandLine.target(for: arch) ?? "aarch64")")
  }

  public var qemuImg: URL { binDirectory.appending(path: "qemu-img") }

  /// The UEFI code and the variable-store template for `arch`, from Homebrew's edk2 build.
  public func firmware(for arch: GuestSpec.Arch) throws(VMLabError) -> QEMUFirmware {
    let names: (code: String, vars: String)
    switch arch {
    case .arm64: names = ("edk2-aarch64-code.fd", "edk2-arm-vars.fd")
    case .x86_64: names = ("edk2-x86_64-code.fd", "edk2-i386-vars.fd")
    case .riscv64: names = ("edk2-riscv-code.fd", "edk2-riscv-vars.fd")
    case .other(let name):
      throw VMLabError.invalidRequest(
        field: "boot.mode", reason: "vmlab has no UEFI firmware for \(name)",
        hint: "Boot with boot.mode kernel, firmware or binary.")
    }
    let code = shareDirectory.appending(path: names.code)
    let vars = shareDirectory.appending(path: names.vars)
    for file in [code, vars] where !FileManager.default.fileExists(atPath: file.path) {
      throw Self.missingTool(file.lastPathComponent, path: file.path)
    }
    return QEMUFirmware(code: code.path, varsTemplate: vars.path)
  }

  static func missingTool(_ tool: String, path: String? = nil) -> VMLabError {
    var data: [String: JSONValue] = [
      "tool": .string(tool), "fix": .string("brew install qemu"),
    ]
    if let path { data["path"] = .string(path) }
    return VMLabError(
      code: .hostMissingTool,
      message: "QEMU is not installed completely: \(tool) is missing.",
      hint: "Run `brew install qemu` (scripts/bootstrap.sh), then retry.", data: data)
  }
}

/// UEFI firmware for a QEMU guest: read-only code and a template copied to `efi-vars.bin`.
public struct QEMUFirmware: Sendable, Hashable, Codable {
  public var code: String
  public var varsTemplate: String

  public init(code: String, varsTemplate: String) {
    self.code = code
    self.varsTemplate = varsTemplate
  }
}
