import Foundation
import VMLabCore
import VMLabVZ
@preconcurrency import Virtualization

/// Turns a `VZRunnerConfig` into a validated `VZVirtualMachineConfiguration`. R-601 extends this
/// (cloud-init seed, balloon, serial pipes, graphics) and adds the unit test of its decisions.
enum ConfigurationBuilder {
  static func build(_ config: VZRunnerConfig) throws(VMLabError) -> VZVirtualMachineConfiguration {
    let machine = VZVirtualMachineConfiguration()
    machine.cpuCount = min(
      max(config.cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
      VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    let mib: UInt64 = 1 << 20
    machine.memorySize = min(
      max(config.memoryBytes / mib * mib, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
      VZVirtualMachineConfiguration.maximumAllowedMemorySize)
    machine.platform = VZGenericPlatformConfiguration()

    let storeURL = URL(filePath: config.efiVariableStore)
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

    machine.storageDevices = try config.disks.map { disk throws(VMLabError) in
      do {
        let attachment = try VZDiskImageStorageDeviceAttachment(
          url: URL(filePath: disk.path), readOnly: disk.readOnly)
        return VZVirtioBlockDeviceConfiguration(attachment: attachment)
      } catch {
        throw engineError("Cannot attach the disk \(disk.path)", error)
      }
    }

    machine.networkDevices = try config.network.map { network throws(VMLabError) in
      switch network {
      case .nat(let mac):
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        if let mac {
          guard let address = VZMACAddress(string: mac) else {
            throw VMLabError.invalidRequest(
              field: "network.macAddress", reason: "\(mac) is not a MAC address",
              hint: "Use six colon-separated hex octets.")
          }
          device.macAddress = address
        } else {
          device.macAddress = .randomLocallyAdministered()
        }
        return device
      }
    }

    if let consoleLog = config.consoleLog {
      let fd = open(consoleLog, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
      guard fd >= 0 else {
        throw VMLabError(
          code: .internal,
          message: "Cannot open \(consoleLog): \(String(cString: strerror(errno)))",
          hint: "Check that the VM directory is writable.")
      }
      let console = VZVirtioConsoleDeviceSerialPortConfiguration()
      console.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: nil,
        fileHandleForWriting: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
      machine.serialPorts = [console]
    }
    machine.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    do { try machine.validate() } catch {
      throw validationError(error)
    }
    return machine
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
