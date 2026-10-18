import Foundation
import Testing
import VMLabCore
import VMLabVZ

@Suite struct ControlProtocolTests {
  static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

  @Test func requestWireFormat() throws {
    #expect(
      Self.text(try ControlCodec.line(ControlRequest(.status))) == "{\"command\":\"status\"}\n")
    #expect(
      Self.text(try ControlCodec.line(ControlRequest(.save, path: "/vm/state.vzsave")))
        == "{\"command\":\"save\",\"path\":\"/vm/state.vzsave\"}\n")
  }

  @Test(arguments: ControlCommand.allCases)
  func everyCommandRoundTrips(command: ControlCommand) throws {
    let request = ControlRequest(command, path: command.takesPath ? "/tmp/x" : nil)
    let line = try ControlCodec.line(request)
    #expect(line.last == UInt8(ascii: "\n"))
    #expect(line.dropLast().contains(UInt8(ascii: "\n")) == false)
    #expect(try ControlCodec.decodeRequest(line) == request)
  }

  @Test func responseRoundTrips() throws {
    let ok = ControlResponse.success(.paused, pid: 42)
    #expect(
      Self.text(try ControlCodec.line(ok)) == "{\"ok\":true,\"pid\":42,\"state\":\"paused\"}\n")
    #expect(try ControlCodec.decodeResponse(try ControlCodec.line(ok)) == ok)

    let refusal = ControlResponse.failure(
      VMLabError(
        code: .wrongState, message: "The guest is stopped", hint: "Check status.",
        data: ["state": .string("stopped")]), state: .stopped)
    let decoded = try ControlCodec.decodeResponse(try ControlCodec.line(refusal))
    #expect(decoded == refusal)
    #expect(decoded.error?.code == .wrongState)
  }

  @Test func acceptsCRLFAndBareObjects() throws {
    #expect(
      try ControlCodec.decodeRequest(Data("{\"command\":\"pause\"}\r\n".utf8)).command == .pause)
    #expect(try ControlCodec.decodeRequest(Data("{\"command\":\"kill\"}".utf8)).command == .kill)
  }

  @Test(arguments: [
    ("not json", "command"),
    ("{}", "command"),
    ("{\"command\":\"reboot\"}", "command"),
    ("{\"command\":\"save\"}", "path"),
    ("{\"command\":\"restore\",\"path\":\"relative/file\"}", "path"),
    ("{\"command\":\"pause\",\"path\":\"/x\"}", "path"),
  ])
  func refusesBadRequests(line: String, field: String) {
    #expect {
      try ControlCodec.decodeRequest(Data(line.utf8))
    } throws: { error in
      let error = error as? VMLabError
      return error?.code == .invalidRequest && error?.data["field"] == .string(field)
    }
  }

  @Test func unreadableResponseIsEngineError() {
    #expect {
      try ControlCodec.decodeResponse(Data("hello\n".utf8))
    } throws: { ($0 as? VMLabError)?.code == .engineError }
  }

  @Test func runnerStatesMapToRecordStates() {
    #expect(RunnerState.running.vmState == .running)
    #expect(RunnerState.paused.vmState == .paused)
    #expect(RunnerState.stopped.vmState == .stopped)
    #expect(RunnerState.error.vmState == .broken)
    #expect(RunnerState.starting.vmState == nil)
  }

  @Test func lineBufferSplitsAcrossChunks() throws {
    var buffer = LineBuffer()
    #expect(try buffer.feed(Array("{\"a\":".utf8)).isEmpty)
    let lines = try buffer.feed(Array("1}\n{\"b\":2}\n{\"c\"".utf8))
    #expect(lines.map(Self.text) == ["{\"a\":1}", "{\"b\":2}"])
    #expect(try buffer.feed(Array(":3}\n".utf8)).map(Self.text) == ["{\"c\":3}"])
  }

  @Test func lineBufferRefusesOverlongLines() {
    var buffer = LineBuffer()
    #expect {
      try buffer.feed([UInt8](repeating: UInt8(ascii: "a"), count: ControlCodec.maxLineBytes + 1))
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
  }

  /// P3: a completed line over the limit is refused too, not only an unfinished one.
  @Test func lineBufferRefusesOverlongCompletedLines() {
    var buffer = LineBuffer()
    let line = [UInt8](repeating: UInt8(ascii: "a"), count: ControlCodec.maxLineBytes + 1)
    #expect {
      try buffer.feed(line + [UInt8(ascii: "\n")])
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
    var exact = LineBuffer()
    let fits = [UInt8](repeating: UInt8(ascii: "a"), count: ControlCodec.maxLineBytes)
    #expect((try? exact.feed(fits + [UInt8(ascii: "\n")]))?.count == 1)
  }

  @Test func configRoundTrips() throws {
    let record = VMRecord(
      id: "vm-abcdef", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64), features: [],
      resources: ResourceSpec(cpus: 3, memoryGB: nil))
    let dir = URL(filePath: "/tmp/vmlab-test/vms/vm-abcdef")
    let config = try VZRunnerConfig.linux(record: record, vmDirectory: dir, seed: false)
    #expect(config.cpus == 3)
    #expect(config.memoryBytes == 4 << 30)
    #expect(config.disks == [.init(path: "/tmp/vmlab-test/vms/vm-abcdef/disk.raw")])
    #expect(config.boot == .efi(variableStore: "/tmp/vmlab-test/vms/vm-abcdef/efi-vars.bin"))
    #expect(config.consoleLog == "/tmp/vmlab-test/vms/vm-abcdef/console.log")
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(VZRunnerConfig.self, from: data) == config)
  }

  @Test func runnerPathsLiveInTheVMDirectory() {
    let paths = VZRunnerPaths(vmDirectory: URL(filePath: "/h/vms/vm-abcdef"))
    #expect(paths.controlSocket.path == "/h/vms/vm-abcdef/control.sock")
    #expect(paths.pidFile.path == "/h/vms/vm-abcdef/vz.pid")
    #expect(paths.log.path == "/h/vms/vm-abcdef/vz.log")
  }
}
