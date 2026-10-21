import Foundation
import Testing
import VMLabCore
import VMLabMCP

@testable import vmlab

/// The CLI builds the same JSON arguments a model would send.
@Suite struct ToolCommandTests {
  @Test func planFlagsBecomeRequirements() throws {
    let command = try PlanCommand.parse(["--guest", "linux", "--require", "serial,gdb", "--json"])
    #expect(command.json)
    #expect(
      try command.arguments()
        == .object([
          "requirements": .object([
            "guest": .object(["os": .string("linux"), "arch": .string("arm64")]),
            "require": .array([.string("serial"), .string("gdb")]),
          ])
        ]))
  }

  @Test func planTakesEveryRequirementFlag() throws {
    let command = try PlanCommand.parse([
      "--guest", "linux", "--arch", "x86_64", "--require", "serial", "--require", "gdb",
      "--prefer", "net_fast", "--cpus", "4", "--memory-gb", "8", "--disk-gb", "40",
      "--network", "nat", "--segment", "lab", "--forward", "22", "--forward", "8080:18080",
      "--image", "debian-13-arm64", "--allow-unverified",
    ])
    let arguments = try command.arguments()
    let r = arguments["requirements"]
    #expect(arguments["allowUnverified"] == .bool(true))
    #expect(r?["guest"]?["arch"] == .string("x86_64"))
    #expect(r?["require"] == .array([.string("serial"), .string("gdb")]))
    #expect(r?["prefer"] == .array([.string("net_fast")]))
    #expect(
      r?["resources"]
        == .object(["cpus": .number(4), "memoryGB": .number(8), "diskGB": .number(40)]))
    #expect(r?["network"]?["segment"] == .string("lab"))
    #expect(
      r?["network"]?["forwards"]
        == .array([
          .object(["guest": .number(22)]),
          .object(["guest": .number(8080), "host": .number(18080)]),
        ]))
    #expect(r?["image"] == .string("debian-13-arm64"))
    // The handler accepts what the CLI builds.
    _ = try ToolArguments(arguments, spec: ToolCatalog.spec(named: "vm_plan")!)
    _ = try Requirements.decode(json: r!.data)
  }

  @Test func planTakesRawRequirementsJSON() throws {
    let command = try PlanCommand.parse([
      "--requirements", #"{"guest":{"os":"macos","arch":"arm64"}}"#,
    ])
    #expect(try command.arguments()["requirements"]?["guest"]?["os"] == .string("macos"))
  }

  @Test func planRefusesMissingOrConflictingInput() {
    #expect(throws: (any Error).self) { try PlanCommand.parse([]) }
    #expect(throws: (any Error).self) {
      try PlanCommand.parse(["--guest", "linux", "--requirements", "{}"])
    }
    #expect(throws: (any Error).self) {
      try PlanCommand.parse(["--guest", "linux", "--forward", "a:b"]).arguments()
    }
  }

  @Test func otherCommandsBuildTheirToolArguments() throws {
    #expect(
      try ListCommand.parse(["--state", "running"]).arguments()
        == .object(["state": .string("running")]))
    #expect(try InspectCommand.parse(["web"]).arguments() == .object(["vm": .string("web")]))
    #expect(try DoctorCommand.parse(["--probe"]).arguments() == .object(["probe": .bool(true)]))
    #expect(
      try LogsCommand.parse(["web", "--source", "events", "--tail", "5"]).arguments()
        == .object(["vm": .string("web"), "source": .string("events"), "tail": .number(5)]))
    #expect(try FactsCommand.parse([]).arguments() == .object([:]))
    #expect(
      try IntrospectCommand.parse(["web", "raw", "--hmp", "info mtree"]).arguments()
        == .object(["vm": .string("web"), "query": .string("raw"), "hmp": .string("info mtree")]))
    #expect(
      try MemoryDumpCommand.parse(["web", "--address", "0x40000000", "--size", "4096"])
        .arguments()
        == .object([
          "vm": .string("web"), "address": .string("0x40000000"), "size": .number(4096),
        ]))
    #expect(
      try MemoryDumpCommand.parse(["web", "--local", "/tmp/ram.elf"]).arguments()
        == .object(["vm": .string("web"), "local": .string("/tmp/ram.elf")]))
    for command in [
      FactsCommand.self, DoctorCommand.self, PlanCommand.self, ListCommand.self,
      InspectCommand.self, LogsCommand.self, IntrospectCommand.self, MemoryDumpCommand.self,
    ] as [any ToolCommand.Type] {
      #expect(ToolHandlers.handler(named: command.toolName) != nil)
    }
  }

  /// P3: `vmlab checkpoint <vm> diff --from a --to b` passes vm_checkpoint's from and to.
  @Test func checkpointDiffTakesFromAndTo() throws {
    #expect(
      try CheckpointCommand.parse(["web", "diff", "--from", "base", "--to", "@now"]).arguments()
        == .object([
          "vm": .string("web"), "action": .string("diff"), "from": .string("base"),
          "to": .string("@now"),
        ]))
  }

  @Test func versionIsThePackageVersion() {
    #expect(VMLab.configuration.version == VMLabMCP.version)
  }
}
