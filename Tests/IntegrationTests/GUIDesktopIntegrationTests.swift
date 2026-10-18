import Foundation
import Testing
import VMLabCore
import VMLabEngines
import VMLabQEMU
import VMLabRFB

@testable import VMLabMCP

/// R-504 and R-502 Verify (integration): a `qemu-hvf` Debian guest planned with `gui_desktop`
/// installs Xfce on first boot and shows it through QEMU's VNC; `vm_computer` then clicks the
/// panel's terminal launcher and types a command, and after a reboot the desktop is back fast.
@Suite struct GUIDesktopIntegrationTests {
  /// Whether `frame` looks like a desktop rather than a text console: most pixels lit.
  static func litFraction(_ frame: Framebuffer) -> Double {
    var lit = 0
    let pixels = frame.pixels
    var i = 0
    while i < pixels.count {
      if pixels[i] > 40 || pixels[i + 1] > 40 || pixels[i + 2] > 40 { lit += 1 }
      i += 4
    }
    return Double(lit) / Double(max(1, frame.width * frame.height))
  }

  static func debugDir() -> URL? {
    ProcessInfo.processInfo.environment["VMLAB_DEBUG_DIR"].map { URL(filePath: $0) }
  }

  /// Polls the VNC screen until it shows a desktop or `timeout` passes; returns the elapsed time.
  static func waitForDesktop(_ guest: QEMUGuest, timeout: Duration, tag: String) async throws
    -> Duration
  {
    let started = ContinuousClock.now
    var shot = 0
    while ContinuousClock.now - started < timeout {
      if let client = try? await RFBClient.connect(.unix(path: guest.machine.layout.vncSocket.path))
      {
        await client.start()
        try? await client.waitForUpdate(timeout: .seconds(5))
        let frame = await client.framebuffer
        await client.close()
        let lit = litFraction(frame)
        if let dir = debugDir() {
          shot += 1
          try? frame.pngData().write(to: dir.appending(path: "\(tag)-\(shot).png"))
          print(
            "[\(tag)] \(ContinuousClock.now - started): \(frame.width)x\(frame.height) lit \(lit)")
        }
        if lit > 0.5 { return ContinuousClock.now - started }
      }
      try await Task.sleep(for: .seconds(10))
    }
    let tail = await guest.machine.serial.read(tail: 40).text
    Issue.record("no desktop within \(timeout) (\(tag)); serial tail:\n\(tail)")
    throw VMLabError(code: .timeout, message: "no desktop", hint: "")
  }

  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(20)))
  func desktopInstallsAndVMComputerDrivesIt() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .gui, .guiDesktop, .netNAT], requested: [.gui, .guiDesktop],
      memoryGB: 4, diskGB: 12, sshKey: true)
    do {
      // R-504: the desktop within 10 minutes of first boot.
      let first = try await Self.waitForDesktop(guest, timeout: .seconds(600), tag: "first")
      print("desktop after first boot: \(first)")

      // R-502: vm_computer over the same display.
      var context = ToolContext(
        home: guest.home,
        displays: DisplaySessions(connectors: DisplayConnectorRegistry(RFBDisplayConnector())))
      context.progress = .none
      func computer(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        var arguments = arguments
        arguments["vm"] = .string(guest.record.id)
        return try await ToolHandlers.call(
          "vm_computer", arguments: .object(arguments), context: context)
      }
      try await Task.sleep(for: .seconds(15))  // let the panel and its launchers settle
      try await GUIComputerSteps.clickTerminalAndType(
        computer: computer, serial: guest.machine.serial)

      // R-504: a second boot shows the desktop within 90 s.
      _ = try await guest.manager.perform(.stop, on: guest.record.id)
      _ = try await guest.manager.perform(.start, on: guest.record.id)
      let second = try await Self.waitForDesktop(guest, timeout: .seconds(90), tag: "second")
      print("desktop after second boot: \(second)")
      #expect(second < .seconds(90))
      // The server's display session reconnects to the restarted QEMU's VNC socket.
      let again = try await computer(["action": .string("screenshot")])
      #expect(again.images.count == 1)
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}

/// The R-502 steps on the Xfce desktop.
enum GUIComputerSteps {
  typealias Computer = ([String: JSONValue]) async throws -> ToolResult

  static func save(_ result: ToolResult, _ name: String) {
    guard let dir = GUIDesktopIntegrationTests.debugDir(), let image = result.images.first else {
      return
    }
    try? image.data.write(to: dir.appending(path: name))
  }

  /// The terminal launcher in Xfce's default bottom dock on QEMU's 800x600 ramfb screen.
  static let terminalLauncher = (x: 327, y: 576)

  /// Clicks the dock's terminal launcher, types a command that writes a marker to the serial
  /// console, and checks the screen changed in the terminal's region.
  static func clickTerminalAndType(
    computer: Computer, serial: SerialChannel
  ) async throws {
    let before = try await computer(["action": .string("screenshot")])
    save(before, "computer-0.png")
    #expect(before.value["width"] == .number(800) && before.value["height"] == .number(600))
    #expect(before.images.first?.mimeType == "image/png")
    let info = try await computer(["action": .string("screen_info")])
    #expect(info.value["width"] == .number(800))

    let clicked = try await computer([
      "action": .string("left_click"),
      "coordinate": .array([
        .number(Double(terminalLauncher.x)), .number(Double(terminalLauncher.y)),
      ]),
      "settleMs": .number(4000),
    ])
    save(clicked, "computer-1-clicked.png")
    let cursor = try await computer(["action": .string("cursor_position")])
    #expect(cursor.value["x"] == .number(Double(terminalLauncher.x)))

    let since = await serial.read(tail: 0).offset
    let typed = try await computer([
      "action": .string("type"), "text": .string("echo vmlab-gui-ok | sudo tee /dev/ttyAMA0\n"),
      "settleMs": .number(2000),
    ])
    save(typed, "computer-2-typed.png")
    _ = try await serial.wait(for: "vmlab-gui-ok", since: since, timeout: .seconds(30))

    // New pixels in the terminal region: the screen differs from the one before the click.
    let diff = try await computer([
      "action": .string("screenshot"), "diffFrom": before.value["id"] ?? .null,
    ])
    #expect(diff.value["unchanged"] == .bool(false))
    let region = try #require(diff.value["changedRegion"])
    let width = region["width"]?.numberValue ?? 0
    let height = region["height"]?.numberValue ?? 0
    #expect(width > 100 && height > 100, "changed region \(region)")
    save(diff, "computer-3-diff.png")

    // zoom on the terminal at full resolution.
    let zoom = try await computer([
      "action": .string("zoom"),
      "region": .array([
        region["x"] ?? .number(0), region["y"] ?? .number(0),
        .number((region["x"]?.numberValue ?? 0) + width),
        .number((region["y"]?.numberValue ?? 0) + height),
      ]),
    ])
    #expect(zoom.value["scale"] == .number(1))
    #expect(zoom.images.count == 1)
  }
}
