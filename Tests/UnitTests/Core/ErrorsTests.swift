import Foundation
import Testing
import VMLabCore

@Suite struct ErrorsTests {
  @Test func codesMatchAppendixD() {
    #expect(
      ErrorCode.allCases.map(\.rawValue) == [
        "invalid_request", "unsatisfiable", "unverified_capability", "capability_missing",
        "vm_not_found", "wrong_state", "limit_macos_guests", "limit_memory", "host_missing_tool",
        "image_not_found", "confirm_required", "timeout", "guest_unreachable", "provision_failed",
        "debug_busy", "engine_error", "internal",
      ])
  }

  @Test func errorRoundTripsAsJSON() throws {
    let error = VMLabError(
      code: .limitMemory, message: "m", hint: "h",
      data: ["requestedGB": .number(8), "list": .array([.string("a"), .bool(true), .null])])
    let decoded = try JSONDecoder().decode(VMLabError.self, from: try JSONEncoder().encode(error))
    #expect(decoded == error)
  }
}
