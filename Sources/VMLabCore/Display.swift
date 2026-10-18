import Foundation
import Synchronization

// MARK: - Display endpoint per profile (R-503)

extension DisplayEndpoint {
  /// The port of the in-guest VNC server (VZ Linux, R-504) and of macOS Screen Sharing (R-606).
  public static let guestVNCPort = 5900
  /// The file in the VM directory that holds the in-guest VNC password.
  public static let passwordFileName = "vnc.pass"

  /// The features that ask for a display.
  static let displayFeatures: [Feature] = [.gui, .guiPreboot, .guiDesktop]

  /// Where `record`'s screen is served, or nil when it has none right now.
  ///
  /// - QEMU: the built-in VNC unix socket, present whenever the guest runs, from the first
  ///   firmware frame; it survives a crash of the guest's display stack (`hostSide`).
  /// - VZ Linux: the in-guest VNC server on the NAT address, port 5900, with the password in
  ///   `<vm>/vnc.pass`; only when the plan requested `gui` (R-504 provisions it) and the guest's
  ///   address is known.
  /// - VZ macOS: the guest's Screen Sharing on the same terms (R-606).
  public static func forVM(_ record: VMRecord, vmDirectory: URL) -> DisplayEndpoint? {
    guard let runtime = record.runtime else { return nil }
    switch record.profile {
    case .qemuHVF, .qemuTCG:
      guard let socket = runtime.vncSocket else { return nil }
      return DisplayEndpoint(address: .unixSocket(path: socket), auth: .none, hostSide: true)
    case .vzLinux, .vzMacOS:
      guard isProvisioned(record), let ip = runtime.ip else { return nil }
      return DisplayEndpoint(
        address: .tcp(host: ip, port: guestVNCPort),
        auth: .vncPassword(file: vmDirectory.appending(path: passwordFileName).path),
        hostSide: false)
    }
  }

  /// Whether `record`'s profile serves a display for it at all: always on QEMU; on VZ Linux when
  /// the plan provisions the desktop and its VNC server (`Plan.provisionsDesktop`, R-504); on VZ
  /// macOS when the plan requested one of the display features.
  public static func isProvisioned(_ record: VMRecord) -> Bool {
    switch record.profile {
    case .qemuHVF, .qemuTCG: true
    case .vzLinux: record.plan?.provisionsDesktop ?? false
    case .vzMacOS: displayFeatures.contains { record.plan?.requests($0) ?? false }
    }
  }

  /// `forVM`, or why there is no display: `capability_missing` when the VM was not planned with
  /// one, `wrong_state` when it is not running or paused, `guest_unreachable` when the guest has
  /// not brought it up yet.
  public static func resolve(_ record: VMRecord, vmDirectory: URL) throws(VMLabError)
    -> DisplayEndpoint
  {
    guard isProvisioned(record) else {
      throw VMLabError(
        code: .capabilityMissing,
        message: "VM \(record.id) (\(record.profile.rawValue)) was not planned with gui, so it "
          + "has no display",
        hint: "Recreate the VM with require: [\"gui\"]; on \(record.profile.rawValue) that "
          + "provisions the guest's VNC server.",
        data: [
          "feature": .string("gui"), "profile": .string(record.profile.rawValue),
          "vm": .string(record.id), "channel": .string("display"),
          "anyOf": .array(displayFeatures.map { .string($0.rawValue) }),
        ])
    }
    guard record.state.isLive else {
      throw VMLabError(
        code: .wrongState,
        message: "VM \(record.id) is \(record.state.rawValue); its display is "
          + "served only while it runs",
        hint: "Start it with vm_lifecycle action: start.",
        data: [
          "vm": .string(record.id), "state": .string(record.state.rawValue),
          "legalActions": .array(
            Lifecycle.legalActions(in: record.state).map { .string($0.rawValue) }),
        ])
    }
    guard let endpoint = forVM(record, vmDirectory: vmDirectory) else {
      throw VMLabError(
        code: .guestUnreachable,
        message: "VM \(record.id)'s display is not available yet",
        hint: "The guest has not finished booting (or reported its address); wait and retry.",
        data: ["vm": .string(record.id), "channel": .string("display")])
    }
    return endpoint
  }

  /// The endpoint as `vm_inspect` shows it.
  public var json: JSONValue {
    var object: [String: JSONValue] = ["kind": .string("vnc"), "hostSide": .bool(hostSide)]
    switch address {
    case .unixSocket(let path): object["address"] = .string("unix:\(path)")
    case .tcp(let host, let port): object["address"] = .string("\(host):\(port)")
    }
    switch auth {
    case .none: object["auth"] = .string("none")
    case .vncPassword(let file):
      object["auth"] = .string("vnc_password")
      object["passwordFile"] = .string(file)
    }
    return .object(object)
  }
}

// MARK: - Display sessions (R-502)

/// A rectangle in guest pixels: origin at the top left, rows downward.
public struct DisplayRect: Codable, Sendable, Hashable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  /// The rectangle between corners `[x0, y0]` and `[x1, y1]` (exclusive), as tool arguments give it.
  public init(corners x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
    self.init(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
  }

  public var json: JSONValue {
    .object([
      "x": .number(Double(x)), "y": .number(Double(y)), "width": .number(Double(width)),
      "height": .number(Double(height)),
    ])
  }
}

/// The image encodings a screenshot can be returned in.
public enum DisplayImageFormat: String, Codable, Sendable, CaseIterable {
  case png, jpeg
}

/// How a screenshot is cropped, scaled and encoded (R-505).
public struct ScreenshotRequest: Sendable, Hashable {
  public static let defaultMaxEdge = 1280
  public static let defaultQuality = 80

  public var format: DisplayImageFormat
  /// JPEG quality 1 to 100; ignored for PNG.
  public var quality: Int
  /// The long edge of the returned image; nil keeps full resolution (zoom). Never upscales.
  public var maxEdge: Int?
  /// The part of the screen to return; nil is the whole screen.
  public var region: DisplayRect?
  /// An earlier screenshot's id: return only what changed since.
  public var diffFrom: String?

  public init(
    format: DisplayImageFormat = .png, quality: Int = Self.defaultQuality,
    maxEdge: Int? = Self.defaultMaxEdge, region: DisplayRect? = nil, diffFrom: String? = nil
  ) {
    self.format = format
    self.quality = quality
    self.maxEdge = maxEdge
    self.region = region
    self.diffFrom = diffFrom
  }
}

/// One screenshot: the image the model sees and where it sits on the guest screen.
public struct ScreenCapture: Sendable, Hashable {
  /// The id a later screenshot may name in `diffFrom`.
  public var id: String
  /// The guest screen size in pixels (unscaled).
  public var width: Int
  public var height: Int
  /// Image pixels per guest pixel: guest = frame origin + image / scale.
  public var scale: Double
  /// The encoded image; nil when `unchanged`.
  public var image: Data?
  public var mimeType: String?
  /// With `diffFrom`: the guest rectangle the image shows; nil without it.
  public var changedRegion: DisplayRect?
  /// With `diffFrom`: nothing changed and no image is returned.
  public var unchanged: Bool

  public init(
    id: String, width: Int, height: Int, scale: Double, image: Data?, mimeType: String?,
    changedRegion: DisplayRect? = nil, unchanged: Bool = false
  ) {
    self.id = id
    self.width = width
    self.height = height
    self.scale = scale
    self.image = image
    self.mimeType = mimeType
    self.changedRegion = changedRegion
    self.unchanged = unchanged
  }
}

/// Pointer buttons held during a pointer event. Wheel buttons are pressed and released to scroll
/// one notch (RFB and X11 convention).
public struct DisplayButtons: OptionSet, Sendable, Hashable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let left = DisplayButtons(rawValue: 1 << 0)
  public static let middle = DisplayButtons(rawValue: 1 << 1)
  public static let right = DisplayButtons(rawValue: 1 << 2)
  public static let wheelUp = DisplayButtons(rawValue: 1 << 3)
  public static let wheelDown = DisplayButtons(rawValue: 1 << 4)
  public static let wheelLeft = DisplayButtons(rawValue: 1 << 5)
  public static let wheelRight = DisplayButtons(rawValue: 1 << 6)
}

/// An open connection to one guest display: screenshots and input. The engine-side
/// implementation (RFB) lives outside Core; the MCP layer holds one per VM.
public protocol DisplaySession: Sendable {
  /// The current guest screen size in pixels.
  func screenSize() async throws(VMLabError) -> (width: Int, height: Int)
  func screenshot(_ request: ScreenshotRequest) async throws(VMLabError) -> ScreenCapture
  /// Moves the pointer to (`x`, `y`) in guest pixels with `buttons` held.
  func pointer(x: Int, y: Int, buttons: DisplayButtons) async throws(VMLabError)
  /// Strikes a key or chord in xdotool spelling: `Return`, `ctrl+c`, `cmd+shift+4`.
  func press(_ chord: String) async throws(VMLabError)
  /// Types `text` one character at a time.
  func type(_ text: String) async throws(VMLabError)
  func close() async
}

/// Opens display sessions on endpoints.
public protocol DisplayConnector: Sendable {
  func connect(_ endpoint: DisplayEndpoint) async throws(VMLabError) -> any DisplaySession
}

/// The display connector this process uses; `vmlab` registers the RFB one at startup.
public final class DisplayConnectorRegistry: Sendable {
  private let current = Mutex<(any DisplayConnector)?>(nil)

  public init(_ connector: (any DisplayConnector)? = nil) {
    current.withLock { $0 = connector }
  }

  public func register(_ connector: any DisplayConnector) {
    current.withLock { $0 = connector }
  }

  /// The registered connector; `internal` when this build registered none.
  public func connector() throws(VMLabError) -> any DisplayConnector {
    guard let connector = current.withLock({ $0 }) else {
      throw VMLabError(
        code: .internal, message: "No display connector is registered in this process",
        hint: "This vmlab build cannot reach guest displays; run vmlab doctor.")
    }
    return connector
  }
}

public enum Displays {
  public static let shared = DisplayConnectorRegistry()
}
