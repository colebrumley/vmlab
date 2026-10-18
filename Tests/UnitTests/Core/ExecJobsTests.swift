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
    let job = try await jobs.start(
      ExecRequest(command: "for i in 1 2 3; do echo $i; sleep 1; done"), on: f.channel)
    #expect(ExecJobs.isValidJobID(job.id))
    var output = ""
    var reads = 0
    var last: ExecJobRead?
    while last?.finished != true, reads < 100 {
      let read = try await jobs.read(job.id, on: f.channel)
      output += read.output
      if !read.output.isEmpty { reads += 1 }
      last = read
      try await Task.sleep(for: .milliseconds(300))
    }
    #expect(last?.finished == true)
    #expect(last?.exitCode == 0)
    #expect(output == "1\n2\n3\n")
    #expect(reads >= 2, "output arrived in \(reads) read(s)")
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
}
