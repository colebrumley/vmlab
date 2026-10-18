/// One of the four ways vmlab can run a guest (Appendix B). A model never names one; the selector
/// picks it from the features asked for.
public enum Profile: String, CaseIterable, Codable, Sendable, Comparable {
  case vzMacOS = "vz-macos"
  case vzLinux = "vz-linux"
  case qemuHVF = "qemu-hvf"
  case qemuTCG = "qemu-tcg"

  /// Relative speed of the guest; 1 is best (Appendix B).
  public var performanceTier: Int {
    switch self {
    case .vzMacOS, .vzLinux: 1
    case .qemuHVF: 2
    case .qemuTCG: 4
    }
  }

  /// Relative host energy cost; 1 is best (Appendix B).
  public var energyTier: Int {
    switch self {
    case .vzMacOS, .vzLinux: 1
    case .qemuHVF: 2
    case .qemuTCG: 3
    }
  }

  /// Relative time to a booted guest; 1 is best (Appendix B).
  public var startupTier: Int {
    switch self {
    case .vzLinux, .qemuHVF: 1
    case .vzMacOS: 2
    case .qemuTCG: 3
    }
  }

  /// Whether the profile runs on Virtualization.framework (ties in ranking go to VZ, Appendix I).
  public var isVZ: Bool { self == .vzMacOS || self == .vzLinux }

  /// Declaration order, so that sorted profiles read as Appendix B's columns.
  public static func < (lhs: Profile, rhs: Profile) -> Bool {
    allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
  }
}
