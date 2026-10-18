import Foundation
import Testing
import VMLabCore
import VMLabMCP

@testable import vmlab

/// `vmlab create`, the lifecycle subcommands and `vmlab images` build the tools' JSON arguments.
@Suite struct LifecycleCommandsTests {
  @Test func createTakesThePlanFlags() throws {
    let command = try CreateCommand.parse([
      "--guest", "linux", "--require", "serial", "--name", "web", "--no-start", "--json",
    ])
    #expect(command.json)
    let arguments = try command.arguments()
    #expect(arguments["name"] == .string("web"))
    #expect(arguments["autostart"] == .bool(false))
    #expect(arguments["requirements"]?["require"] == .array([.string("serial")]))
    #expect(arguments["allowUnverified"] == nil)
  }

  @Test func createNeedsAGuest() {
    #expect(throws: (any Error).self) { try CreateCommand.parse(["--name", "web"]) }
  }

  @Test func lifecycleSubcommandsNameTheirAction() throws {
    #expect(
      try StartCommand.parse(["web"]).arguments()
        == .object(["vm": .string("web"), "action": .string("start")]))
    #expect(try StopCommand.parse(["web"]).arguments()["action"] == .string("stop"))
    #expect(try KillCommand.parse(["web"]).arguments()["action"] == .string("kill"))
    #expect(try PauseCommand.parse(["web"]).arguments()["action"] == .string("pause"))
    #expect(try ResumeCommand.parse(["web"]).arguments()["action"] == .string("resume"))
    #expect(try ResetCommand.parse(["web"]).arguments()["action"] == .string("reset"))
    #expect(
      try DestroyCommand.parse(["web", "--force"]).arguments()
        == .object(["vm": .string("web"), "action": .string("destroy"), "force": .bool(true)]))
    #expect(StartCommand.toolName == "vm_lifecycle")
  }

  @Test func imagesSubcommandsCallTheImagesTool() throws {
    #expect(
      try Images.Pull.parse(["debian-13-arm64"]).arguments()
        == .object(["action": .string("pull"), "name": .string("debian-13-arm64")]))
    #expect(try Images.List.parse([]).arguments() == .object(["action": .string("list")]))
    #expect(try Images.Remove.parse(["x"]).arguments()["action"] == .string("remove"))
  }
}
