import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// The runner's `serial.sock` bridge (R-602) speaks what `SerialChannel` reads from QEMU: bytes
/// both ways, one client at a time, plus the backlog of output made before anyone connected.
@Suite struct SerialBridgeTests {
  /// A bridge on a short /tmp socket, the pipe standing in for the guest's console input, and a
  /// log directory.
  struct Fixture {
    let directory: URL
    let socket: String
    let input = Pipe()
    let bridge: SerialBridge

    init(backlog: Int = SerialBridge.backlogCapacity) throws {
      let id = UUID().uuidString.prefix(8)
      directory = URL(filePath: "/tmp/vmlab-br-\(id)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      socket = directory.appending(path: "serial.sock").path
      bridge = try SerialBridge(
        path: socket, guestInput: input.fileHandleForWriting.fileDescriptor,
        backlogCapacity: backlog)
      bridge.start()
    }

    func channel() async throws -> SerialChannel {
      let channel = SerialChannel(
        socketPath: socket, logURL: directory.appending(path: "serial-\(UUID()).log"))
      try await channel.start()
      return channel
    }

    /// Reads exactly `count` bytes the bridge wrote to the guest.
    func guestReceived(_ count: Int) -> String {
      String(
        decoding: (try? input.fileHandleForReading.read(upToCount: count)) ?? Data(),
        as: UTF8.self)
    }

    /// Stops the bridge first: it writes to `input`'s raw descriptor, which closes with the pipe.
    func cleanUp() {
      bridge.stop()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  @Test func bootOutputBeforeTheFirstClientIsDelivered() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    f.bridge.guestOutput(Array("[    0.000000] Booting Linux\n".utf8))
    let channel = try await f.channel()
    defer { Task { await channel.stop() } }
    f.bridge.guestOutput(Array("debian login: ".utf8))
    let match = try await channel.wait(for: "login: ", since: 0, timeout: .seconds(5))
    #expect(match.offset == UInt64("[    0.000000] Booting Linux\ndebian login: ".utf8.count))
    #expect(await channel.read(since: 0).text.hasPrefix("[    0.000000] Booting Linux\n"))
    #expect(f.bridge.backlog.isEmpty)
  }

  @Test func clientBytesReachTheGuestUnchanged() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let channel = try await f.channel()
    defer { Task { await channel.stop() } }
    try await channel.write("root\n")
    #expect(f.guestReceived(5) == "root\n")
  }

  @Test func outputWhileDisconnectedWaitsForTheNextClient() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let first = try await f.channel()
    #expect(await eventually { f.bridge.hasClient })
    await first.stop()
    #expect(await eventually { !f.bridge.hasClient })
    f.bridge.guestOutput(Array("while away\n".utf8))
    #expect(f.bridge.backlog == Array("while away\n".utf8))
    let second = try await f.channel()
    defer { Task { await second.stop() } }
    #expect(try await second.wait(for: "while away", since: 0, timeout: .seconds(5)).start == 0)
  }

  /// `stop` drops the client and closes the listener, after which the bridge no longer writes to
  /// the guest's input; it is safe twice (the fixture's clean-up calls it again).
  @Test func stopDropsTheClientAndClosesTheListener() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let channel = try await f.channel()
    defer { Task { await channel.stop() } }
    #expect(await eventually { f.bridge.hasClient })
    f.bridge.stop()
    #expect(!f.bridge.hasClient)
    // Refused once the last copy of the listener is gone; a child another test is spawning may
    // hold one for a few ms (`SpawnWindow`).
    #expect(
      await SpawnWindow.eventually {
        guard let fd = try? UnixStream.connect(path: f.socket) else { return true }
        close(fd)
        return false
      })
  }

  @Test func backlogKeepsTheNewestBytes() throws {
    let f = try Fixture(backlog: 8)
    defer { f.cleanUp() }
    f.bridge.guestOutput(Array("0123456789".utf8))
    f.bridge.guestOutput(Array("ab".utf8))
    #expect(String(decoding: f.bridge.backlog, as: UTF8.self) == "456789ab")
  }

  /// As with QEMU's socket chardev, a second client is served only after the first leaves.
  @Test func oneClientAtATime() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let first = try await f.channel()
    #expect(await eventually { f.bridge.hasClient })
    let second = try await f.channel()
    defer { Task { await second.stop() } }
    f.bridge.guestOutput(Array("to the first\n".utf8))
    _ = try await first.wait(for: "first", since: 0, timeout: .seconds(5))
    #expect(await second.endOffset == 0)
    await first.stop()
    f.bridge.guestOutput(Array("to the second\n".utf8))
    _ = try await second.wait(for: "second\n", since: 0, timeout: .seconds(5))
    #expect(await second.read(since: 0).text == "to the second\n")
  }
}
