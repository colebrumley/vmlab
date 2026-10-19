import Foundation
import VMLabCore

/// A GDB remote serial protocol client in all-stop mode, over one transport.
///
/// Commands are serialised: one packet is in flight at a time. `cont`, `step` and `vCont` return
/// once the stub acknowledges them and leave the target `running`; `waitForStop` blocks until the
/// stop reply. While the target runs, only `interrupt` and `waitForStop` are legal.
///
/// Replies carry no tag, so the client keeps them in step with its commands: a packet that
/// arrives while no command waits (QEMU's stop reply to a debugger that stopped a running guest,
/// a stop after the wait for it gave up) is taken in before the next command goes out, a stop
/// reply that arrives while a command other than `?` waits is recorded and skipped, and a reply
/// that cannot be the command's closes the connection rather than shift every later reply.
public actor GDBClient {
  public struct Options: Sendable {
    /// How long a command waits for its ack and its reply: the dead-peer window (R-1101). A stub
    /// that misses it is dead: the client closes the connection (a late reply would be taken as
    /// the next command's), records `deadPeerReason` and calls the dead-peer handler.
    public var replyTimeout: Duration
    /// Layout used when the stub serves no `target.xml`.
    public var fallbackArchitecture: GDBArchitecture?
    /// How many times a packet is resent after the stub answers `-`.
    public var maxRetransmits: Int

    public init(
      replyTimeout: Duration = DeadPeer.window, fallbackArchitecture: GDBArchitecture? = nil,
      maxRetransmits: Int = 3
    ) {
      self.replyTimeout = replyTimeout
      self.fallbackArchitecture = fallbackArchitecture
      self.maxRetransmits = maxRetransmits
    }
  }

  public enum TargetState: Sendable, Equatable {
    case stopped
    case running
  }

  public let options: Options
  public private(set) var state = TargetState.stopped
  /// The stub's `qSupported` reply, once `handshake` ran.
  public private(set) var features: StubFeatures?
  /// The last stop, if any was seen.
  public private(set) var lastStop: StopReason?
  /// Console output (`O` packets) received while the target ran.
  public private(set) var consoleOutput: [UInt8] = []

  private let transport: any GDBTransport
  private var decoder = GDBPacketDecoder()
  private var reader: Task<Void, Never>?
  private var events: [GDBEvent] = []
  private var waiter: Waiter?
  private var nextWaiterID = 0
  private var closedError: GDBError?
  private var cachedMap: RegisterMap?
  private var busy = false
  private var queue: [CheckedContinuation<Void, Never>] = []
  /// Why the stub was declared dead (R-1101), once it was; every later call fails.
  public private(set) var deadPeerReason: String?
  private var deadPeerHandler: (@Sendable (String) async -> Void)?

  private struct Waiter {
    var id: Int
    var continuation: CheckedContinuation<GDBEvent, any Error>
    var timer: Task<Void, Never>
  }

  public init(transport: any GDBTransport, options: Options = Options()) {
    self.transport = transport
    self.options = options
  }

  deinit { reader?.cancel() }

  /// Connects over TCP and runs the `qSupported` handshake.
  public static func connect(host: String = "127.0.0.1", port: UInt16, options: Options = Options())
    async throws -> GDBClient
  {
    let transport = try await GDBTCPTransport.open(host: host, port: port)
    let client = GDBClient(transport: transport, options: options)
    _ = try await client.handshake()
    return client
  }

  public func close() async {
    closedError = closedError ?? .connectionClosed
    await transport.close()
    reader?.cancel()
  }

  /// Called once with the reason when the stub misses an ack or a reply (R-1101); the session
  /// layer marks the VM broken from it.
  public func onDeadPeer(_ handler: @escaping @Sendable (String) async -> Void) {
    deadPeerHandler = handler
  }

  /// True once the stub closed the connection (or `close` ran); every later command fails.
  public var isClosed: Bool { closedError != nil }

  // MARK: Queries

  /// `qSupported`: what the stub offers.
  public func handshake() async throws -> StubFeatures {
    let reply = try await exclusive {
      try await self.request(GDBCommand.qSupported, expecting: .any)
    }
    let parsed = StubFeatures.parse(reply)
    features = parsed
    return parsed
  }

  /// `?`: why the target is stopped.
  public func haltReason() async throws -> StopReason {
    try await exclusive {
      let reply = try await self.request(GDBCommand.haltReason, expecting: .stop)
      return try await self.recordStop(try StopReply.parse(reply))
    }
  }

  /// `vCont?`: the action letters the stub supports, or `nil` when it has no `vCont`.
  public func vContActions() async throws -> Set<String>? {
    try await exclusive {
      let reply = try await self.request(
        GDBCommand.vContQuery, expecting: .any, emptyMeansUnsupported: false)
      return parseVContActions(reply)
    }
  }

  // MARK: Execution

  /// `c`: resume. Returns once the stub acknowledged; the target is then running.
  public func cont() async throws { try await resume(GDBCommand.continue) }

  /// `s`: single-step. The stop arrives through `waitForStop`.
  public func step() async throws { try await resume(GDBCommand.step) }

  /// `vCont;...`: resume with per-thread actions.
  public func vCont(_ actions: [VContAction]) async throws {
    try await resume(GDBCommand.vCont(actions))
  }

  /// Sends the interrupt byte. The stop reply arrives through `waitForStop`. Legal at any time,
  /// but a stopped target may not answer it (QEMU ignores it), so `halt` only sends it when the
  /// target runs.
  public func interrupt() async throws {
    startReader()
    if let error = closedError { throw error }
    try await send(GDBPacket.interrupt)
  }

  /// Blocks until the target stops and returns why, with the pc resolved. When the target is
  /// already stopped it returns the last stop at once (asking `?` if none was seen yet).
  public func waitForStop(timeout: Duration) async throws -> StopReason {
    try await exclusive {
      if self.state == .stopped {
        if let last = self.lastStop { return last }
        let reply = try await self.request(GDBCommand.haltReason, expecting: .stop)
        return try await self.recordStop(try StopReply.parse(reply))
      }
      while true {
        let payload = try await self.nextPacket(timeout: timeout)
        let text = String(decoding: payload, as: UTF8.self)
        if text.count > 1, text.first == "O", let bytes = Hex.decode(text.dropFirst()) {
          self.consoleOutput.append(contentsOf: bytes)
          continue
        }
        // A refused resume (`E22` to a `vCont` naming an unknown thread) never ran the CPU.
        if let error = Self.stubError(payload) {
          self.state = .stopped
          throw error
        }
        guard StopReply.isStopReply(text) else {
          // Nothing but a stop answers a resume: a reply to some command is a lost step.
          throw await self.outOfStep("a stop reply", got: text)
        }
        return try await self.recordStop(try StopReply.parse(text))
      }
    }
  }

  /// Interrupts and waits for the stop.
  public func halt(timeout: Duration) async throws -> StopReason {
    if state == .running { try await interrupt() }
    return try await waitForStop(timeout: timeout)
  }

  /// `Hg<thread>`: the thread later `g`, `p` and `m` packets act on.
  public func selectThread(_ thread: String) async throws {
    try await exclusive { try await self.expectOK(GDBCommand.selectThread(thread)) }
  }

  // MARK: Registers

  /// `g`: the raw register block, hex as the stub sent it (`xx` marks unavailable bytes). With a
  /// `thread`, `Hg` selects it in the same exclusive section, so no other call's `Hg` intervenes.
  public func readRegistersRaw(thread: String? = nil) async throws -> String {
    try await exclusive {
      if let thread { try await self.expectOK(GDBCommand.selectThread(thread)) }
      return try await self.request(GDBCommand.readRegisters, expecting: .hex)
    }
  }

  /// `G`: writes the whole register block.
  public func writeRegisters(_ data: [UInt8]) async throws {
    try await exclusive { try await self.expectOK(GDBCommand.writeRegisters(data)) }
  }

  /// `p`: one register by number, in target byte order.
  public func readRegister(number: Int) async throws -> [UInt8] {
    try await exclusive { try await self.readRegisterLocked(number) }
  }

  /// `P`: writes one register by number.
  public func writeRegister(number: Int, value: [UInt8]) async throws {
    try await exclusive {
      try await self.expectOK(GDBCommand.writeRegister(number, value: value))
    }
  }

  /// Every register the `g` reply carries, named through the register map; of `thread` when one
  /// is given (selected atomically with the read).
  public func registers(thread: String? = nil) async throws -> [RegisterReading] {
    let map = try await registerMap()
    return try map.decode(registersReply: try await readRegistersRaw(thread: thread))
  }

  /// One register by name (`pc` and `sp` also resolve to `rip`/`rsp` on x86).
  public func register(named name: String) async throws -> RegisterValue {
    let map = try await registerMap()
    guard let register = map.register(named: name) else { throw GDBError.unknownRegister(name) }
    if let reading = try await registers().first(where: { $0.register == register }),
      let value = reading.value
    {
      return value
    }
    return RegisterValue(bytes: try await readRegister(number: register.number))
  }

  /// Writes one register by name.
  public func setRegister(named name: String, value: UInt64) async throws {
    let map = try await registerMap()
    guard let register = map.register(named: name) else { throw GDBError.unknownRegister(name) }
    let bytes = (0..<register.byteSize).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    try await writeRegister(number: register.number, value: bytes)
  }

  // MARK: Memory

  /// `m`: reads `length` bytes, in packets the stub accepts. A short read ends early only if the
  /// stub returns no bytes at all (then the error is the stub's).
  /// With a `thread`, `Hg` selects it in the same exclusive section as the reads.
  public func readMemory(address: UInt64, length: Int, thread: String? = nil) async throws
    -> [UInt8]
  {
    try await exclusive {
      if let thread { try await self.expectOK(GDBCommand.selectThread(thread)) }
      var out: [UInt8] = []
      out.reserveCapacity(length)
      while out.count < length {
        let chunk = min(length - out.count, self.maxReadChunk)
        let reply = try await self.request(
          GDBCommand.readMemory(address: address &+ UInt64(out.count), length: chunk),
          expecting: .hex)
        guard let bytes = Hex.decode(reply), !bytes.isEmpty else {
          throw GDBError.malformedReply("bad m reply: \(reply.prefix(64))")
        }
        out.append(contentsOf: bytes.prefix(chunk))
      }
      return out
    }
  }

  /// `M`: writes bytes, in packets the stub accepts.
  /// With a `thread`, `Hg` selects it in the same exclusive section as the writes.
  public func writeMemory(address: UInt64, bytes: [UInt8], thread: String? = nil) async throws {
    try await exclusive {
      if let thread { try await self.expectOK(GDBCommand.selectThread(thread)) }
      var offset = 0
      while offset < bytes.count {
        let chunk = Array(bytes[offset..<min(bytes.count, offset + self.maxWriteChunk)])
        try await self.expectOK(
          GDBCommand.writeMemory(address: address &+ UInt64(offset), bytes: chunk))
        offset += chunk.count
      }
    }
  }

  // MARK: Breakpoints and watchpoints

  /// `Z<type>`: inserts a breakpoint (`kind` is the instruction length) or a watchpoint (`kind` is
  /// the number of bytes watched).
  public func insertBreakpoint(_ type: BreakpointType, address: UInt64, kind: Int) async throws {
    try await exclusive {
      try await self.expectOK(GDBCommand.insertPoint(type, address: address, kind: kind))
    }
  }

  /// `z<type>`: removes what `insertBreakpoint` inserted (same type, address and kind).
  public func removeBreakpoint(_ type: BreakpointType, address: UInt64, kind: Int) async throws {
    try await exclusive {
      try await self.expectOK(GDBCommand.removePoint(type, address: address, kind: kind))
    }
  }

  // MARK: Target description

  /// `qXfer:features:read:<annex>`: the whole annex, or `nil` if the stub does not serve it.
  public func readFeatureAnnex(_ annex: String) async throws -> String? {
    try await exclusive { try await self.readAnnexLocked(annex) }
  }

  /// The register map: `target.xml` and its includes when the stub serves them, else the built-in
  /// layout of `options.fallbackArchitecture`. Cached after the first call.
  public func registerMap() async throws -> RegisterMap {
    if let cachedMap { return cachedMap }
    let map = try await exclusive { try await self.loadRegisterMapLocked() }
    cachedMap = map
    return map
  }

  // MARK: Internals: protocol

  private var packetSize: Int { max(features?.packetSize ?? 4096, 256) }
  /// Bytes per `m`: two hex digits each, with room for framing.
  private var maxReadChunk: Int { (packetSize - 8) / 2 }
  /// Bytes per `M`: the header (`M<addr>,<len>:`) takes up to 30 characters.
  private var maxWriteChunk: Int { (packetSize - 40) / 2 }

  private func loadRegisterMapLocked() async throws -> RegisterMap {
    if let cachedMap { return cachedMap }
    if let main = try await readAnnexLocked("target.xml") {
      var annexes: [String: String] = [:]
      var pending = try RegisterMap.includes(in: main)
      while let href = pending.popLast() {
        guard annexes[href] == nil, annexes.count < 32 else { continue }
        guard let text = try await readAnnexLocked(href) else {
          throw GDBError.badTargetDescription("stub does not serve included annex \(href)")
        }
        annexes[href] = text
        pending.append(contentsOf: try RegisterMap.includes(in: text))
      }
      return try RegisterMap.build(targetXML: main, annexes: annexes)
    }
    guard let fallback = options.fallbackArchitecture else { throw GDBError.noTargetDescription }
    return RegisterMap.builtin(fallback)
  }

  private func readAnnexLocked(_ annex: String) async throws -> String? {
    if let features, !features.supports("qXfer:features:read") { return nil }
    var data: [UInt8] = []
    let length = packetSize - 5
    while true {
      let reply: [UInt8]
      do {
        reply = try await requestBytes(
          GDBCommand.readFeatures(annex: annex, offset: data.count, length: length),
          expecting: .transfer)
      } catch GDBError.unsupported {
        return nil
      } catch GDBError.stubError where data.isEmpty {
        return nil
      }
      guard let marker = reply.first, marker == UInt8(ascii: "m") || marker == UInt8(ascii: "l")
      else {
        throw GDBError.malformedReply("bad qXfer reply")
      }
      let chunk = GDBPacket.unescape(Array(reply.dropFirst()))
      data.append(contentsOf: chunk)
      if marker == UInt8(ascii: "l") { break }
      if chunk.isEmpty { throw GDBError.malformedReply("qXfer returned no data") }
      if data.count > 4 * 1024 * 1024 { throw GDBError.malformedReply("annex too large") }
    }
    return String(decoding: data, as: UTF8.self)
  }

  private func readRegisterLocked(_ number: Int) async throws -> [UInt8] {
    let reply = try await request(GDBCommand.readRegister(number), expecting: .hex)
    guard let bytes = Hex.decode(reply) else {
      throw GDBError.malformedReply("bad p reply: \(reply.prefix(64))")
    }
    return bytes
  }

  /// Records a stop, reading the pc with `p` when the reply did not expedite it.
  private func recordStop(_ reply: StopReply) async throws -> StopReason {
    state = .stopped
    let map = try? await loadMapForStop()
    let pcNumber = map?.programCounter?.number
    var reason = StopReason(reply: reply, pcRegister: pcNumber)
    if reason.pc == nil, reply.kind == .signal, let pcNumber {
      reason.pc = try? Hex.littleEndian(await readRegisterLocked(pcNumber))
    }
    lastStop = reason
    return reason
  }

  /// The register map, loaded under the lock the caller already holds.
  private func loadMapForStop() async throws -> RegisterMap {
    if let cachedMap { return cachedMap }
    let map = try await loadRegisterMapLocked()
    cachedMap = map
    return map
  }

  private func resume(_ payload: String) async throws {
    try await exclusive {
      guard self.state == .stopped else { throw GDBError.targetRunning }
      try await self.transmit(payload)
      self.state = .running
    }
  }

  /// Commands answered `OK` (or `E nn`): `Z`, `z`, `Hg`, `M`, `G`, `P`.
  private func expectOK(_ payload: String) async throws {
    _ = try await request(payload, expecting: .ok)
  }

  private func request(
    _ payload: String, expecting shape: ReplyShape, emptyMeansUnsupported: Bool = true
  ) async throws -> String {
    let bytes = try await requestBytes(
      payload, expecting: shape, emptyMeansUnsupported: emptyMeansUnsupported)
    return String(decoding: bytes, as: UTF8.self)
  }

  /// What the reply to a command looks like, besides `E nn` and the empty packet.
  enum ReplyShape: Sendable {
    /// A stop reply (`?`).
    case stop
    /// `OK`.
    case ok
    /// Hex digits, `x` for unavailable bytes (`g`, `p`, `m`).
    case hex
    /// `m` or `l` and data (`qXfer`).
    case transfer
    /// Anything but a stop reply (`qSupported`, `vCont?`).
    case any
  }

  enum Verdict: Equatable {
    /// The command's reply.
    case reply
    /// A packet the stub sent unasked (a stop, console output): recorded, then skipped.
    case unsolicited
    /// Neither: the replies are out of step with the commands.
    case outOfStep
  }

  /// Whether `reply` answers a command whose replies have `shape`.
  static func verdict(_ reply: [UInt8], for shape: ReplyShape) -> Verdict {
    if reply.isEmpty || stubError(reply) != nil { return .reply }
    let text = String(decoding: reply, as: UTF8.self)
    if StopReply.isStopReply(text) { return shape == .stop ? .reply : .unsolicited }
    if isConsoleOutput(text) { return .unsolicited }
    switch shape {
    case .stop: return .outOfStep
    case .ok: return text == "OK" ? .reply : .outOfStep
    case .hex:
      let hex = reply.allSatisfy { Hex.nibble($0) != nil || $0 == UInt8(ascii: "x") }
      return hex ? .reply : .outOfStep
    case .transfer:
      return reply.first == UInt8(ascii: "m") || reply.first == UInt8(ascii: "l")
        ? .reply : .outOfStep
    case .any: return .reply
    }
  }

  /// An `O` packet: console output, hex after the letter (`OK` is not one).
  static func isConsoleOutput(_ text: String) -> Bool {
    text.count > 1 && text.first == "O" && Hex.decode(text.dropFirst()) != nil
  }

  /// Sends a command and returns its reply payload, mapping `E nn` and empty replies to errors.
  /// Stop replies and console output the stub sends while it waits are recorded and skipped; a
  /// packet that cannot be the reply closes the connection.
  private func requestBytes(
    _ payload: String, expecting shape: ReplyShape, emptyMeansUnsupported: Bool = true
  ) async throws -> [UInt8] {
    guard state == .stopped else { throw GDBError.targetRunning }
    try await transmit(payload)
    var reply: [UInt8]
    while true {
      reply = try await fromPeer("the reply to \(Self.name(payload))") {
        try await self.nextPacket(timeout: self.options.replyTimeout)
      }
      switch Self.verdict(reply, for: shape) {
      case .reply: break
      case .unsolicited:
        takeUnsolicited(reply)
        continue
      case .outOfStep:
        throw await outOfStep(
          "the reply to \(Self.name(payload))", got: String(decoding: reply, as: UTF8.self))
      }
      break
    }
    if reply.isEmpty {
      if emptyMeansUnsupported {
        throw GDBError.unsupported(
          packet: String(payload.prefix(while: { $0 != ":" && $0 != "," })))
      }
      return reply
    }
    if let error = Self.stubError(reply) { throw error }
    return reply
  }

  /// `Enn` or `E.message`.
  static func stubError(_ reply: [UInt8]) -> GDBError? {
    guard reply.first == UInt8(ascii: "E") else { return nil }
    let rest = String(decoding: reply.dropFirst(), as: UTF8.self)
    if rest.count == 2, let code = Int(rest, radix: 16) {
      return .stubError(code: code, message: nil)
    }
    if rest.hasPrefix(".") { return .stubError(code: -1, message: String(rest.dropFirst())) }
    return nil
  }

  /// Sends a frame and waits for the stub's `+`, resending on `-`. What the stub sent while no
  /// command waited is taken in first: on a stopped target it answers nothing of ours. A packet
  /// that arrives before the ack (QEMU's stop reply for a guest it stopped as this client
  /// connected) is kept, in order, for the reader of the reply.
  private func transmit(_ payload: String) async throws {
    startReader()
    if state == .stopped {
      while !events.isEmpty {
        if case .packet(let stray) = events.removeFirst() { takeUnsolicited(stray) }
      }
    }
    let frame = GDBPacket.frame(payload)
    var attempts = 0
    var early: [GDBEvent] = []
    defer { events.insert(contentsOf: early, at: 0) }
    while true {
      if let error = closedError { throw error }
      try await send(frame)
      var acked: Bool?
      while acked == nil {
        let event = try await fromPeer("the ack of \(Self.name(payload))") {
          try await self.nextEvent(timeout: self.options.replyTimeout)
        }
        switch event {
        case .ack: acked = true
        case .nack: acked = false
        case .packet: early.append(event)
        case .corrupt: break
        }
      }
      if acked == true { return }
      attempts += 1
      if attempts > options.maxRetransmits { throw GDBError.tooManyRetransmits }
    }
  }

  /// Records a packet the stub sent unasked: a stop becomes the last stop, console output is
  /// kept; anything else (a stale reply) is dropped.
  private func takeUnsolicited(_ payload: [UInt8]) {
    let text = String(decoding: payload, as: UTF8.self)
    if Self.isConsoleOutput(text), let bytes = Hex.decode(text.dropFirst()) {
      consoleOutput.append(contentsOf: bytes)
    } else if let reply = try? StopReply.parse(text) {
      lastStop = StopReason(reply: reply, pcRegister: cachedMap?.programCounter?.number)
    }
  }

  /// Closes the connection after a reply that cannot answer the command in flight, so no later
  /// command takes a reply meant for an earlier one; the session layer reconnects.
  private func outOfStep(_ expected: String, got text: String) async -> GDBError {
    closedError = closedError ?? .connectionClosed
    await transport.close()
    reader?.cancel()
    return GDBError.malformedReply(
      "out of step with the stub: expected \(expected), got \(text.prefix(64)); "
        + "the connection was closed to resynchronise")
  }

  /// The next packet, skipping stray acks.
  private func nextPacket(timeout: Duration) async throws -> [UInt8] {
    while true {
      if case .packet(let payload) = try await nextEvent(timeout: timeout) { return payload }
    }
  }

  // MARK: Internals: dead peer

  /// `body`, a wait bounded by `replyTimeout`; its timeout declares the stub dead.
  private func fromPeer<T: Sendable>(
    _ what: String, _ body: () async throws -> T
  ) async throws -> T {
    do {
      return try await body()
    } catch GDBError.timeout(let seconds) {
      await declareDead(DeadPeer.silence(options.replyTimeout, waitingFor: what))
      throw GDBError.timeout(seconds: seconds)
    }
  }

  private func declareDead(_ reason: String) async {
    guard deadPeerReason == nil else { return }
    deadPeerReason = reason
    closedError = .connectionClosed
    await transport.close()
    reader?.cancel()
    if let handler = deadPeerHandler { await handler(reason) }
  }

  /// A packet's command letters, without its arguments, for messages.
  static func name(_ payload: String) -> String {
    String(payload.prefix(while: { $0 != ":" && $0 != "," && $0 != ";" }).prefix(24))
  }

  // MARK: Internals: event mailbox

  private func startReader() {
    guard reader == nil else { return }
    let stream = transport.incoming
    reader = Task { [weak self] in
      do {
        for try await chunk in stream {
          guard let self else { return }
          await self.ingest(chunk)
        }
        await self?.readerEnded(.connectionClosed)
      } catch {
        await self?.readerEnded(.connectionClosed)
      }
    }
  }

  /// Decodes a chunk, acknowledges each packet before delivering it, and asks for a resend of
  /// corrupt ones.
  private func ingest(_ chunk: [UInt8]) async {
    for event in decoder.feed(chunk) {
      switch event {
      case .packet:
        try? await transport.send(GDBPacket.ack)
        deliver(event)
      case .corrupt:
        try? await transport.send(GDBPacket.nack)
      case .ack, .nack:
        deliver(event)
      }
    }
  }

  private func deliver(_ event: GDBEvent) {
    if let current = waiter {
      waiter = nil
      current.timer.cancel()
      current.continuation.resume(returning: event)
    } else {
      events.append(event)
    }
  }

  /// Writes to the stub. A write that finds the connection gone closes the client at once: the
  /// reader may not have seen end of file yet, and `isClosed` must not lag the error.
  private func send(_ bytes: [UInt8]) async throws {
    do {
      try await transport.send(bytes)
    } catch GDBError.connectionClosed {
      if closedError == nil { readerEnded(.connectionClosed) }
      throw GDBError.connectionClosed
    }
  }

  private func readerEnded(_ error: GDBError) {
    closedError = error
    if let current = waiter {
      waiter = nil
      current.timer.cancel()
      current.continuation.resume(throwing: error)
    }
  }

  private func nextEvent(timeout: Duration) async throws -> GDBEvent {
    if !events.isEmpty { return events.removeFirst() }
    if let closedError { throw closedError }
    let id = nextWaiterID
    nextWaiterID += 1
    return try await withCheckedThrowingContinuation { continuation in
      let timer = Task { [weak self] in
        guard (try? await Task.sleep(for: timeout)) != nil else { return }
        await self?.expire(id, timeout: timeout)
      }
      waiter = Waiter(id: id, continuation: continuation, timer: timer)
    }
  }

  private func expire(_ id: Int, timeout: Duration) {
    guard let current = waiter, current.id == id else { return }
    waiter = nil
    let seconds =
      Double(timeout.components.seconds)
      + Double(timeout.components.attoseconds) / 1e18
    current.continuation.resume(throwing: GDBError.timeout(seconds: seconds))
  }

  // MARK: Internals: serialisation

  private func exclusive<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    if busy {
      await withCheckedContinuation { queue.append($0) }
    } else {
      busy = true
    }
    defer {
      if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }
    return try await body()
  }
}
