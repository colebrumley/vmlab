import Darwin
import Foundation

/// Whether a pid read from a VM's pid file (`qemu.pid`, `vz.pid`) or its record still names that
/// VM's engine (bug hunt BH-3). A pid file outlives an engine that was SIGKILLed or lost to a host
/// reboot, and its pid is later reused by an unrelated process; `kill(pid, 0)` alone would then
/// make every start refuse and every kill signal that process. So the pid must be alive, its
/// executable (`proc_pidpath`) a QEMU system emulator or the VZ runner, and, when its arguments
/// can be read, one of them must name the VM's directory (QEMU's `-pidfile`, the runner's `run`).
public enum EngineProcess {
  /// The executables an engine pid file may name: QEMU's system emulators and the VZ runner.
  public static func isEngine(_ path: String) -> Bool {
    let name = URL(filePath: path).lastPathComponent
    return name.hasPrefix("qemu-system-") || name == "vmlab-vz"
  }

  /// `pid` is a live engine process, and runs the VM in `vmDirectory` when that is given.
  public static func isRunning(_ pid: Int32, vmDirectory: URL? = nil) -> Bool {
    guard LivenessProbe.processExists(pid), let path = HostProcesses.executablePath(pid),
      isEngine(path)
    else { return false }
    guard let vmDirectory, let arguments = HostProcesses.arguments(pid) else { return true }
    return arguments.contains { names($0, vmDirectory) }
  }

  /// SIGKILLs `pid` only when `isRunning(pid, vmDirectory:)`; whether it was signalled.
  @discardableResult
  public static func kill(_ pid: Int32, vmDirectory: URL? = nil) -> Bool {
    guard isRunning(pid, vmDirectory: vmDirectory) else { return false }
    return Darwin.kill(pid, SIGKILL) == 0
  }

  /// Whether `argument` is, or is a path inside, `directory` (as given or both canonical).
  static func names(_ argument: String, _ directory: URL) -> Bool {
    guard argument.hasPrefix("/") else { return false }
    let given = directory.standardizedFileURL.path
    return PathPolicy.isInside(argument, given)
      || PathPolicy.isInside(PathPolicy.canonical(argument), PathPolicy.canonical(given))
  }
}
