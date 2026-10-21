import Foundation
import Synchronization
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_create`, `vm_lifecycle` and `images` against the fake backend (R-205): a context whose
/// backends are `FakeBackend`s, whose image store serves the fixture catalogue from disk, with a
/// short heartbeat and a progress recorder.
@Suite struct VMCreateHandlerTests {
  struct Fixture {
    let context: ToolContext
    let backend: FakeBackend
    let progress = ProgressLog()

    init(
      heartbeat: Duration = .milliseconds(40), catalogue: ImageCatalogue? = nil,
      hostMemory: HostMemoryGuard? = nil
    ) throws {
      let base = try ToolHandlerTests.context()
      let (_, bin) = try ImagesTests.sandbox()
      let images = ImageStore(
        home: base.home, catalogue: try catalogue ?? ImagesTests.catalogue(),
        downloader: ImagesTests.downloader(), runner: ConvertRunner(), searchPaths: [bin.path])
      let registry = BackendRegistry()
      let backend = FakeBackend(profile: .qemuHVF, store: base.store)
      registry.register(backend)
      var context = ToolContext(
        home: base.home, probe: base.probe, backends: registry, images: images,
        startGate: StartGate(hostMemory: hostMemory))
      let progress = progress
      context.progress = ToolProgress { value, _, message in
        progress.add(value, message ?? "")
      }
      context.heartbeat = heartbeat
      self.context = context
      self.backend = backend
    }

    /// Requirements the M1 fixture host plans onto `qemu-hvf`.
    static let requirements: JSONValue = .object([
      "guest": .object(["os": .string("linux"), "arch": .string("arm64")]),
      "require": .array([.string("serial"), .string("gdb")]),
      "image": .string("tiny-arm64"),
    ])

    func create(_ extra: [String: JSONValue] = [:]) async throws(VMLabError) -> ToolResult {
      var arguments: [String: JSONValue] = [
        "requirements": Self.requirements, "allowUnverified": .bool(true), "name": .string("web"),
      ]
      arguments.merge(extra) { $1 }
      return try await ToolHandlers.call(
        "vm_create", arguments: .object(arguments), context: context)
    }

    func vmDirectories() -> [String] {
      (try? FileManager.default.contentsOfDirectory(atPath: context.store.vmsDirectory.path))?
        .filter { !$0.hasPrefix(".") } ?? []
    }

    func cleanUp() { try? FileManager.default.removeItem(at: context.home) }
  }

  final class ProgressLog: Sendable {
    private let entries = Mutex<[(value: Double, message: String)]>([])
    func add(_ value: Double, _ message: String) {
      entries.withLock { $0.append((value, message)) }
    }
    var values: [Double] { entries.withLock { $0.map(\.value) } }
    var messages: [String] { entries.withLock { $0.map(\.message) } }
  }

  @Test func slowCreateEmitsProgress() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    // Held until three heartbeats arrived (a fixed sleep starves on a busy machine).
    let progress = f.progress
    f.backend.holdCreate {
      progress.messages.count(where: { $0.hasPrefix("creating the VM (") }) >= 3
    }
    let result = try await f.create(["autostart": .bool(false)])
    #expect(result.value["state"] == .string("created"))
    #expect(result.value["plan"]?["profile"] == .string("qemu-hvf"))
    #expect(result.warnings.contains { $0.contains("pulled image tiny-arm64") })
    let messages = f.progress.messages
    #expect(messages.contains("pulling image tiny-arm64"))
    #expect(messages.contains("creating the VM"))
    // A heartbeat every 40 ms while the create is held.
    #expect(messages.count(where: { $0.hasPrefix("creating the VM (") }) >= 3)
    let values = f.progress.values
    #expect(values == values.sorted() && Set(values).count == values.count)
    #expect(f.vmDirectories().count == 1)
  }

  @Test func heartbeatStopsWhenTheCallReturns() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["autostart": .bool(false)])
    let count = f.progress.values.count
    try await Task.sleep(for: .milliseconds(200))
    #expect(f.progress.values.count == count)
  }

  @Test func cancellationLeavesNoVMDirectory() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    f.backend.delayCreate(.seconds(30))
    let call = Task { try await f.create() }
    // Cancel once the backend is creating (the directory exists).
    let deadline = ContinuousClock.now + .seconds(10)
    while f.backend.operations.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(f.vmDirectories().count == 1)
    call.cancel()
    let outcome = await call.result
    guard case .failure(let error) = outcome else {
      Issue.record("a cancelled create returned a result")
      return
    }
    #expect((error as? VMLabError)?.data["cancelled"] == .bool(true))
    #expect(f.vmDirectories().isEmpty)
    #expect(f.backend.operations == [.create, .destroy])
    #expect(try f.context.store.list().records.isEmpty)
  }

  @Test func createStartsByDefault() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let result = try await f.create()
    #expect(result.value["state"] == .string("running"))
    #expect(result.value["vm"]?["name"] == .string("web"))
    #expect(result.value["endpoints"]?["gdb"] == .string("tcp:127.0.0.1:1234"))
    #expect(f.backend.operations == [.create, .start])
    #expect(f.progress.messages.contains { $0.hasPrefix("starting vm-") })
  }

  @Test func failedAutostartDestroysTheVM() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    f.backend.fail(.start)
    let error = await #expect(throws: VMLabError.self) { try await f.create() }
    #expect(error?.code == .engineError)
    #expect(f.vmDirectories().isEmpty)
    #expect(f.backend.operations == [.create, .start, .destroy])
  }

  /// Under host memory pressure the autostart is refused with `limit_memory` before the backend
  /// starts anything, and the created VM is destroyed.
  @Test func memoryPressureRefusesTheAutostart() async throws {
    let f = try Fixture(
      hostMemory: HostMemoryGuard(
        reader: FixedHostMemory(HostMemorySnapshot(pressure: .warn, availableGB: 20))))
    defer { f.cleanUp() }
    let error = await #expect(throws: VMLabError.self) { try await f.create() }
    #expect(error?.code == .limitMemory)
    #expect(error?.data["pressureLevel"] == .string("warn"))
    #expect(f.vmDirectories().isEmpty)
    #expect(f.backend.operations == [.create, .destroy])
  }

  @Test func unsatisfiableRequestIsItsRefusal() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let requirements: JSONValue = .object([
      "guest": .object(["os": .string("linux"), "arch": .string("arm64")]),
      "require": .array([.string("rosetta"), .string("gdb")]),
    ])
    let error = await #expect(throws: VMLabError.self) {
      try await ToolHandlers.call(
        "vm_create", arguments: .object(["requirements": requirements]), context: f.context)
    }
    #expect(error?.code == .unsatisfiable)
    #expect(f.vmDirectories().isEmpty)
  }

  @Test func unknownImageIsImageNotFound() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    var requirements = Fixture.requirements.objectValue ?? [:]
    requirements["image"] = .string("no-such-image")
    let error = await #expect(throws: VMLabError.self) {
      try await f.create(["requirements": .object(requirements)])
    }
    #expect(error?.code == .imageNotFound)
    #expect(f.vmDirectories().isEmpty)
  }

  /// R-1000: an amd64 image named for an arm64 guest is refused before anything is created.
  @Test func imageForAnotherGuestIsInvalidRequest() throws {
    let arm = try Requirements(
      guest: GuestSpec(os: .linux, arch: .arm64), image: "ubuntu-24.04-amd64")
    let error = #expect(throws: VMLabError.self) {
      try VMCreateHandler.image(for: arm, catalogue: .builtin)
    }
    #expect(error?.code == .invalidRequest)
    #expect(error?.data["field"] == .string("image"))
    #expect(error?.hint.contains("x86_64") == true)
    let x86 = try Requirements(
      guest: GuestSpec(os: .linux, arch: .x86_64), image: "ubuntu-24.04-amd64")
    #expect(try VMCreateHandler.image(for: x86, catalogue: .builtin) == "ubuntu-24.04-amd64")
    // A pulled record's guest wins over the catalogue's.
    let registered = try Requirements(guest: GuestSpec(os: .linux, arch: .arm64), image: "mine")
    #expect(
      try VMCreateHandler.image(
        for: registered, catalogue: .builtin,
        guestOf: { _ in GuestSpec(os: .linux, arch: .arm64) }) == "mine")
    #expect(throws: VMLabError.self) {
      try VMCreateHandler.image(
        for: registered, catalogue: .builtin,
        guestOf: { _ in GuestSpec(os: .linux, arch: .riscv64) })
    }
  }

  /// CR-4: an image set after decoding (fleet's `image` argument) is still checked.
  @Test func anImageNameOutsideImagesIsRefused() throws {
    var requirements = try Requirements(guest: GuestSpec(os: .linux, arch: .arm64))
    requirements.image = "../../tmp/x"
    let error = #expect(throws: VMLabError.self) {
      try VMCreateHandler.image(for: requirements, catalogue: .builtin)
    }
    #expect(error?.code == .invalidRequest)
    #expect(error?.data["field"] == .string("image"))
  }

  @Test func defaultImageIsTheFirstForTheGuest() throws {
    let requirements = try Requirements(guest: GuestSpec(os: .linux, arch: .arm64))
    #expect(try VMCreateHandler.image(for: requirements, catalogue: .builtin) == "debian-13-arm64")
    let mac = try Requirements(guest: GuestSpec(os: .macos, arch: .arm64))
    #expect(try VMCreateHandler.image(for: mac, catalogue: .builtin) == "macos-base")
  }

  // MARK: R-1202: image "none"

  /// Requirements for a bare machine booting `mode` from a file under `$TMPDIR` the M1 fixture
  /// host plans onto `qemu-hvf`.
  static func bare(
    _ mode: String, require: [String] = ["serial", "gdb"], prefer: [String] = [],
    resources: [String: JSONValue]? = nil
  ) throws -> JSONValue {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "vmlab-bare-\(UUID().uuidString)")
    try Data([0]).write(to: file)
    var boot: [String: JSONValue] = ["mode": .string(mode)]
    switch mode {
    case "kernel": boot["kernel"] = .string(file.path)
    case "binary":
      boot["binary"] = .string(file.path)
      boot["loadAddress"] = .string("0x40080000")
    case "firmware": boot["firmware"] = .string(file.path)
    default: break
    }
    var object: [String: JSONValue] = [
      "guest": .object(["os": .string("linux"), "arch": .string("arm64")]),
      "require": .array(require.map { .string($0) }),
      "prefer": .array(prefer.map { .string($0) }),
      "image": .string("none"), "boot": .object(boot),
    ]
    if let resources { object["resources"] = .object(resources) }
    return .object(object)
  }

  static func arguments(_ tool: String, _ requirements: JSONValue) -> JSONValue {
    tool == "vm_create"
      ? .object(["requirements": requirements, "name": .string("b")])
      : .object(["requirements": requirements])
  }

  static func features(_ plan: JSONValue?) -> [String] {
    plan?["features"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  @Test(arguments: ["kernel", "binary", "firmware"])
  func bareMachineForEveryFileBoot(mode: String) async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let requirements = try Self.bare(mode)
    let plan = try await ToolHandlers.call(
      "vm_plan",
      arguments: .object(["requirements": requirements, "allowUnverified": .bool(true)]),
      context: f.context)
    #expect(plan.value["satisfiable"] == .bool(true))
    #expect(
      Set(Self.features(plan.value)).isDisjoint(with: Requirements.needsImage.map(\.rawValue)))
    #expect(Self.features(plan.value).contains("serial"))

    let result = try await f.create(["requirements": requirements, "autostart": .bool(false)])
    #expect(result.value["state"] == .string("created"))
    #expect(
      Set(Self.features(result.value["plan"])).isDisjoint(
        with: Requirements.needsImage.map(\.rawValue)))
    // Nothing pulled, no key.
    #expect(!result.warnings.contains { $0.contains("pulled image") })
    #expect(!f.progress.messages.contains { $0.hasPrefix("pulling image") })
    #expect(f.context.images.pulled("tiny-arm64") == nil)
    let record = try #require(try f.context.store.list().records.first)
    #expect(record.image == nil && record.isBare && record.imageName == "none")
    let data = try Data(
      contentsOf: f.context.store.directory(of: record.id).appending(path: "vm.json"))
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(json["image"] == nil)
    let directory = f.context.store.directory(of: record.id)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "id_ed25519").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appending(path: "id_ed25519.pub").path))
  }

  @Test(arguments: [nil, "disk"] as [String?])
  func bareDiskBootIsRefused(mode: String?) async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    var requirements = try Self.bare("kernel").objectValue ?? [:]
    requirements["boot"] = mode.map { .object(["mode": .string($0)]) }
    for tool in ["vm_plan", "vm_create"] {
      let error = await #expect(throws: VMLabError.self) {
        try await ToolHandlers.call(
          tool, arguments: Self.arguments(tool, .object(requirements)), context: f.context)
      }
      #expect(error?.code == .invalidRequest)
      #expect(error?.data["field"] == .string("image"))
      #expect(error?.hint == "a disk boot needs an image; set boot.mode or name an image")
    }
    #expect(f.vmDirectories().isEmpty)
  }

  @Test func bareKernelBootNeedsAKernel() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    var requirements = try Self.bare("kernel").objectValue ?? [:]
    requirements["boot"] = .object(["mode": .string("kernel")])
    let error = await #expect(throws: VMLabError.self) {
      try await f.create(["requirements": .object(requirements)])
    }
    #expect(error?.code == .invalidRequest)
    #expect(error?.data["field"] == .string("boot.kernel"))
  }

  @Test(arguments: Requirements.needsImage)
  func bareRefusesAFeatureThatNeedsAnImage(feature: Feature) async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let requirements = try Self.bare("kernel", require: ["serial", feature.rawValue])
    for tool in ["vm_plan", "vm_create"] {
      let error = await #expect(throws: VMLabError.self) {
        try await ToolHandlers.call(
          tool, arguments: Self.arguments(tool, requirements), context: f.context)
      }
      #expect(error?.code == .invalidRequest)
      #expect(error?.data["field"] == .string("require[1]"))
    }
    #expect(f.vmDirectories().isEmpty)
  }

  @Test func barePreferencesThatNeedAnImageAreDenied() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let requirements = try Self.bare(
      "kernel", prefer: ["checkpoint_live", "introspection", "exec_ssh"],
      resources: ["diskGB": .number(64)])
    let plan = try await ToolHandlers.call(
      "vm_plan",
      arguments: .object(["requirements": requirements, "allowUnverified": .bool(true)]),
      context: f.context)
    #expect(
      Set(Self.features(plan.value)).isDisjoint(with: Requirements.needsImage.map(\.rawValue)))
    #expect(Self.features(plan.value).contains("introspection"))
    #expect(
      plan.value["preferredDenied"] == .array([.string("checkpoint_live"), .string("exec_ssh")]))
    #expect(plan.value["resources"]?["diskGB"] == nil)
    let notes = plan.value["notes"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(notes.contains { $0.contains("diskGB") && $0.contains("ignored") })
  }

  /// Autostart returns once the engine is up: no SSH wait, no `ssh_unreachable`, no provisioning.
  @Test func bareAutostartDoesNotWaitForSSH() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let result = try await f.create(["requirements": try Self.bare("kernel")])
    #expect(result.value["state"] == .string("running"))
    #expect(!result.warnings.contains { $0.contains("ssh_unreachable") })
    #expect(result.value["endpoints"]?["ssh"] == nil)
    #expect(f.backend.operations == [.create, .start])
    let record = try #require(try f.context.store.list().records.first)
    let directory = f.context.store.directory(of: record.id)
    #expect(ProvisionReport.load(from: directory) == nil)
  }
}
