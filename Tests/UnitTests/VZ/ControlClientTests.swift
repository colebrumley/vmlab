import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// A one-thread control socket that answers each request line with `answer` (nil: stay silent).
final class FakeRunner: Sendable {
  let path: String
  let fd: Int32

  init(answer: @escaping @Sendable (ControlRequest) -> ControlResponse?) throws {
    path = "/tmp/vmlab-cc-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    unlink(path)
    fd = try UnixStream.listen(path: path)
    let fd = fd
    Thread.detachNewThread {
      while true {
        let conn = accept(fd, nil, nil)
        if conn < 0 { return }
        var buffer = LineBuffer()
        while let bytes = try? UnixStream.read(conn), !bytes.isEmpty {
          for line in (try? buffer.feed(bytes)) ?? [] {
            guard let request = try? ControlCodec.decodeRequest(line) else { continue }
            if let reply = answer(request), let data = try? ControlCodec.line(reply) {
              try? UnixStream.writeAll(conn, data)
            }
          }
        }
        close(conn)
      }
    }
  }

  deinit {
    unlink(path)
    shutdown(fd, SHUT_RDWR)
    close(fd)
  }
}

@Suite struct ControlClientTests {
  @Test func sendsAndDecodes() async throws {
    let runner = try FakeRunner { request in
      request.command == .status ? .success(.running, pid: 7) : .success(.paused, pid: 7)
    }
    let client = VZControlClient(socketPath: runner.path)
    #expect(try await client.status() == .success(.running, pid: 7))
    #expect(try await client.pause().state == .paused)
  }

  @Test func runnerRefusalIsThrown() async throws {
    let error = VMLabError(code: .wrongState, message: "stopped", hint: "h")
    let runner = try FakeRunner { _ in .failure(error, state: .stopped) }
    await #expect(throws: error) {
      try await VZControlClient(socketPath: runner.path).resume()
    }
  }

  @Test func noRunnerIsGuestUnreachable() async {
    let path = "/tmp/vmlab-cc-missing-\(getpid()).sock"
    await #expect {
      try await VZControlClient(socketPath: path).status()
    } throws: { error in
      let error = error as? VMLabError
      return error?.code == .guestUnreachable && error?.data["socket"] == .string(path)
    }
  }

  @Test func silentRunnerTimesOut() async throws {
    let runner = try FakeRunner { _ in nil }
    await #expect {
      try await VZControlClient(socketPath: runner.path).send(
        ControlRequest(.status), timeout: .milliseconds(200))
    } throws: { ($0 as? VMLabError)?.code == .timeout }
  }

  @Test func attachReportsPidAndState() async throws {
    let runner = try FakeRunner { _ in .success(.paused, pid: 99) }
    let handle = try await VMLabVZ.attach(socketPath: runner.path)
    #expect(handle.pid == 99)
    #expect(handle.state == .paused)
    #expect(handle.runtime == VMRuntime(pid: 99, controlSocket: runner.path))
  }
}
