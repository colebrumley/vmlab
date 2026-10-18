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
}
