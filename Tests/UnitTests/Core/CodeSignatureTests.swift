import Foundation
import Testing
import VMLabCore

@Suite struct CodeSignatureTests {
  static func fixture(_ name: String) throws -> String {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Fixtures/codesign/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
  }

  @Test(arguments: ["vmlab-vz-signed.txt", "vmlab-vz-signed.xml"])
  func signedRunnerCarriesTheEntitlement(fixture: String) throws {
    let output = try Self.fixture(fixture)
    #expect(CodeSignature.hasVirtualizationEntitlement(codesignOutput: output))
    #expect(
      CodeSignature.grantedEntitlements(inCodesignOutput: output) == [
        CodeSignature.virtualizationEntitlement
      ])
  }

  @Test func unsignedBinaryHasNone() throws {
    let output = try Self.fixture("unsigned.txt")
    #expect(CodeSignature.grantedEntitlements(inCodesignOutput: output).isEmpty)
    #expect(!CodeSignature.hasVirtualizationEntitlement(codesignOutput: output))
  }

  @Test func falseValueIsNotGranted() throws {
    let output = try Self.fixture("virtualization-false.txt")
    #expect(
      CodeSignature.grantedEntitlements(inCodesignOutput: output) == [
        "com.apple.security.network.client"
      ])
  }
}
