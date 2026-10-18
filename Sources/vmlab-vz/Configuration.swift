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
    machine.platform = VZGenericPlatformConfiguration()

    switch plan.bootLoader {
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
    if plan.entropy { machine.entropyDevices = [VZVirtioEntropyDeviceConfiguration()] }
    if plan.memoryBalloon {
      machine.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    }
    if let graphics = plan.graphics {
      let device = VZVirtioGraphicsDeviceConfiguration()
      device.scanouts = [
        VZVirtioGraphicsScanoutConfiguration(
          widthInPixels: graphics.width, heightInPixels: graphics.height)
      ]
      machine.graphicsDevices = [device]
      machine.keyboards = [VZUSBKeyboardConfiguration()]
      machine.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    do { try machine.validate() } catch {
      throw validationError(error)
    }
    return BuiltMachine(configuration: machine, console: pipes)
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
