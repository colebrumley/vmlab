import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP
@testable import vmlab

@Suite struct ComputerTests {
  @Test func flagsBecomeVMComputerArguments() throws {
    let command = try ComputerCommand.parse([
      "desk", "left_click_drag", "--from", "1,2", "--at", "30, 40", "--settle-ms", "0",
      "--out", "/tmp/x.png",
    ])
    #expect(
      try command.arguments()
        == .object([
          "vm": .string("desk"), "action": .string("left_click_drag"),
          "startCoordinate": .array([.number(1), .number(2)]),
          "coordinate": .array([.number(30), .number(40)]), "settleMs": .number(0),
        ]))
    // Every flag names a field of the tool's schema.
    let properties = ToolSpec.vmComputer.inputSchema["properties"]?.objectValue ?? [:]
    let all = try ComputerCommand.parse([
      "d", "scroll", "--at", "1,1", "--direction", "up", "--amount", "2", "--region", "0,0,5,5",
      "--seconds", "1", "--max-edge", "640", "--format", "jpeg", "--text", "a",
    ]).arguments()
    for key in all.objectValue?.keys ?? [:].keys { #expect(properties[key] != nil, "\(key)") }
    #expect(throws: (any Error).self) {
      try ComputerCommand.parse(["d", "x", "--at", "1"]).arguments()
    }
  }
}
