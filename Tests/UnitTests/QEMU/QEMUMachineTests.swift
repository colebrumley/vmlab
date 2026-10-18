import Darwin
import Foundation
import Testing
import VMLabCore

@testable import VMLabQEMU

/// A unix socket that listens and never accepts: how QEMU's QMP monitor looks to a second client
/// while another holds it (the connection waits in the backlog, ungreeted).
final class HeldMonitor: Sendable {
  let path: String
  let fd: Int32

  init() throws {
    path = "/tmp/vmlab-held-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    unlink(path)
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      buf.copyBytes(from: path.utf8)
      buf[path.utf8.count] = 0
    }
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try #require(rc == 0 && listen(fd, 4) == 0)
  }

  deinit {
    close(fd)
    unlink(path)
  }
}

@Suite struct QEMUMachineTests {
  /// R-1100: the second server gets the monitor the first one does not hold.
  @Test func attachUsesWhicheverMonitorGreets() async throws {
    let held = try HeldMonitor()
    let path = "/tmp/vmlab-qmp2-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    let free = try FakeQMPServer(path: path, connections: 1)
    defer { free.stop() }
    let started = ContinuousClock.now
    let client = try await QEMUMachine.connectFirst(
      [held.path, path], connectTimeout: .seconds(2), timeout: .seconds(20))
    #expect(ContinuousClock.now - started < .seconds(10))
    #expect(client.endpoint == path)
    #expect(try await client.queryStatus().status == "running")
    await client.close()
  }

  @Test func noFreeMonitorIsTheFirstOnesError() async throws {
    let one = try HeldMonitor()
    let two = try HeldMonitor()
    await #expect {
      _ = try await QEMUMachine.connectFirst(
        [one.path, two.path], connectTimeout: .seconds(1), timeout: .milliseconds(300))
    } throws: { ($0 as? VMLabError)?.code == .timeout }
  }

  @Test func layoutHasTwoMonitors() {
    let layout = QEMULayout(vmDirectory: URL(filePath: "/v/vm-a"))
    #expect(layout.secondaryQMPSocket.path == "/v/vm-a/qmp2.sock")
    #expect(layout.sockets.contains(layout.secondaryQMPSocket))
  }
}
