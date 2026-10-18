import Foundation
import Testing
import VMLabCore
import VMLabRFB

@Suite struct RFBIntegrationTests {
  /// The lowest row at or below `from` with a pixel brighter than near-black, or nil.
  static func lastLitRow(_ frame: Framebuffer, from: Int = 0) -> Int? {
    var last: Int?
    for y in max(0, from)..<frame.height {
      let row = frame.pixels[(y * frame.width * 4)..<((y + 1) * frame.width * 4)]
      if row.contains(where: { $0 > 64 }) { last = y }
    }
    return last
  }

  /// R-500 Verify (integration): connect to the Debian guest's QEMU VNC socket during boot and get
  /// a non-blank image.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(3)))
  func debianBootScreenIsNotBlank() async throws {
    let guest = try await QEMUGuest.boot()
    do {
      _ = try await guest.machine.serial.wait(for: "login:", since: 0, timeout: .seconds(90))
      let client = try await RFBClient.connect(.unix(path: guest.machine.layout.vncSocket.path))
      defer { Task { await client.close() } }
      await client.start()
      try await client.requestUpdate(incremental: false)
      try await client.waitForUpdate(timeout: .seconds(10))
      let frame = await client.framebuffer
      #expect(frame.width > 0 && frame.height > 0)
      #expect(Set(frame.pixels).count > 1, "the framebuffer is a single colour")
      _ = try await client.snapshot()
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// R-501 Verify (integration): on the Debian guest's tty1 login prompt, type `debian` + Return;
  /// the next screenshot differs from the previous one in the prompt region (`Password:`).
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(3)))
  func typingAtLoginPromptShowsPassword() async throws {
    let guest = try await QEMUGuest.boot()
    do {
      _ = try await guest.machine.serial.wait(for: "login:", since: 0, timeout: .seconds(90))
      let client = try await RFBClient.connect(.unix(path: guest.machine.layout.vncSocket.path))
      defer { Task { await client.close() } }
      await client.start()
      // Give getty on tty1 a moment after the serial prompt, then take the "before" frame.
      try await Task.sleep(for: .seconds(3))
      try await client.requestUpdate(incremental: false)
      try await client.waitForUpdate(timeout: .seconds(10))
      let before = await client.framebuffer
      try await client.type("debian\n")
      try await Task.sleep(for: .seconds(2))
      try await client.requestUpdate(incremental: false)
      try await client.waitForUpdate(timeout: .seconds(10))
      let after = await client.framebuffer
      if let dir = ProcessInfo.processInfo.environment["VMLAB_DEBUG_DIR"] {
        try before.pngData().write(to: URL(filePath: dir).appending(path: "before.png"))
        try after.pngData().write(to: URL(filePath: dir).appending(path: "after.png"))
      }
      #expect(before.width == after.width && before.height == after.height)
      // The prompt region: everything below the last lit row of the login prompt (plus a margin
      // for the blinking cursor) is dark before and holds `Password:` after.
      let promptBottom = Self.lastLitRow(before) ?? 0
      #expect(promptBottom > 0, "no login prompt on tty1")
      #expect(Self.lastLitRow(after, from: promptBottom + 8) != nil, "no Password: line appeared")
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}
