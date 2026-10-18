import Foundation

/// The guest architectures with a built-in register layout for stubs that serve no `target.xml`.
public enum GDBArchitecture: String, Sendable, CaseIterable, Codable {
  case arm64
  // swift-format-ignore: AlwaysUseLowerCamelCase
  case x86_64

  /// The annex name and contents of the built-in description.
  public var builtinDescription: (annex: String, xml: String) {
    switch self {
    case .arm64: ("aarch64-core.xml", BuiltinTargets.aarch64Core)
    case .x86_64: ("i386-64bit-core.xml", BuiltinTargets.x8664Core)
    }
  }

  /// The breakpoint `kind` for `Z0`/`Z1`: the instruction length to patch.
  public var breakpointKind: Int {
    switch self {
    case .arm64: 4
    case .x86_64: 1
    }
  }

  /// Maps a target description's `<architecture>` string to an architecture.
  public init?(targetArchitecture: String) {
    switch targetArchitecture {
    case let name where name.hasPrefix("aarch64"): self = .arm64
    case "i386:x86-64", "x86-64", "x86_64": self = .x86_64
    default: return nil
    }
  }
}

/// One register of the target description.
public struct GDBRegister: Sendable, Equatable {
  public var name: String
  /// The number `p`/`P` and expedited stop-reply registers use.
  public var number: Int
  public var bitSize: Int
  public var type: String?
  public var group: String?

  public init(name: String, number: Int, bitSize: Int, type: String? = nil, group: String? = nil) {
    self.name = name
    self.number = number
    self.bitSize = bitSize
    self.type = type
    self.group = group
  }

  public var byteSize: Int { (bitSize + 7) / 8 }
}

/// A register's contents, in target byte order (little-endian on both supported architectures).
public struct RegisterValue: Sendable, Equatable {
  public var bytes: [UInt8]

  public init(bytes: [UInt8]) { self.bytes = bytes }

  /// The numeric value for registers of up to 64 bits.
  public var uint64: UInt64? { Hex.littleEndian(bytes) }

  /// `0x`-prefixed hex, most significant byte first.
  public var hex: String { "0x" + Hex.encode(bytes.reversed()) }
}

/// A named register reading. `value` is `nil` when the stub reported the register unavailable.
public struct RegisterReading: Sendable, Equatable {
  public var register: GDBRegister
  public var value: RegisterValue?

  public init(register: GDBRegister, value: RegisterValue?) {
    self.register = register
    self.value = value
  }
}

/// Registers by number and name, built from `target.xml` (and the annexes it includes).
public struct RegisterMap: Sendable, Equatable {
  public var architecture: String?
  /// Every register, ordered by number: the order of the `g` packet.
  public var registers: [GDBRegister]

  public init(architecture: String?, registers: [GDBRegister]) {
    self.architecture = architecture
    self.registers = registers.sorted { $0.number < $1.number }
  }

  /// Names `pc` and `sp` resolve to on x86, where the registers are called `rip`/`rsp`.
  static let aliases: [String: [String]] = [
    "pc": ["pc", "rip", "eip"],
    "sp": ["sp", "rsp", "esp"],
  ]

  public func register(named name: String) -> GDBRegister? {
    let lower = name.lowercased()
    for candidate in Self.aliases[lower] ?? [lower] {
      if let found = registers.first(where: { $0.name.lowercased() == candidate }) {
        return found
      }
    }
    return nil
  }

  public func register(number: Int) -> GDBRegister? {
    registers.first { $0.number == number }
  }

  public var programCounter: GDBRegister? { register(named: "pc") }

  /// Splits a `g` reply into registers in number order. Registers past the end of the reply are
  /// omitted (stubs send only a prefix, e.g. QEMU sends the core registers); registers the stub
  /// sent as `xx` have a `nil` value.
  public func decode(registersReply reply: String) throws -> [RegisterReading] {
    let chars = Array(reply.utf8)
    guard chars.count % 2 == 0 else {
      throw GDBError.malformedReply("odd-length g reply")
    }
    var readings: [RegisterReading] = []
    var offset = 0
    for register in registers {
      let width = register.byteSize * 2
      guard offset + width <= chars.count else { break }
      let field = chars[offset..<offset + width]
      offset += width
      if field.allSatisfy({ $0 == 0x78 || $0 == 0x58 }) {
        readings.append(RegisterReading(register: register, value: nil))
      } else if let bytes = Hex.decode(String(decoding: field, as: UTF8.self)) {
        readings.append(RegisterReading(register: register, value: RegisterValue(bytes: bytes)))
      } else {
        throw GDBError.malformedReply("bad hex for register \(register.name)")
      }
    }
    return readings
  }

  /// The annexes a description includes with `<xi:include href=...>`, in document order.
  public static func includes(in xml: String) throws -> [String] {
    try TargetXMLParser.parse(xml).items.compactMap {
      if case .include(let href) = $0 { href } else { nil }
    }
  }

  /// The `bitsize` a description may give a register: the widest real registers (SVE/SME) are
  /// 2048 bits, so 4096 leaves room while keeping byte arithmetic far from overflow.
  public static let bitSizeLimit = 1...4096
  /// The register numbers a description may use (`p`/`P` take any hex number; real targets use
  /// a few hundred).
  public static let registerNumberLimit = 0...65535

  /// Builds the map from the main description and the annexes it includes (by name). Registers
  /// without `regnum` are numbered one after the previous register, starting at 0. A `bitsize`
  /// outside `bitSizeLimit` or a number outside `registerNumberLimit` is `badTargetDescription`.
  public static func build(targetXML xml: String, annexes: [String: String] = [:]) throws
    -> RegisterMap
  {
    var architecture: String?
    var registers: [GDBRegister] = []
    var next = 0
    func walk(_ text: String, depth: Int) throws {
      guard depth < 8 else { throw GDBError.badTargetDescription("includes nest too deep") }
      let document = try TargetXMLParser.parse(text)
      if architecture == nil { architecture = document.architecture }
      for item in document.items {
        switch item {
        case .include(let href):
          guard let included = annexes[href] else {
            throw GDBError.badTargetDescription("missing included annex \(href)")
          }
          try walk(included, depth: depth + 1)
        case .register(let name, let bitSize, let regnum, let type, let group):
          let number = regnum ?? next
          guard bitSizeLimit.contains(bitSize) else {
            throw GDBError.badTargetDescription("register \(name) has bitsize \(bitSize)")
          }
          guard registerNumberLimit.contains(number) else {
            throw GDBError.badTargetDescription("register \(name) has number \(number)")
          }
          registers.append(
            GDBRegister(name: name, number: number, bitSize: bitSize, type: type, group: group))
          next = number + 1
        }
      }
    }
    try walk(xml, depth: 0)
    guard !registers.isEmpty else {
      throw GDBError.badTargetDescription("no registers")
    }
    return RegisterMap(architecture: architecture, registers: registers)
  }

  /// The built-in layout for `architecture`.
  public static func builtin(_ architecture: GDBArchitecture) -> RegisterMap {
    // The built-in descriptions are constants; unit tests check that they parse.
    (try? build(targetXML: architecture.builtinDescription.xml))
      ?? RegisterMap(architecture: nil, registers: [])
  }
}

/// A minimal reader for GDB target descriptions: `<architecture>`, `<reg>` and `<xi:include>`.
enum TargetXMLParser {
  enum Item: Equatable {
    case include(String)
    case register(name: String, bitSize: Int, regnum: Int?, type: String?, group: String?)
  }

  struct Document {
    var architecture: String?
    var items: [Item]
  }

  static func parse(_ xml: String) throws -> Document {
    let delegate = Delegate()
    // Target descriptions carry a DOCTYPE naming gdb-target.dtd; never resolve it.
    let parser = XMLParser(data: Data(xml.utf8))
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse() else {
      if let error = delegate.error { throw error }
      throw GDBError.badTargetDescription(
        parser.parserError.map { "\($0.localizedDescription)" } ?? "unparseable XML")
    }
    if let error = delegate.error { throw error }
    let architecture = delegate.architecture?.trimmingCharacters(in: .whitespacesAndNewlines)
    return Document(
      architecture: architecture?.isEmpty == false ? architecture : nil, items: delegate.items)
  }

  private final class Delegate: NSObject, XMLParserDelegate {
    var items: [Item] = []
    var architecture: String?
    var inArchitecture = false
    var error: GDBError?

    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
      qualifiedName qName: String?, attributes: [String: String] = [:]
    ) {
      switch elementName {
      case "architecture":
        inArchitecture = true
        architecture = ""
      case "xi:include", "include":
        if let href = attributes["href"] { items.append(.include(href)) }
      case "reg":
        guard let name = attributes["name"], let bits = attributes["bitsize"].flatMap({ Int($0) })
        else {
          error = .badTargetDescription("reg without name or bitsize")
          parser.abortParsing()
          return
        }
        items.append(
          .register(
            name: name, bitSize: bits, regnum: attributes["regnum"].flatMap { Int($0) },
            type: attributes["type"], group: attributes["group"]))
      default: break
      }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      if inArchitecture { architecture? += string }
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
      qualifiedName qName: String?
    ) {
      if elementName == "architecture" { inArchitecture = false }
    }
  }
}

/// Built-in descriptions matching QEMU's `g` layout, for stubs without `qXfer:features:read`.
enum BuiltinTargets {
  static let aarch64Core: String = {
    let gprs = (0...30).map { "<reg name=\"x\($0)\" bitsize=\"64\"/>" }.joined(separator: "\n")
    return """
      <?xml version="1.0"?>
      <!DOCTYPE target SYSTEM "gdb-target.dtd">
      <target>
      <architecture>aarch64</architecture>
      <feature name="org.gnu.gdb.aarch64.core">
      \(gprs)
      <reg name="sp" bitsize="64" type="data_ptr"/>
      <reg name="pc" bitsize="64" type="code_ptr"/>
      <reg name="cpsr" bitsize="32"/>
      </feature>
      </target>
      """
  }()

  static let x8664Core: String = {
    let gprs = [
      "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp",
      "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
    ].map { name in
      let type = name == "rbp" || name == "rsp" ? " type=\"data_ptr\"" : ""
      return "<reg name=\"\(name)\" bitsize=\"64\"\(type)/>"
    }.joined(separator: "\n")
    let segments = ["cs", "ss", "ds", "es", "fs", "gs"].map {
      "<reg name=\"\($0)\" bitsize=\"32\"/>"
    }
    .joined(separator: "\n")
    let tail = ["fs_base", "gs_base", "k_gs_base", "cr0", "cr2", "cr3", "cr4", "cr8", "efer"]
      .map { "<reg name=\"\($0)\" bitsize=\"64\"/>" }.joined(separator: "\n")
    return """
      <?xml version="1.0"?>
      <!DOCTYPE target SYSTEM "gdb-target.dtd">
      <target>
      <architecture>i386:x86-64</architecture>
      <feature name="org.gnu.gdb.i386.core">
      \(gprs)
      <reg name="rip" bitsize="64" type="code_ptr"/>
      <reg name="eflags" bitsize="32"/>
      \(segments)
      \(tail)
      </feature>
      </target>
      """
  }()
}
