import Darwin
import Foundation

/// Whether a pid read from a VM's pid file (`qemu.pid`, `vz.pid`) or its record still names that
/// VM's engine (bug hunt BH-3). A pid file outlives an engine that was SIGKILLed or lost to a host
/// reboot, and its pid is later reused by an unrelated process; `kill(pid, 0)` alone would then
/// make every start refuse and every kill signal that process. So the pid must be alive, its
/// executable (`proc_pidpath`) a QEMU system emulator or the VZ runner, and, when its arguments
/// can be read, one of them must name the VM's directory (QEMU's `-pidfile`, the runner's `run`).
public enum EngineProcess {
  /// The pid files an engine writes in its VM directory.
  public static let pidFiles = ["qemu.pid", "vz.pid"]

  /// The pid of an engine that runs the VM in `vmDirectory`, by its pid files; nil when none does.
  public static func running(in vmDirectory: URL) -> Int32? {
    for file in pidFiles {
      guard
        let text = try? String(contentsOf: vmDirectory.appending(path: file), encoding: .utf8),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
        isRunning(pid, vmDirectory: vmDirectory)
      else { continue }
      return pid
    }
    return nil
  }

  /// CX-14: kills the engine `running(in:)` finds and waits up to `wait` for it to go. A start
  /// that crashed (or failed) after launching its engine and before recording `runtime` leaves
  /// one; the caller holds the VM's operation lock, so no start of it is in flight. The pid
  /// killed, or nil when there was none.
  @discardableResult
  public static func killStranded(in vmDirectory: URL, wait: Duration = .seconds(5)) async
    -> Int32?
  {
    guard let pid = running(in: vmDirectory), kill(pid, vmDirectory: vmDirectory) else {
      return nil
    }
    let deadline = ContinuousClock.now + wait
    while LivenessProbe.processExists(pid), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    return pid
  }

  /// The executables an engine pid file may name: QEMU's system emulators and the VZ runner.
  public static func isEngine(_ path: String) -> Bool {
    let name = URL(filePath: path).lastPathComponent
    return name.hasPrefix("qemu-system-") || name == "vmlab-vz"
  }

  /// The executable a segment's `switch.pid` names: the segment switch (R-901).
  public static func isSwitch(_ path: String) -> Bool {
    URL(filePath: path).lastPathComponent == "vmlab-switch"
  }

  /// `pid` is a live `vmlab-switch` for the segment whose directory is `segmentDirectory`
  /// (`<home>/segments/<name>`): its argument is `<name>` and its `VMLAB_HOME` environment (or a
  /// `VMLAB_HOME=` argument) names `<home>`. False when either cannot be read, so a pid reused by
  /// another segment's switch of the same home is not this one's.
  public static func isSwitchRunning(_ pid: Int32, segmentDirectory: URL) -> Bool {
    guard LivenessProbe.processExists(pid), let path = HostProcesses.executablePath(pid),
      isSwitch(path), let arguments = HostProcesses.arguments(pid),
      arguments.contains(segmentDirectory.lastPathComponent)
    else { return false }
    let fromArguments = arguments.last { $0.hasPrefix("VMLAB_HOME=") }
      .map { String($0.dropFirst("VMLAB_HOME=".count)) }
    guard let value = HostProcesses.environment(pid)?["VMLAB_HOME"] ?? fromArguments else {
      return false
    }
    let home = segmentDirectory.deletingLastPathComponent().deletingLastPathComponent()
    return sameDirectory(value, home)
  }

  /// Whether the absolute `path` is `directory` (as given or both canonical).
  static func sameDirectory(_ path: String, _ directory: URL) -> Bool {
    guard path.hasPrefix("/") else { return false }
    let given = directory.standardizedFileURL.path
    return URL(filePath: path).standardizedFileURL.path == given
      || PathPolicy.canonical(path) == PathPolicy.canonical(given)
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
