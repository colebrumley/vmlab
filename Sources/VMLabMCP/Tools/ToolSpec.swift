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
    _ description: String, enum values: [String]? = nil, default value: String? = nil,
    maxLength: Int? = nil
  )
    -> JSONValue
  {
    var schema: [String: JSONValue] = [
      "type": .string("string"), "description": .string(description),
    ]
    if let values { schema["enum"] = .array(values.map { .string($0) }) }
    if let maxLength { schema["maxLength"] = .number(Double(maxLength)) }
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

  static func number(
    _ description: String, minimum: Double? = nil, maximum: Double? = nil,
    default value: Double? = nil
  ) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("number"), "description": .string(description),
    ]
    if let minimum { schema["minimum"] = .number(minimum) }
    if let maximum { schema["maximum"] = .number(maximum) }
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

  static let vm = string(
    "The VM's id (vm-xxxxxx) or name, as vm_list or vm_create returned it.",
    maxLength: VMRecord.maxNameLength)

  /// A new VM's name: the rule `Store` enforces.
  static func vmName(_ description: String) -> JSONValue {
    string(
      description + " 1 to \(VMRecord.maxNameLength) letters, digits, '.', '_' or '-', starting "
        + "with a letter or digit.", maxLength: VMRecord.maxNameLength)
  }

  /// A segment's name: the rule `SegmentStore.isValidName` enforces.
  static func segmentName(_ description: String) -> JSONValue {
    string(
      description + " Lowercase letters, digits and '-', at most "
        + "\(SegmentStore.maxNameLength) characters.", maxLength: SegmentStore.maxNameLength)
  }

  static func timeoutSeconds(
    _ description: String, maximum: Int? = nil, default value: Int? = nil
  ) -> JSONValue {
    integer(description, minimum: 1, maximum: maximum, default: value)
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
            "cpus": integer("Virtual CPUs.", minimum: 1, maximum: ResourceLimits.maxCPUs),
            "memoryGB": integer(
              "Guest memory in GB.", minimum: 1, maximum: ResourceLimits.maxMemoryGB),
            "diskGB": integer("Disk size in GB.", minimum: 1, maximum: ResourceLimits.maxDiskGB),
          ], description: "Guest resources; each omitted field takes the guest's default."),
        "network": object(
          [
            "mode": string(
              "nat for outbound internet, none for no network device at all.",
              enum: NetworkSpec.Mode.allCases.map(\.rawValue)),
            "segment": segmentName("A private segment (net_segment) to join with a second NIC."),
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
              "QEMU arguments after vmlab's own (implies custom_devices, so QEMU), e.g. "
                + "[\"-device\", \"virtio-rng-pci\"]. Devices, drives, objects, chardevs, "
                + "user-mode netdevs, -cpu (replaces vmlab's; host or max under qemu-hvf), "
                + "-machine properties (merged into vmlab's; no accel=), -icount, -d, -D, -trace, "
                + "-numa, -overcommit and more are allowed. Refused: monitors, -serial (vmlab's "
                + "console; add -chardev plus -device pci-serial), -incoming, -add-fd, -set, "
                + "-readconfig, exec:/mon:/cmd:, fd/script/helper keys, tap/bridge/vmnet; "
                + "-plugin, -semihosting and passthrough devices need the owner's allowHostCode. "
                + "Host paths must be absolute and outside VMLAB_HOME; paths QEMU only reads "
                + "(-cdrom, romfile=, readonly=on disks) may be under the home or /tmp, paths it "
                + "writes (-D, -trace file=, chardev path=, writable disks, shared dirs) only "
                + "under /tmp, $TMPDIR or ~/vmlab-files (never a home dotfile or ~/Library)."
            )
          ], description: "Engine-specific additions."),
        "provision": object(
          [
            "packages": array(
              string("A distribution package name, e.g. jq."),
              "Packages cloud-init installs on first boot (Linux only)."),
            "userData": string(
              "cloud-init user-data merged after vmlab's own (its keys win, lists append); must "
                + "start with #cloud-config, #!, #cloud-boothook or #include (Linux only)."),
            "runCommands": array(
              string("One shell command."),
              "Commands run in order on first boot: as root after cloud-init (Linux), or over "
                + "SSH as the login user (macOS). The first that fails stops the rest; "
                + "vm_inspect reports it as provision_failed."),
          ], description: "First-boot provisioning beyond vmlab's own setup."),
        "share": object(
          [
            "host": string(
              "Absolute host path of an existing directory under /tmp, $TMPDIR or ~/vmlab-files "
                + "(the guest writes it; never the home itself, a home dotfile or ~/Library). "
                + "Omitted: the VM's own shared/ "
                + "directory (vm_inspect endpoints.share)."),
            "guest": string(
              "Absolute guest path it is mounted at. A macOS guest always mounts it at "
                + "\(SharedDirSpec.macOSAutomountPath).",
              default: SharedDirSpec.defaultGuestPath),
          ],
          description:
            "A host directory mounted read-write in the guest (implies shared_dir): 9p under "
            + "QEMU (the guest kernel needs 9p; Debian's cloud kernel has none), virtiofs under VZ."
        ),
      ], required: ["guest"],
      description: "What the VM must be. Only guest is required; every other field has a default.")
  }()
}
