import Foundation
import Testing

@testable import VMLabCore

/// R-503: which display endpoint each profile serves, and when it has none.
@Suite struct DisplayTests {
  static let dir = URL(filePath: "/tmp/vmlab-test/vms/vm-aaaaaa")

  static func record(
    _ profile: Profile, requested: [Feature], plan: Bool = true, state: VMState = .running,
    ip: String? = "192.168.64.7"
  ) -> VMRecord {
    let guest = GuestSpec(os: profile == .vzMacOS ? .macos : .linux, arch: .arm64)
    let features = Feature.allCases.filter {
      Capabilities.entry($0, on: profile).availability == .yes
    }
    var record = VMRecord(
      id: "vm-aaaaaa", profile: profile, guest: guest, features: features, state: state,
      runtime: state.isLive
        ? VMRuntime(
          pid: 1, controlSocket: "/tmp/c.sock", vncSocket: "/tmp/v.sock", ip: ip) : nil)
    if plan {
      record.plan = Plan(
        profile: profile, guest: guest, resources: ResourceSpec(), features: features,
        requested: requested, estimatedStartupSeconds: 0)
    }
    return record
  }

  @Test(arguments: [Profile.vzLinux, .vzMacOS])
  func vzEndpointIsAbsentWhenGUIWasNotRequired(profile: Profile) throws {
    // `gui` is granted (a `yes` in the matrix) but was not asked for.
    let record = Self.record(profile, requested: [.serial])
    #expect(record.features.contains(.gui))
    #expect(DisplayEndpoint.forVM(record, vmDirectory: Self.dir) == nil)
    let error = #expect(throws: VMLabError.self) {
      try DisplayEndpoint.resolve(record, vmDirectory: Self.dir)
    }
    #expect(error?.code == .capabilityMissing)
    #expect(error?.data["feature"] == .string("gui"))
    // A record from before `Plan.requested` (or without a plan) has no VZ display either.
    #expect(
      DisplayEndpoint.forVM(Self.record(profile, requested: [], plan: false), vmDirectory: Self.dir)
        == nil)
  }

  @Test func vzLinuxWithGUIServesTheInGuestVNCServer() throws {
    let endpoint = try DisplayEndpoint.resolve(
      Self.record(.vzLinux, requested: [.gui]), vmDirectory: Self.dir)
    #expect(endpoint.address == .tcp(host: "192.168.64.7", port: 5900))
    #expect(endpoint.auth == .vncPassword(file: Self.dir.path + "/vnc.pass"))
    #expect(endpoint.hostSide == false)
  }

  @Test func vzWithoutAnAddressYetIsUnreachable() {
    let error = #expect(throws: VMLabError.self) {
      try DisplayEndpoint.resolve(
        Self.record(.vzLinux, requested: [.guiDesktop], ip: nil), vmDirectory: Self.dir)
    }
    #expect(error?.code == .guestUnreachable)
  }

  @Test(arguments: [Profile.qemuHVF, .qemuTCG])
  func qemuAlwaysServesItsVNCSocket(profile: Profile) throws {
    for requested in [[], [Feature.gui]] {
      let endpoint = try DisplayEndpoint.resolve(
        Self.record(profile, requested: requested), vmDirectory: Self.dir)
      #expect(
        endpoint == DisplayEndpoint(address: .unixSocket(path: "/tmp/v.sock"), hostSide: true))
    }
  }

  @Test func stoppedVMHasNoDisplay() {
    let record = Self.record(.qemuHVF, requested: [.gui], state: .stopped)
    #expect(DisplayEndpoint.forVM(record, vmDirectory: Self.dir) == nil)
    let error = #expect(throws: VMLabError.self) {
      try DisplayEndpoint.resolve(record, vmDirectory: Self.dir)
    }
    #expect(error?.code == .wrongState)
  }

  @Test func inspectJSON() {
    let unix = DisplayEndpoint(address: .unixSocket(path: "/v.sock"), hostSide: true)
    #expect(
      unix.json
        == .object([
          "kind": .string("vnc"), "address": .string("unix:/v.sock"), "auth": .string("none"),
          "hostSide": .bool(true),
        ]))
    let tcp = DisplayEndpoint(
      address: .tcp(host: "10.0.0.2", port: 5900), auth: .vncPassword(file: "/p"), hostSide: false)
    guard case .object(let object) = tcp.json else {
      Issue.record("not an object")
      return
    }
    #expect(object["address"] == .string("10.0.0.2:5900"))
    #expect(object["auth"] == .string("vnc_password"))
    #expect(object["passwordFile"] == .string("/p"))
  }

  @Test func selectorRecordsRequestedFeatures() throws {
    let plan = try select(
      try Requirements(
        guest: GuestSpec(os: .linux, arch: .arm64), require: [.serial], prefer: [.gui]),
      host: SelectorTests.devHost(), running: .empty
    ).get()
    #expect(plan.requests(.gui))
    #expect(plan.requests(.serial))
    #expect(!plan.requests(.gdb))
  }

  @Test func planWithoutRequestedDecodes() throws {
    let plan = Plan(
      profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64), resources: ResourceSpec(),
      features: [.gui], requested: [.gui], estimatedStartupSeconds: 20)
    guard
      case .object(var object) = try JSONDecoder().decode(
        JSONValue.self, from: JSONEncoder().encode(plan))
    else {
      Issue.record("not an object")
      return
    }
    object["requested"] = nil
    let old = try JSONDecoder().decode(
      Plan.self, from: JSONEncoder().encode(JSONValue.object(object)))
    #expect(old.requested == [])
    #expect(old.features == [.gui])
  }
}

/// `DisplayRect(corners:)` takes model-supplied corners; it saturates instead of trapping.
@Suite struct DisplayRectOverflowTests {
  @Test func extremeCornersDoNotTrap() async {
    await #expect(processExitsWith: .success) {
      _ = DisplayRect(corners: -9_000_000_000_000_000_000, 0, 9_000_000_000_000_000_000, 10)
      _ = DisplayRect(corners: Int.min, Int.max, Int.max, Int.min)
    }
  }

  @Test func extremeCornersSaturate() {
    let rect = DisplayRect(corners: Int.min, 0, Int.max, 10)
    #expect(rect.x == Int.min && rect.width == Int.max && rect.height == 10)
    #expect(
      DisplayRect(corners: 30, 40, 10, 20) == DisplayRect(x: 10, y: 20, width: 20, height: 20))
  }
}
