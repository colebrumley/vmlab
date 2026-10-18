import Foundation
import Testing
import VMLabCore
import VMLabMCP

@testable import vmlab

/// `vmlab images register` builds the images tool's register arguments (R-1002).
@Suite struct ImagesCommandTests {
  @Test func registerFormsBecomeToolArguments() throws {
    let disk = try Images.Register.parse([
      "deb", "--disk", "/tmp/d.raw", "--guest", "linux", "--arch", "arm64", "--format", "raw",
    ]).arguments()
    #expect(
      disk
        == .object([
          "action": .string("register"), "name": .string("deb"), "path": .string("/tmp/d.raw"),
          "guest": .string("linux"), "arch": .string("arm64"), "format": .string("raw"),
        ]))
    let ipsw = try Images.Register.parse(["--ipsw", "/tmp/Restore.ipsw"]).arguments()
    #expect(
      ipsw == .object(["action": .string("register"), "path": .string("/tmp/Restore.ipsw")]))
    let kernel = try Images.Register.parse(["k", "--kernel", "/tmp/Image"]).arguments()
    #expect(kernel["kernel"] == .string("/tmp/Image") && kernel["arch"] == .string("arm64"))
    #expect(throws: (any Error).self) { try Images.Register.parse(["x"]) }
    #expect(throws: (any Error).self) {
      try Images.Register.parse(["x", "--disk", "/a", "--ipsw", "/b.ipsw"])
    }
    #expect(throws: (any Error).self) { try Images.Register.parse(["--disk", "/a"]) }
  }
}
