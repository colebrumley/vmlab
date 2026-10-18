import Foundation
import Testing
import VMLabCore

/// Background jobs against the stand-in `ssh` of `SSHExecTests`, so the real job scripts run on
/// the host (`perl` for the process group, macOS `tail -f`).
@Suite struct ExecJobsTests {
  typealias Fixture = SSHExecTests.Fixture

  @Test func aJobIsReadIncrementallyAndFinishes() async throws {
    let f = try Fixture()
    let jobs = ExecJobs()
    // Each line after the first waits for a gate file the test creates once it has read the line
    // before, so the output arrives in three reads however slow the host is.
    let gate = f.dir.appending(path: "gate").path
    let job = try await jobs.start(
      ExecRequest(
        command:
          "for i in 1 2 3; do echo $i; while [ ! -f '\(gate)'$i ]; do sleep 0.1; done; done"),
      on: f.channel)
    #expect(ExecJobs.isValidJobID(job.id))
    var output = ""
    var reads = 0
    var last: ExecJobRead?
    let deadline = ContinuousClock.now + .seconds(60)
    while last?.finished != true, ContinuousClock.now < deadline {
      let read = try await jobs.read(job.id, on: f.channel)
      output += read.output
      if !read.output.isEmpty {
        reads += 1
        let lines = output.split(separator: "\n").count
        FileManager.default.createFile(atPath: gate + String(lines), contents: nil)
      }
      last = read
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(last?.finished == true)
    #expect(last?.exitCode == 0)
    #expect(output == "1\n2\n3\n")
    #expect(reads == 3, "output arrived in \(reads) read(s)")
    // Read again: nothing new.
    #expect(try await jobs.read(job.id, on: f.channel).output == "")
  }

  @Test func waitReturnsTheStatusAndKillEndsTheGroup() async throws {
    let f = try Fixture()
    let jobs = ExecJobs()
    let quick = try await jobs.start(ExecRequest(command: "echo hi; exit 4"), on: f.channel)
    let done = try await jobs.wait(quick.id, on: f.channel, timeout: .seconds(20))
    #expect(done.finished)
    #expect(done.exitCode == 4)
    #expect(done.output == "hi\n")

    let slow = try await jobs.start(ExecRequest(command: "echo up; sleep 300"), on: f.channel)
    let pending = try await jobs.wait(slow.id, on: f.channel, timeout: .seconds(2))
    #expect(!pending.finished)
    let killed = try await jobs.kill(slow.id, on: f.channel)
    #expect(killed.finished)
    #expect(killed.exitCode == 143)
  }

  @Test func aJobSurvivesARestartOfTheServer() async throws {
    let f = try Fixture()
    let first = ExecJobs()
    let job = try await first.start(
      ExecRequest(command: "echo one; sleep 2; echo two"), on: f.channel)
    try await Task.sleep(for: .milliseconds(800))
    await first.stopReaders()
    // A fresh process: no reader, only the files on disk.
    let second = ExecJobs()
    let done = try await second.wait(job.id, on: f.channel, timeout: .seconds(20))
    #expect(done.finished)
    #expect(done.exitCode == 0)
    #expect(done.output.hasSuffix("two\n"))
    #expect(done.output.filter { $0 == "\n" }.count == 2, "\(done.output)")
  }

  @Test func unknownJobsAreInvalidRequest() async throws {
    let f = try Fixture()
    let error = await #expect(throws: VMLabError.self) {
      try await ExecJobs().read("j-000000000000", on: f.channel)
    }
    #expect(error?.code == .invalidRequest)
    #expect(!ExecJobs.isValidJobID("../../etc"))
  }

  /// CR-6: a start whose ssh outlives its timeout after the guest launched the job kills the job
  /// and leaves no record, so no guest job runs without an id the model could kill.
  @Test func aStartThatTimesOutKillsTheJobAndLeavesNoRecord() async throws {
    let f = try Fixture()
    let mark = f.dir.appending(path: "hang")
    FileManager.default.createFile(atPath: mark.path, contents: nil)
    // The stand-in ssh runs the command, then hangs once (the start call) as a lost link would.
    try """
    #!/bin/sh
    for a; do last=$a; done
    /bin/sh -c "$last"
    rc=$?
    if [ -f '\(mark.path)' ]; then rm -f '\(mark.path)'; exec sleep 30; fi
    exit $rc
    """.write(to: f.dir.appending(path: "ssh"), atomically: true, encoding: .utf8)
    let pidFile = f.dir.appending(path: "job.pid")
    let jobs = ExecJobs(startTimeout: .seconds(5))
    let error = await #expect(throws: VMLabError.self) {
      try await jobs.start(
        ExecRequest(command: "echo $$ > '\(pidFile.path)'; exec sleep 300"), on: f.channel)
    }
    #expect(error?.code == .timeout)
    let records = try f.scratch().filter { $0.hasSuffix(".json") || $0.hasSuffix(".log") }
    #expect(records.isEmpty, "\(records)")
    // The job may still be writing its pid on a busy host.
    let written = ContinuousClock.now + .seconds(10)
    while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < written {
      try await Task.sleep(for: .milliseconds(100))
    }
    let text = try String(contentsOf: pidFile, encoding: .utf8)
    let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    let deadline = ContinuousClock.now + .seconds(10)
    while Darwin.kill(pid, 0) == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(Darwin.kill(pid, 0) != 0, "job \(pid) still runs")
  }
}
