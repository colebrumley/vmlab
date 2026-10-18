import Foundation
import Testing
import VMLabCore

@testable import VMLabQEMU

/// R-311 Verify: QMP transcripts of every named query, the raw allowlist and both dump forms.
@Suite struct QEMUIntrospectionTests {
  static func client(_ transcript: String) async throws -> (QMPClient, ScriptedQMPTransport) {
    let transport = ScriptedQMPTransport(
      transcript: QEMUCheckpointsTests.greeting + "\n" + transcript)
    return (try await QMPClient.handshake(over: transport, timeout: .seconds(5)), transport)
  }

  @Test func namedQueriesMapToQMPAndHMP() async throws {
    let (qmp, transport) = try await Self.client(
      """
      > {"execute":"query-status","id":"vmlab-2"}
      < {"return": {"status": "running", "running": true}, "id": "vmlab-2"}
      > {"execute":"query-block","id":"vmlab-3"}
      < {"return": [{"device": "disk0"}], "id": "vmlab-3"}
      > {"execute":"query-pci","id":"vmlab-4"}
      < {"return": [{"bus": 0, "devices": [{"qdev_id": "", "class_info": {"desc": "SCSI controller", "class": 256}, "id": {"device": 4097, "vendor": 6900}}]}], "id": "vmlab-4"}
      > {"execute":"query-cpus-fast","id":"vmlab-5"}
      < {"return": [{"cpu-index": 0, "qom-path": "/machine/unattached/device[0]", "thread-id": 1, "target": "aarch64"}], "id": "vmlab-5"}
      > {"execute":"human-monitor-command","id":"vmlab-6","arguments":{"command-line":"info mtree"}}
      < {"return": "address-space: memory\\r\\n  0000000000000000-ffffffffffffffff (prio 0, i/o): system\\r\\n", "id": "vmlab-6"}
      > {"execute":"human-monitor-command","id":"vmlab-7","arguments":{"command-line":"info registers -a"}}
      < {"return": "CPU#0\\r\\n PC=ffff800080001234\\r\\n", "id": "vmlab-7"}
      > {"execute":"human-monitor-command","id":"vmlab-8","arguments":{"command-line":"info qtree"}}
      < {"return": "bus: main-system-bus\\r\\n", "id": "vmlab-8"}
      > {"execute":"query-chardev","id":"vmlab-9"}
      < {"return": [{"frontend-open": true, "filename": "unix:serial.sock", "label": "serial0"}], "id": "vmlab-9"}
      > {"execute":"human-monitor-command","id":"vmlab-10","arguments":{"command-line":"info mtree -f"}}
      < {"return": "FlatView #0\\r\\n", "id": "vmlab-10"}
      """)
    let intro = QMPIntrospection(qmp: qmp)
    #expect(
      try await intro.query(.status)
        == .json(.object(["status": .string("running"), "running": .bool(true)])))
    #expect(try await intro.query(.block) == .json(.array([.object(["device": .string("disk0")])])))
    guard case .json(let pci) = try await intro.query(.pci) else {
      Issue.record("pci is not JSON")
      return
    }
    #expect(pci.arrayValue?.first?["devices"]?.arrayValue?.count == 1)
    guard case .json(let cpus) = try await intro.query(.cpus) else {
      Issue.record("cpus is not JSON")
      return
    }
    #expect(cpus.arrayValue?.first?["target"] == .string("aarch64"))
    guard case .text(let mtree) = try await intro.query(.memoryTree) else {
      Issue.record("memory_tree is not text")
      return
    }
    #expect(mtree.hasPrefix("address-space: memory"))
    #expect(try await intro.query(.registers) == .text("CPU#0\r\n PC=ffff800080001234\r\n"))
    #expect(try await intro.query(.devices) == .text("bus: main-system-bus\r\n"))
    guard case .json(let chardev) = try await intro.query(.qmp("query-chardev")) else {
      Issue.record("raw qmp is not JSON")
      return
    }
    #expect(chardev.arrayValue?.first?["label"] == .string("serial0"))
    #expect(try await intro.query(.hmp("info   mtree -f")) == .text("FlatView #0\r\n"))
    #expect(await transport.mismatches == [])
  }

  @Test(arguments: [
    "quit", "system_reset", "query-", "query-status;quit", "Query-status", "x-query-foo",
    "human-monitor-command",
  ])
  func rawQMPOutsideQueryIsRefused(command: String) async throws {
    let (qmp, transport) = try await Self.client("")
    let error = await #expect(throws: VMLabError.self) {
      try await QMPIntrospection(qmp: qmp).query(.qmp(command))
    }
    #expect(error?.code == .invalidRequest)
    #expect(error?.data["field"] == .string("qmp"))
    #expect(await transport.mismatches == [])
  }

  @Test(arguments: [
    "info", "quit", "savevm x", "info registers; quit", "infomtree", "info $(x)", "system_reset",
    "info mtree\nquit",
  ])
  func rawHMPOutsideInfoIsRefused(command: String) async throws {
    let (qmp, _) = try await Self.client("")
    let error = await #expect(throws: VMLabError.self) {
      try await QMPIntrospection(qmp: qmp).query(.hmp(command))
    }
    #expect(error?.code == .invalidRequest)
    #expect(error?.data["field"] == .string("hmp"))
  }

  static func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "vmlab-dump-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func rangeDumpUsesPmemsaveAndReportsTheFileSize() async throws {
    let dir = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appending(path: "range.raw")
    let (qmp, transport) = try await Self.client(
      """
      > {"execute":"pmemsave","id":"vmlab-2","arguments":{"val":1073741824,"size":1048576,"filename":"\(path.path)"}}
      < {"return": {}, "id": "vmlab-2"}
      """)
    // QEMU writes the file; here the test does.
    FileManager.default.createFile(atPath: path.path, contents: Data(count: 1 << 20))
    let result = try await QMPMemoryDumper(qmp: qmp).dump(
      MemoryDumpRequest(address: 0x4000_0000, size: 1 << 20, path: path))
    #expect(result == MemoryDumpResult(path: path, bytes: 1 << 20, format: .raw))
    #expect(await transport.mismatches == [])
  }

  @Test func fullDumpIsAnELFCoreWithoutPaging() async throws {
    let dir = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appending(path: "all.elf")
    let (qmp, transport) = try await Self.client(
      """
      > {"execute":"dump-guest-memory","id":"vmlab-2","arguments":{"paging":false,"protocol":"file:\(path.path)","format":"elf"}}
      < {"return": {}, "id": "vmlab-2"}
      """)
    FileManager.default.createFile(atPath: path.path, contents: Data(count: 4096))
    let result = try await QMPMemoryDumper(qmp: qmp).dump(MemoryDumpRequest(path: path))
    #expect(result == MemoryDumpResult(path: path, bytes: 4096, format: .elf))
    #expect(await transport.mismatches == [])
  }

  @Test func aDumpThatWroteNothingIsAnEngineError() async throws {
    let dir = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appending(path: "missing.raw")
    let (qmp, _) = try await Self.client(
      """
      > {"execute":"pmemsave","id":"vmlab-2","arguments":{"val":0,"size":16,"filename":"\(path.path)"}}
      < {"return": {}, "id": "vmlab-2"}
      """)
    let error = await #expect(throws: VMLabError.self) {
      try await QMPMemoryDumper(qmp: qmp).dump(MemoryDumpRequest(address: 0, size: 16, path: path))
    }
    #expect(error?.code == .engineError)
  }
}
