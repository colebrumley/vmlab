import Foundation
import Testing
import VMLabCore

@Suite struct BackendTests {
  static func vm(_ features: [Feature], profile: Profile = .qemuHVF) -> FakeRunningVM {
    FakeRunningVM(
      id: "vm-abcdef", profile: profile, features: features,
      serial: SerialChannel(
        socketPath: "/nonexistent/serial.sock", logURL: URL(filePath: "/dev/null")),
      display: DisplayEndpoint(address: .tcp(host: "192.168.64.2", port: 5900), hostSide: false),
      gdb: GDBEndpoint(host: "127.0.0.1", port: 1234), introspection: FakeIntrospection(),
      exec: FakeExec(), checkpoints: FakeCheckpoints())
  }

  /// Each channel and the feature `capability_missing` must name when the plan lacks it.
  static let channelFeatures: [(String, [Feature])] = [
    ("serial", [.serial]), ("display", [.gui, .guiPreboot, .guiDesktop]), ("gdb", [.gdb]),
    ("introspection", [.introspection]), ("exec", [.execSSH, .execAgent]),
    ("checkpoints", [.checkpointDisk, .checkpointLive]), ("memory_dump", [.memoryDump]),
  ]

  static func request(_ name: String, on vm: FakeRunningVM) throws(VMLabError) {
    switch name {
    case "serial": _ = try vm.channel(.serial)
    case "display": _ = try vm.channel(.display)
    case "gdb": _ = try vm.channel(.gdb)
    case "introspection": _ = try vm.channel(.introspection)
    case "exec": _ = try vm.channel(.exec)
    case "memory_dump": _ = try vm.channel(.memoryDump)
    default: _ = try vm.channel(.checkpoints)
    }
  }

  @Test(arguments: channelFeatures)
  func channelAbsentFromPlanIsCapabilityMissing(
    channel: String, granting: [Feature]
  ) throws {
    let feature = granting[0]
    let others = Feature.allCases.filter { !granting.contains($0) }
    let vm = Self.vm(others, profile: .vzLinux)
    let error = #expect(throws: VMLabError.self) { try Self.request(channel, on: vm) }
    #expect(error?.code == .capabilityMissing)
    #expect(error?.data["feature"] == .string(feature.rawValue))
    #expect(error?.data["profile"] == .string("vz-linux"))
    #expect(error?.data["channel"] == .string(channel))
    #expect(error?.hint.contains("vm_plan") == true)
    #expect(error?.hint.contains("require") == true)

    for granted in granting { try Self.request(channel, on: Self.vm([granted])) }
  }

  @Test func grantedChannelsReturnTheBackendsHandles() async throws {
    let vm = Self.vm([.serial, .gdb, .execAgent, .gui, .introspection, .checkpointDisk])
    #expect(try vm.channel(.gdb) == GDBEndpoint(host: "127.0.0.1", port: 1234))
    #expect(try vm.channel(.display).hostSide == false)
    let result = try await vm.channel(.exec).run(ExecRequest(command: "true"))
    #expect(result.exitCode == 0)
    #expect(
      try await vm.channel(.introspection).query(.pci) == .json(.object(["query": .string("pci")])))
  }

  @Test func grantedButAbsentChannelIsGuestUnreachable() {
    var vm = Self.vm([.gui])
    vm.display = nil
    let error = #expect(throws: VMLabError.self) { try vm.channel(.display) }
    #expect(error?.code == .guestUnreachable)
  }

  @Test func gdbEndpointParsesRuntimeString() {
    #expect(
      GDBEndpoint(runtime: "tcp:127.0.0.1:1234") == GDBEndpoint(host: "127.0.0.1", port: 1234))
    #expect(GDBEndpoint(runtime: "unix:/tmp/gdb.sock") == nil)
    #expect(GDBEndpoint(runtime: "tcp::1234") == nil)
    #expect(GDBEndpoint(runtime: "tcp:host:99999") == nil)
  }

  @Test func displayEndpointRoundTrips() throws {
    let endpoint = DisplayEndpoint(
      address: .tcp(host: "192.168.64.2", port: 5900), auth: .vncPassword(file: "/x/vnc.pass"),
      hostSide: false)
    let data = try JSONEncoder().encode(endpoint)
    #expect(try JSONDecoder().decode(DisplayEndpoint.self, from: data) == endpoint)
  }

  @Test func registryLooksUpByProfile() throws {
    let registry = BackendRegistry()
    let store = Store(home: URL(filePath: "/nonexistent"))
    let error = #expect(throws: VMLabError.self) { try registry.backend(for: .qemuHVF) }
    #expect(error?.code == .internal)
    #expect(error?.data["profile"] == .string("qemu-hvf"))

    registry.register(FakeBackend(profile: .vzLinux, store: store))
    registry.register(FakeBackend(profile: .qemuHVF, store: store))
    #expect(registry.profiles == [.vzLinux, .qemuHVF])
    #expect(try registry.backend(for: .vzLinux).profile == .vzLinux)
    registry.unregister(.vzLinux)
    #expect(registry.profiles == [.qemuHVF])
  }

  @Test func registryIsThreadSafe() async {
    let registry = BackendRegistry()
    let store = Store(home: URL(filePath: "/nonexistent"))
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<200 {
        group.addTask {
          let profile = Profile.allCases[i % Profile.allCases.count]
          registry.register(FakeBackend(profile: profile, store: store))
          _ = try? registry.backend(for: profile)
          _ = registry.profiles
        }
      }
    }
    #expect(registry.profiles == Profile.allCases.sorted())
  }
}
