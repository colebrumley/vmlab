import Foundation
import Testing
import VMLabCore
import VMLabMCP

@testable import vmlab

/// `vmlab debug` builds `vm_debug`'s arguments and renders its results.
@Suite struct DebugCommandTests {
  @Test func buildsTheToolArguments() throws {
    let command = try DebugCommand.parse([
      "web", "breakpoint_add", "--address", "0x1000", "--kind", "watch_write", "--size", "8",
      "--timeout", "5", "--thread", "p01.02", "--symbol-file", "/tmp/vmlinux",
    ])
    #expect(
      try command.arguments()
        == .object([
          "vm": .string("web"), "action": .string("breakpoint_add"), "address": .string("0x1000"),
          "kind": .string("watch_write"), "size": .number(8), "timeoutSeconds": .number(5),
          "thread": .string("p01.02"), "symbolFile": .string("/tmp/vmlinux"),
        ]))
    #expect(DebugCommand.toolName == "vm_debug")
  }

  @Test func rendersStopsAndRegisters() throws {
    let command = try DebugCommand.parse(["web", "registers"])
    let text = command.render(
      ToolResult([
        "stopped": .bool(true), "reason": .string("breakpoint"), "pc": .string("0x10"),
        "registers": .object(["pc": .string("0x10"), "v0": .null]),
      ]))
    #expect(text.contains("stopped (breakpoint) at 0x10"))
    #expect(text.contains("v0      unavailable"))
  }
}
