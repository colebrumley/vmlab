import Foundation
import VMLabCore
import VMLabVZ
@preconcurrency import Virtualization

/// The guest's virtio console: two pipes the runner owns. Guest output is appended to the console
/// log and, when a socket is configured, bridged to `serial.sock` (`SerialBridge`, R-602), whose
/// clients' bytes are written to the guest's input pipe.
final class ConsolePipes: Sendable {
  let guestInput = Pipe()
  let guestOutput = Pipe()
  let log: FileHandle
  let bridge: SerialBridge?

  init(log path: String, socket: String?) throws(VMLabError) {
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    guard fd >= 0 else {
      throw VMLabError(
        code: .internal,
        message: "Cannot open \(path): \(String(cString: strerror(errno)))",
        hint: "Check that the VM directory is writable.")
    }
    log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    if let socket {
      do {
        bridge = try SerialBridge(
          path: socket, guestInput: guestInput.fileHandleForWriting.fileDescriptor)
      } catch {
        throw VMLabError(
          code: .internal, message: "Cannot listen on \(socket): \(error)",
          hint: "Check the VM directory and that the path is under 104 bytes.",
          data: ["socket": .string(socket)])
      }
    } else {
      bridge = nil
    }
  }

  var attachment: VZFileHandleSerialPortAttachment {
    VZFileHandleSerialPortAttachment(
      fileHandleForReading: guestInput.fileHandleForReading,
      fileHandleForWriting: guestOutput.fileHandleForWriting)
  }

  /// Starts copying guest output to the log and the bridge, and accepting bridge clients.
  func start() {
    let log = log
    let bridge = bridge
    bridge?.start()
    guestOutput.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      } else {
        try? log.write(contentsOf: data)
        bridge?.guestOutput([UInt8](data))
      }
    }
  }
}

/// A built machine and the console pipes the runner must keep alive.
struct BuiltMachine {
  let configuration: VZVirtualMachineConfiguration
  let console: ConsolePipes?
}

/// Turns a `VZRunnerConfig` into a validated `VZVirtualMachineConfiguration`: the config is first
/// resolved into `VZMachineDecisions` (plain data, unit-tested in VMLabVZ), which this materialises
/// device by device.
enum ConfigurationBuilder {
  static var limits: VZMachineLimits {
    VZMachineLimits(
      minCPUs: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
      maxCPUs: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
      minMemoryBytes: VZVirtualMachineConfiguration.minimumAllowedMemorySize,
      maxMemoryBytes: VZVirtualMachineConfiguration.maximumAllowedMemorySize)
  }

  static func build(_ config: VZRunnerConfig) throws(VMLabError) -> BuiltMachine {
    let plan = try config.decisions(limits: limits)
    let machine = VZVirtualMachineConfiguration()
    machine.cpuCount = plan.cpus
    machine.memorySize = plan.memoryBytes
    let platform = VZGenericPlatformConfiguration()
    if let path = plan.machineIdentifier {
      platform.machineIdentifier = try machineIdentifier(at: URL(filePath: path))
    }
    if plan.nestedVirtualization {
      guard VZGenericPlatformConfiguration.isNestedVirtualizationSupported else {
        throw VMLabError(
          code: .capabilityMissing,
          message: "This host cannot give VZ guests nested virtualization",
          hint: "Nested virtualization needs an M3 or newer and macOS 15; recreate the VM "
            + "without nested_virt.",
          data: ["feature": .string("nested_virt")])
      }
      platform.isNestedVirtualizationEnabled = true
    }
    machine.platform = platform

    switch plan.bootLoader {
    case .macOS(let model, let identifier, let auxiliary):
      machine.platform = try macPlatform(
        hardwareModel: model, machineIdentifier: identifier, auxiliaryStorage: auxiliary)
      machine.bootLoader = VZMacOSBootLoader()
    case .efi(let path):
      let storeURL = URL(filePath: path)
      let store: VZEFIVariableStore
      do {
        store =
          FileManager.default.fileExists(atPath: storeURL.path)
          ? VZEFIVariableStore(url: storeURL)
          : try VZEFIVariableStore(creatingVariableStoreAt: storeURL)
      } catch {
        throw engineError("Cannot create the EFI variable store \(storeURL.path)", error)
      }
      let loader = VZEFIBootLoader()
      loader.variableStore = store
      machine.bootLoader = loader
    case .linux(let kernel, let initrd, let commandLine):
      let loader = VZLinuxBootLoader(kernelURL: URL(filePath: kernel))
      loader.initialRamdiskURL = initrd.map { URL(filePath: $0) }
      loader.commandLine = commandLine
      machine.bootLoader = loader
    }

    machine.storageDevices = try plan.storage.map { disk throws(VMLabError) in
      do {
        let attachment = try VZDiskImageStorageDeviceAttachment(
          url: URL(filePath: disk.path), readOnly: disk.readOnly)
        return VZVirtioBlockDeviceConfiguration(attachment: attachment)
      } catch {
        throw engineError("Cannot attach the disk \(disk.path)", error)
      }
    }

    machine.networkDevices = plan.network.map { nic in
      let device = VZVirtioNetworkDeviceConfiguration()
      device.attachment = VZNATNetworkDeviceAttachment()
      // decisions(limits:) validated the text.
      device.macAddress =
        nic.mac.flatMap(VZMACAddress.init(string:)) ?? .randomLocallyAdministered()
      return device
    }

    var pipes: ConsolePipes? = nil
    if let console = plan.console {
      let console = try ConsolePipes(log: console.log, socket: console.socket)
      let port = VZVirtioConsoleDeviceSerialPortConfiguration()
      port.attachment = console.attachment
      machine.serialPorts = [port]
      pipes = console
    }
    machine.directorySharingDevices = try plan.fileSystems.map { fs throws(VMLabError) in
      let device = VZVirtioFileSystemDeviceConfiguration(tag: fs.tag)
      if fs.rosetta {
        guard VZLinuxRosettaDirectoryShare.availability == .installed else {
          throw VMLabError(
            code: .hostMissingTool, message: "Rosetta for Linux is not installed on this host",
            hint: "Run softwareupdate --install-rosetta, then start the VM again.",
            data: ["tool": .string("rosetta")])
        }
        do {
          device.share = try VZLinuxRosettaDirectoryShare()
        } catch {
          throw engineError("Cannot share Rosetta", error)
        }
      } else {
        device.share = VZSingleDirectoryShare(
          directory: VZSharedDirectory(url: URL(filePath: fs.path ?? "/"), readOnly: fs.readOnly))
      }
      return device
    }
    if plan.entropy { machine.entropyDevices = [VZVirtioEntropyDeviceConfiguration()] }
    if plan.memoryBalloon {
      machine.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    }
    if let graphics = plan.graphics {
      if plan.platform == "mac" {
        let device = VZMacGraphicsDeviceConfiguration()
        device.displays = [
          VZMacGraphicsDisplayConfiguration(
            widthInPixels: graphics.width, heightInPixels: graphics.height,
            pixelsPerInch: graphics.pixelsPerInch ?? 72)
        ]
        machine.graphicsDevices = [device]
      } else {
        let device = VZVirtioGraphicsDeviceConfiguration()
        device.scanouts = [
          VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: graphics.width, heightInPixels: graphics.height)
        ]
        machine.graphicsDevices = [device]
      }
      machine.keyboards = [VZUSBKeyboardConfiguration()]
      machine.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    do { try machine.validate() } catch {
      throw validationError(error)
    }
    return BuiltMachine(configuration: machine, console: pipes)
  }

  /// The identifier stored at `url`, or a new one written there.
  static func machineIdentifier(at url: URL) throws(VMLabError) -> VZGenericMachineIdentifier {
    if let data = try? Data(contentsOf: url),
      let stored = VZGenericMachineIdentifier(dataRepresentation: data)
    {
      return stored
    }
    let fresh = VZGenericMachineIdentifier()
    do { try fresh.dataRepresentation.write(to: url, options: .atomic) } catch {
      throw engineError("Cannot write the machine identifier \(url.path)", error)
    }
    return fresh
  }

  /// A `VZMacPlatformConfiguration` from a Tart clone's hardware model, machine identifier (base64
  /// `dataRepresentation`s) and auxiliary storage file.
  static func macPlatform(
    hardwareModel: String, machineIdentifier: String, auxiliaryStorage: String
  ) throws(VMLabError) -> VZMacPlatformConfiguration {
    guard let modelData = Data(base64Encoded: hardwareModel),
      let model = VZMacHardwareModel(dataRepresentation: modelData)
    else { throw macError("the hardware model in config.json is not readable") }
    guard model.isSupported else {
      throw macError("this host cannot run the image's macOS hardware model")
    }
    guard let identifierData = Data(base64Encoded: machineIdentifier),
      let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData)
    else { throw macError("the machine identifier (ecid) in config.json is not readable") }
    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = model
    platform.machineIdentifier = identifier
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: URL(filePath: auxiliaryStorage))
    return platform
  }

  static func macError(_ reason: String) -> VMLabError {
    VMLabError(
      code: .engineError, message: "Cannot build the macOS platform: \(reason)",
      hint: "Pull the image again, or try macos-sequoia-base (Appendix H).",
      data: ["engine": .string("vz"), "raw": .string(reason)])
  }

  /// A failed `validate()`: `host_missing_tool` when the process lacks the entitlement.
  static func validationError(_ error: any Error) -> VMLabError {
    let text = "\(error.localizedDescription) \(error)"
    if text.contains(CodeSignature.virtualizationEntitlement) || text.contains("entitlement") {
      return VMLabError(
        code: .hostMissingTool,
        message: "vmlab-vz lacks the \(CodeSignature.virtualizationEntitlement) entitlement",
        hint: VZRunnerLauncher.signingHint,
        data: [
          "tool": .string("vmlab-vz"),
          "entitlement": .string(CodeSignature.virtualizationEntitlement),
        ])
    }
    return engineError("Invalid VZ configuration", error)
  }

  static func engineError(_ what: String, _ error: any Error) -> VMLabError {
    let ns = error as NSError
    return VMLabError(
      code: .engineError, message: "\(what): \(ns.localizedDescription)",
      hint: "Check <vm>/vz.log.",
      data: ["domain": .string(ns.domain), "errorCode": .number(Double(ns.code))])
  }
}
