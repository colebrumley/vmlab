import Foundation
import VMLabCore

/// The files a QEMU guest keeps in its VM directory (Appendix F). Socket paths go to
/// `sockaddr_un`, whose `sun_path` holds 103 bytes and a NUL; `validate()` refuses a layout whose
/// sockets would not fit, so a long `VMLAB_HOME` fails with a hint instead of a QEMU error.
public struct QEMULayout: Sendable, Hashable {
  /// `sizeof(sockaddr_un.sun_path)` on Darwin, including the terminating NUL.
  public static let maxSocketPathBytes = 104

  public var directory: URL

  public init(vmDirectory: URL) { self.directory = vmDirectory }

  public var disk: URL { directory.appending(path: "disk.qcow2") }
  public var seed: URL { directory.appending(path: "seed.iso") }
  /// Where the seed's `user-data` and `meta-data` are written before the ISO is built.
  public var seedSource: URL { directory.appending(path: "seed") }
  public var efiVars: URL { directory.appending(path: "efi-vars.bin") }
  public var qmpSocket: URL { directory.appending(path: "qmp.sock") }
  /// A second QMP monitor: QEMU's QMP socket serves one client at a time, and the server that
  /// started the guest holds `qmp.sock`, so another `vmlab` process attaches here (R-1100).
  public var secondaryQMPSocket: URL { directory.appending(path: "qmp2.sock") }
  public var serialSocket: URL { directory.appending(path: "serial.sock") }
  public var vncSocket: URL { directory.appending(path: "vnc.sock") }
  /// The host end of the `org.qemu.guest_agent.0` virtio-serial port (R-403).
  public var agentSocket: URL { directory.appending(path: "qga.sock") }
  public var pidFile: URL { directory.appending(path: "qemu.pid") }
  public var log: URL { directory.appending(path: "qemu.log") }
  public var serialLog: URL { directory.appending(path: "serial.log") }
  /// Everything the guest writes to its serial port, written by QEMU itself (chardev `logfile`),
  /// whether or not a vmlab process holds the serial socket. Appended across boots, never
  /// rotated by vmlab.
  public var consoleLog: URL { directory.appending(path: "console.log") }

  public var sockets: [URL] {
    [qmpSocket, secondaryQMPSocket, serialSocket, vncSocket, agentSocket]
  }

  /// Throws `invalid_request` when a socket path is too long for `sockaddr_un`.
  public func validate() throws(VMLabError) {
    for socket in sockets where socket.path.utf8.count >= Self.maxSocketPathBytes {
      throw VMLabError(
        code: .invalidRequest,
        message:
          "The socket path \(socket.path) is \(socket.path.utf8.count) bytes; unix sockets allow "
          + "at most \(Self.maxSocketPathBytes - 1).",
        hint: "Set VMLAB_HOME to a shorter directory, such as /tmp/vmlab-<name>.",
        data: [
          "field": .string("VMLAB_HOME"), "reason": .string("socket path too long"),
          "path": .string(socket.path),
        ])
    }
  }
}
