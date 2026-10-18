import Foundation
import Testing
import VMLabCore

@testable import VMLabQEMU

@Suite struct QEMUCheckpointsTests {
  static let greeting = """
    < {"QMP": {"version": {"qemu": {"micro": 2, "minor": 1, "major": 11}}, "capabilities": []}}
    > {"execute":"qmp_capabilities","id":"vmlab-1"}
    < {"return": {}, "id": "vmlab-1"}
    """

  static func queryBlock(id: Int, snapshots: [String] = []) -> String {
    let list = snapshots.map { #"{"id": "1", "name": "\#($0)", "vm-state-size": 4096}"# }
      .joined(separator: ", ")
    return """
      > {"execute":"query-block","id":"vmlab-\(id)"}
      < {"return": [{"device": "pflash1", "inserted": {"node-name": "#block323", "drv": "raw"}}, {"device": "disk0", "inserted": {"node-name": "#block555", "drv": "qcow2", "image": {"snapshots": [\(list)]}}}], "id": "vmlab-\(id)"}
      """
  }

  static func client(_ transcript: String) async throws -> (QMPClient, ScriptedQMPTransport) {
    let transport = ScriptedQMPTransport(transcript: greeting + "\n" + transcript)
    return (try await QMPClient.handshake(over: transport, timeout: .seconds(5)), transport)
  }

  @Test func snapshotSaveRunsTheJobOnDisk0AndDismissesIt() async throws {
    let (qmp, transport) = try await Self.client(
      Self.queryBlock(id: 2) + """

        > {"execute":"snapshot-save","id":"vmlab-3","arguments":{"job-id":"vmlab-save-cp-1","tag":"cp-1","vmstate":"#block555","devices":["#block555"]}}
        < {"event": "JOB_STATUS_CHANGE", "data": {"status": "created", "id": "vmlab-save-cp-1"}}
        < {"return": {}, "id": "vmlab-3"}
        > {"execute":"query-jobs","id":"vmlab-4"}
        < {"return": [{"current-progress": 0, "status": "running", "total-progress": 1, "type": "snapshot-save", "id": "vmlab-save-cp-1"}], "id": "vmlab-4"}
        > {"execute":"query-jobs","id":"vmlab-5"}
        < {"return": [{"current-progress": 1, "status": "concluded", "total-progress": 1, "type": "snapshot-save", "id": "vmlab-save-cp-1"}], "id": "vmlab-5"}
        > {"execute":"job-dismiss","id":"vmlab-6","arguments":{"id":"vmlab-save-cp-1"}}
        < {"return": {}, "id": "vmlab-6"}
        """)
    try await QMPSnapshots.save(
      tag: "cp-1", qmp: qmp, timeout: .seconds(5), poll: .milliseconds(1))
    #expect(await transport.mismatches == [])
  }

  @Test func snapshotLoadAndDeleteUseTheirOwnJobs() async throws {
    let (qmp, transport) = try await Self.client(
      Self.queryBlock(id: 2, snapshots: ["cp-1"]) + """

        > {"execute":"snapshot-load","id":"vmlab-3","arguments":{"job-id":"vmlab-load-cp-1","tag":"cp-1","vmstate":"#block555","devices":["#block555"]}}
        < {"return": {}, "id": "vmlab-3"}
        > {"execute":"query-jobs","id":"vmlab-4"}
        < {"return": [{"status": "concluded", "type": "snapshot-load", "id": "vmlab-load-cp-1"}], "id": "vmlab-4"}
        > {"execute":"job-dismiss","id":"vmlab-5","arguments":{"id":"vmlab-load-cp-1"}}
        < {"return": {}, "id": "vmlab-5"}
        """ + "\n" + Self.queryBlock(id: 6, snapshots: ["cp-1"]) + """

          > {"execute":"snapshot-delete","id":"vmlab-7","arguments":{"job-id":"vmlab-delete-cp-1","tag":"cp-1","devices":["#block555"]}}
          < {"return": {}, "id": "vmlab-7"}
          > {"execute":"query-jobs","id":"vmlab-8"}
          < {"return": [], "id": "vmlab-8"}
          """)
    try await QMPSnapshots.load(tag: "cp-1", qmp: qmp, timeout: .seconds(5), poll: .milliseconds(1))
    try await QMPSnapshots.delete(
      tag: "cp-1", qmp: qmp, timeout: .seconds(5), poll: .milliseconds(1))
    #expect(await transport.mismatches == [])
  }

  @Test func aFailedJobIsAnEngineErrorWithQEMUsMessage() async throws {
    let (qmp, transport) = try await Self.client(
      Self.queryBlock(id: 2) + """

        > {"execute":"snapshot-load","id":"vmlab-3","arguments":{"job-id":"vmlab-load-nope","tag":"nope","vmstate":"#block555","devices":["#block555"]}}
        < {"return": {}, "id": "vmlab-3"}
        > {"execute":"query-jobs","id":"vmlab-4"}
        < {"return": [{"status": "concluded", "type": "snapshot-load", "id": "vmlab-load-nope", "error": "Snapshot 'nope' does not exist in one or more devices"}], "id": "vmlab-4"}
        > {"execute":"job-dismiss","id":"vmlab-5","arguments":{"id":"vmlab-load-nope"}}
        < {"return": {}, "id": "vmlab-5"}
        """)
    await #expect {
      try await QMPSnapshots.load(
        tag: "nope", qmp: qmp, timeout: .seconds(5), poll: .milliseconds(1))
    } throws: {
      guard let error = $0 as? VMLabError else { return false }
      return error.code == .engineError
        && error.data["raw"] == .string("Snapshot 'nope' does not exist in one or more devices")
    }
    #expect(await transport.mismatches == [])
  }

  @Test func tagsComeFromQueryBlock() async throws {
    let (qmp, _) = try await Self.client(Self.queryBlock(id: 2, snapshots: ["a", "b"]))
    #expect(try await QMPSnapshots.tags(qmp) == ["a", "b"])
  }

  @Test(arguments: ["cp-1", "base.v2", "A_b", String(repeating: "x", count: 64)])
  func validTags(tag: String) throws {
    try QEMUCheckpoints.validate(tag: tag)
  }

  @Test(arguments: ["", "12", "has space", "semi;colon", "ü", String(repeating: "x", count: 65)])
  func invalidTags(tag: String) {
    #expect(throws: VMLabError.self) { try QEMUCheckpoints.validate(tag: tag) }
  }

  @Test func parsesQemuImgInfoSnapshots() {
    let json = """
      {"virtual-size": 8589934592, "filename": "disk.qcow2", "format": "qcow2",
       "snapshots": [{"icount": 0, "vm-state-size": 0, "name": "cp-1", "id": "1"},
                     {"vm-state-size": 0, "name": "cp-2", "id": "2"}]}
      """
    #expect(QEMUImageSnapshots.parseTags(json) == ["cp-1", "cp-2"])
    #expect(QEMUImageSnapshots.parseTags(#"{"format": "qcow2"}"#) == [])
  }

  @Test func daemonizedQEMUDisablesObjCForkSafety() {
    let env = QEMUMachine.daemonEnvironment(["PATH": "/usr/bin"])
    #expect(env["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] == "YES")
    #expect(env["PATH"] == "/usr/bin")
  }

  // MARK: The provider on a stopped guest (real qemu-img)

  static func home() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "vmlab-cp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static let installation = try? QEMUInstallation.locate()

  static func record(_ profile: Profile = .qemuHVF, features: [Feature] = [.checkpointDisk])
    -> VMRecord
  {
    VMRecord(
      id: "vm-cp", profile: profile, guest: GuestSpec(os: .linux, arch: .arm64),
      features: features, state: .stopped)
  }

  @Test func liveIsAllowedUnderTCGWhenGrantedOrWhenTheHostFactSaysYes() throws {
    let home = try Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let hvf = QEMUBackend(profile: .qemuHVF, store: store)
    #expect(!hvf.liveSnapshotsAllowed(Self.record()))
    #expect(hvf.liveSnapshotsAllowed(Self.record(features: [.checkpointLive])))
    #expect(
      QEMUBackend(profile: .qemuTCG, store: store).liveSnapshotsAllowed(Self.record(.qemuTCG)))
    var facts = SlowProbes()
    facts.record(.qemuHVFLiveSnapshot, .yes, at: Date(), osVersion: "26.6", qemuVersion: "11.1.2")
    try facts.save(to: SlowProbes.url(home: home))
    #expect(hvf.liveSnapshotsAllowed(Self.record()))
  }

  @Test(.enabled(if: installation != nil))
  func diskCheckpointsOfAStoppedGuestUseQemuImg() async throws {
    let home = try Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let backend = QEMUBackend(
      profile: .qemuHVF, store: Store(home: home), installation: Self.installation)
    let record = Self.record()
    let layout = backend.layout(of: record.id)
    try FileManager.default.createDirectory(at: layout.directory, withIntermediateDirectories: true)
    try QEMUMachine.run(
      Self.installation!.qemuImg, ["create", "-q", "-f", "qcow2", layout.disk.path, "16M"],
      step: "create")
    let provider = try await backend.checkpoints(record)
    let checkpoints = try #require(provider as? QEMUCheckpoints)

    try await provider.create(id: "cp-1", mode: .disk)
    try await provider.create(id: "cp-2", mode: .disk)
    #expect(try await checkpoints.tags() == ["cp-1", "cp-2"])
    try await provider.restore(id: "cp-1", mode: .disk)
    try await provider.delete(id: "cp-2")
    #expect(try await checkpoints.tags() == ["cp-1"])

    await #expect {
      try await provider.create(id: "cp-1", mode: .disk)
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
    await #expect {
      try await provider.restore(id: "cp-9", mode: .disk)
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
    await #expect {
      try await provider.delete(id: "cp-9")
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
    // Live needs a running guest: never started implicitly.
    await #expect {
      try await provider.create(id: "live-1", mode: .live)
    } throws: {
      guard let error = $0 as? VMLabError else { return false }
      return error.code == .wrongState && error.hint.contains("vm_lifecycle start")
    }
    await #expect {
      try await provider.restore(id: "cp-1", mode: .live)
    } throws: { ($0 as? VMLabError)?.code == .wrongState }
  }
}
