import VMLabCore

/// One MCP tool as the model sees it: its name, the description `tools/list` sends, the JSON
/// Schema (draft 2020-12) of its arguments, and the documented shape of its result (Appendix C).
/// Handlers are wired by R-201 and later items; this type only describes.
public struct ToolSpec: Sendable, Hashable {
  /// `^[a-z0-9_]{1,40}$` (constraint C10).
  public let name: String
  /// What the tool does, when to use it and what it returns, written for a model.
  public let summary: String
  /// The input schema: a JSON Schema object with `type: object`.
  public let inputSchema: JSONValue
  /// The result object, as a short JSON-like sketch for `docs/TOOLS.md`. Every result also carries
  /// `vm` where a VM is involved and `warnings`.
  public let outputShape: String
  /// The Appendix D codes the tool can raise, beyond `internal`.
  public let errors: [ErrorCode]

  public init(
    name: String, summary: String, inputSchema: JSONValue, outputShape: String,
    errors: [ErrorCode]
  ) {
    self.name = name
    self.summary = summary
    self.inputSchema = inputSchema
    self.outputShape = outputShape
    self.errors = errors
  }

  /// The `description` sent in `tools/list`: the summary plus the errors it can raise.
  public var description: String {
    guard !errors.isEmpty else { return summary }
    return summary + " Errors: " + errors.map(\.rawValue).joined(separator: ", ") + "."
  }
}

/// Builders for the JSON Schema fragments the tool files use. Every node carries a `type`.
enum Schema {
  static let dialect = "https://json-schema.org/draft/2020-12/schema"

  /// A tool's input: an object schema tagged with the 2020-12 dialect.
  static func input(_ properties: [String: JSONValue] = [:], required: [String] = [])
    -> JSONValue
  {
    guard case .object(var schema) = object(properties, required: required) else {
      preconditionFailure("object() builds an object")
    }
    schema["$schema"] = .string(dialect)
    return .object(schema)
  }

  static func object(
    _ properties: [String: JSONValue], required: [String] = [], description: String? = nil,
    additionalProperties: JSONValue? = .bool(false)
  ) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("object"), "properties": .object(properties),
    ]
    if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
    if let description { schema["description"] = .string(description) }
    if let additionalProperties { schema["additionalProperties"] = additionalProperties }
    return .object(schema)
  }

  static func string(
    _ description: String, enum values: [String]? = nil, default value: String? = nil
  )
    -> JSONValue
  {
    var schema: [String: JSONValue] = [
      "type": .string("string"), "description": .string(description),
    ]
    if let values { schema["enum"] = .array(values.map { .string($0) }) }
    if let value { schema["default"] = .string(value) }
    return .object(schema)
  }

  static func integer(
    _ description: String, minimum: Int? = nil, maximum: Int? = nil, default value: Int? = nil
  ) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("integer"), "description": .string(description),
    ]
    if let minimum { schema["minimum"] = .number(Double(minimum)) }
    if let maximum { schema["maximum"] = .number(Double(maximum)) }
    if let value { schema["default"] = .number(Double(value)) }
    return .object(schema)
  }

  static func number(_ description: String, minimum: Double? = nil, default value: Double? = nil)
    -> JSONValue
  {
    var schema: [String: JSONValue] = [
      "type": .string("number"), "description": .string(description),
    ]
    if let minimum { schema["minimum"] = .number(minimum) }
    if let value { schema["default"] = .number(value) }
    return .object(schema)
  }

  static func boolean(_ description: String, default value: Bool = false) -> JSONValue {
    .object([
      "type": .string("boolean"), "description": .string(description), "default": .bool(value),
    ])
  }

  static func array(
    _ items: JSONValue, _ description: String, minItems: Int? = nil, maxItems: Int? = nil,
    unique: Bool = false
  ) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("array"), "items": items, "description": .string(description),
    ]
    if let minItems { schema["minItems"] = .number(Double(minItems)) }
    if let maxItems { schema["maxItems"] = .number(Double(maxItems)) }
    if unique { schema["uniqueItems"] = .bool(true) }
    return .object(schema)
  }

  /// The action selector of a tool that shares one target (constraint C10).
  static func action(_ values: [String], _ description: String) -> JSONValue {
    string(description, enum: values)
  }

  // MARK: Fragments shared by several tools

  static let vm = string("The VM's id (vm-xxxxxx) or name, as vm_list or vm_create returned it.")

  static func timeoutSeconds(_ description: String, default value: Int? = nil) -> JSONValue {
    integer(description, minimum: 1, default: value)
  }

  static let allowUnverified = boolean(
    "Treat features whose slow probe has not run on this host as available, instead of failing "
      + "with unverified_capability.")

  /// `requirements` of `vm_plan`, `vm_create` and `fleet create`: `Requirements` in
  /// `Sources/VMLabCore/Features.swift`.
  static let requirements: JSONValue = {
    let features = Feature.allCases.map(\.rawValue)
    let port = { (description: String) in integer(description, minimum: 1, maximum: 65535) }
    return object(
      [
        "guest": object(
          [
            "os": string("Guest operating system.", enum: GuestSpec.OS.allCases.map(\.rawValue)),
            "arch": string(
              "Guest CPU architecture: arm64, x86_64, riscv64, or another QEMU architecture name."
                + " Anything but arm64 runs under emulation (qemu-tcg)."),
          ], required: ["os", "arch"], description: "The guest to run."),
        "require": array(
          string("A feature from the catalogue (docs/FEATURES.md).", enum: features),
          "Features the VM must have; a profile lacking any is ruled out. Default [] (VZ).",
          unique: true),
        "prefer": array(
          string("A feature from the catalogue (docs/FEATURES.md).", enum: features),
          "Features to have when possible; they rank profiles but never rule one out.",
          unique: true),
        "resources": object(
          [
            "cpus": integer("Virtual CPUs.", minimum: 1),
            "memoryGB": integer("Guest memory in GB.", minimum: 1),
            "diskGB": integer("Disk size in GB.", minimum: 1),
          ], description: "Guest resources; each omitted field takes the guest's default."),
        "network": object(
          [
            "mode": string(
              "nat for outbound internet, none for no network device at all.",
              enum: NetworkSpec.Mode.allCases.map(\.rawValue)),
            "segment": string("A private segment (net_segment) to join with a second NIC."),
            "forwards": array(
              object(
                [
                  "guest": port("Guest port."),
                  "host": port("Host port on 127.0.0.1; omit to let vmlab choose one."),
                ], required: ["guest"]),
              "Guest ports to make reachable from the host."),
          ], description: "Networking; omitted means NAT."),
        "image": string(
          "Image or template name (images list). Omitted: the default image for the guest."),
        "boot": object(
          [
            "mode": string(
              "disk boots the image; kernel boots kernel/initrd directly; firmware boots a "
                + "supplied firmware image; binary loads a raw image at loadAddress and starts "
                + "the CPU there.",
              enum: BootSpec.Mode.allCases.map(\.rawValue), default: "disk"),
            "kernel": string(
              "Host path of the kernel image (mode kernel). Omitted: the image's kernel, "
                + "extracted from it on first use (images extract_kernel)."),
            "initrd": string("Host path of the initrd (mode kernel)."),
            "cmdline": string(
              "Kernel command line (mode kernel), e.g. console=ttyAMA0 root=/dev/vda1."),
            "dtb": string("Host path of a device tree blob (mode kernel); default QEMU's own."),
            "firmware": string("Host path of the firmware image (mode firmware)."),
            "firmwareFormat": string(
              "pflash attaches the firmware as UEFI flash; bios loads it as a ROM (-bios).",
              enum: BootSpec.FirmwareFormat.allCases.map(\.rawValue), default: "pflash"),
            "binary": string("Host path of a raw image to load (mode binary)."),
            "loadAddress": string(
              "Guest physical address for binary, hex such as 0x40080000 (mode binary)."),
            "haltAtStart": boolean(
              "Start with the CPU halted so vm_debug sees the first "
                + "instruction."),
          ], description: "How the guest boots; omitted means from its disk."),
        "extra": object(
          [
            "qemuArgs": array(
              string("One QEMU command-line argument."),
              "Arguments appended verbatim after vmlab's own (implies custom_devices, so QEMU), "
                + "e.g. [\"-device\", \"virtio-rng-pci\"]. -qmp, -serial, -vnc, -gdb, -s, "
                + "-pidfile, -daemonize, -monitor, -mon and -readconfig are refused: vmlab owns them."
            )
          ], description: "Engine-specific additions."),
        "share": object(
          [
            "host": string(
              "Absolute host path of an existing directory. Omitted: the VM's own shared/ "
                + "directory (vm_inspect endpoints.share)."),
            "guest": string(
              "Absolute guest path it is mounted at.", default: SharedDirSpec.defaultGuestPath),
          ],
          description:
            "A host directory mounted read-write in the guest (implies shared_dir): 9p under "
            + "QEMU (the guest kernel needs 9p; Debian's cloud kernel has none), virtiofs under VZ."
        ),
      ], required: ["guest"],
      description: "What the VM must be. Only guest is required; every other field has a default.")
  }()
}
