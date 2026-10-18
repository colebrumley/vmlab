import Foundation

/// Reads the entitlements of a signed binary from `codesign -d --entitlements -` output, so that
/// `vmlab doctor` can say whether the VZ runner can use Virtualization.framework.
public enum CodeSignature {
  /// The one entitlement vmlab asks for (constraint C2).
  public static let virtualizationEntitlement = "com.apple.security.virtualization"

  /// Entitlements granted in `output`: keys with a `true` value, or any non-boolean value.
  /// Accepts both the bracketed format codesign prints by default and the `--xml` plist.
  public static func grantedEntitlements(inCodesignOutput output: String) -> Set<String> {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<plist") {
      return grantedEntitlements(inPlist: Data(trimmed.utf8))
    }
    var granted = Set<String>()
    var key: String?
    for raw in trimmed.split(separator: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[Key] ") {
        key = String(line.dropFirst("[Key] ".count))
      } else if let current = key, line.hasPrefix("["), !line.hasPrefix("[Value]") {
        if line != "[Bool] false" { granted.insert(current) }
        key = nil
      }
    }
    return granted
  }

  private static func grantedEntitlements(inPlist data: Data) -> Set<String> {
    guard
      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return [] }
    return Set(dict.filter { ($0.value as? Bool) ?? true }.keys)
  }

  /// Whether `output` shows the virtualization entitlement granted.
  public static func hasVirtualizationEntitlement(codesignOutput output: String) -> Bool {
    grantedEntitlements(inCodesignOutput: output).contains(virtualizationEntitlement)
  }
}
