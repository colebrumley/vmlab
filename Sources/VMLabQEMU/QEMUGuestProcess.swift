import Foundation
import VMLabCore

extension VMLabQEMU {
  /// Recognises a `qemu-system-*` process as a guest, vmlab's or not, for the host-wide memory
  /// count (`HostMemoryGuard`): its `-m` memory, and its VM directory from vmlab's `-pidfile`.
  public static let guestProcessRecognizer = GuestProcessRecognizer(
    engine: "qemu",
    matchesExecutable: { URL(filePath: $0).lastPathComponent.hasPrefix("qemu-system-") },
    recognize: { process in
      guard let memoryGB = memoryGB(arguments: process.arguments) else { return nil }
      let directory = value(of: "-pidfile", in: process.arguments).map {
        URL(filePath: $0).deletingLastPathComponent().path
      }
      return HostGuestProcess(
        pid: process.pid, engine: "qemu", memoryGB: memoryGB, directory: directory)
    })

  /// The guest memory of a QEMU command line in GiB: `-m 4096M`, `-m 4G`, `-m 512` (MiB) or
  /// `-m size=4G,slots=2`. QEMU's default (128 MiB) when `-m` is absent.
  public static func memoryGB(arguments: [String]) -> Double? {
    guard var text = value(of: "-m", in: arguments) else { return 0.125 }
    text = String(text.split(separator: ",").first ?? "")
    if text.hasPrefix("size=") { text.removeFirst(5) }
    let unit = text.last.flatMap { $0.isLetter ? $0.uppercased() : nil }
    let digits = unit == nil ? text : String(text.dropLast())
    guard let number = Double(digits), number > 0 else { return nil }
    switch unit {
    case nil, "M": return number / 1024
    case "G": return number
    case "T": return number * 1024
    case "K": return number / 1_048_576
    default: return nil
    }
  }

  static func value(of option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }
}
