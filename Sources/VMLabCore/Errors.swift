/// The Appendix D error codes. Every model-facing refusal carries one (constraint C8).
public enum ErrorCode: String, CaseIterable, Codable, Sendable {
  case invalidRequest = "invalid_request"
  case unsatisfiable
  case unverifiedCapability = "unverified_capability"
  case capabilityMissing = "capability_missing"
  case vmNotFound = "vm_not_found"
  case wrongState = "wrong_state"
  case limitMacOSGuests = "limit_macos_guests"
  case limitMemory = "limit_memory"
  case hostMissingTool = "host_missing_tool"
  case imageNotFound = "image_not_found"
  case confirmRequired = "confirm_required"
  case timeout
  case guestUnreachable = "guest_unreachable"
  case provisionFailed = "provision_failed"
  case debugBusy = "debug_busy"
  case engineError = "engine_error"
  case `internal`
}

/// A JSON value, for the machine-readable `data` of an error.
public enum JSONValue: Codable, Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension JSONValue {
  /// The member `key` of an object; nil for anything else.
  public subscript(key: String) -> JSONValue? { objectValue?[key] }

  public var objectValue: [String: JSONValue]? {
    if case .object(let object) = self { object } else { nil }
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let array) = self { array } else { nil }
  }

  public var stringValue: String? {
    if case .string(let string) = self { string } else { nil }
  }

  public var numberValue: Double? {
    if case .number(let number) = self { number } else { nil }
  }

  public var boolValue: Bool? {
    if case .bool(let bool) = self { bool } else { nil }
  }
}

/// Every error vmlab reports: `{ code, message, hint, data }` (Appendix D). Only the MCP layer
/// renders it.
public struct VMLabError: Error, Codable, Sendable, Hashable {
  public var code: ErrorCode
  public var message: String
  public var hint: String
  public var data: [String: JSONValue]

  public init(code: ErrorCode, message: String, hint: String, data: [String: JSONValue] = [:]) {
    self.code = code
    self.message = message
    self.hint = hint
    self.data = data
  }

  /// `invalid_request` with the Appendix D `data`: `field` and `reason`.
  public static func invalidRequest(field: String, reason: String, hint: String) -> VMLabError {
    VMLabError(
      code: .invalidRequest, message: "Invalid request: \(reason)", hint: hint,
      data: ["field": .string(field), "reason": .string(reason)])
  }
}
