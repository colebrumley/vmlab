import Foundation
import Logging
import VMLabCore
import VMLabVZ
@preconcurrency import Virtualization

/// Owns one `VZVirtualMachine` on the main queue and answers control requests for it. Once the
/// guest has run and then stops (from inside, `stop`, `kill` or `exit`), the runner exits.
@MainActor
final class Runner: NSObject {
  let paths: VZRunnerPaths
  let machine: VZVirtualMachine
  let logger = Logger(label: "vmlab-vz")
  let events: EventLog
  private var hasRun = false
  private var exiting = false

  /// The virtio console's pipes, kept alive for the life of the guest.
  let console: ConsolePipes?

  init(paths: VZRunnerPaths, machine built: BuiltMachine) {
    self.paths = paths
    self.machine = VZVirtualMachine(configuration: built.configuration)
    self.console = built.console
    self.events = EventLog(vmDirectory: paths.vmDirectory)
    super.init()
    machine.delegate = self
    // Drain the console from the start, so a restored (--hold) guest never blocks on a full pipe.
    console?.start()
  }

  var state: RunnerState {
    switch machine.state {
    case .stopped: .stopped
    case .running: .running
    case .paused: .paused
    case .error: .error
    case .starting: .starting
    case .pausing: .pausing
    case .resuming: .resuming
    case .stopping: .stopping
    case .saving: .saving
    case .restoring: .restoring
    @unknown default: .error
    }
  }

  private var pid: Int32 { getpid() }

  /// Starts the guest; a failure ends the runner with the error.
  func start() {
    machine.start { result in
      MainActor.assumeIsolated {
        switch result {
        case .success:
          self.hasRun = true
          self.record("guest started (runner pid \(self.pid))")
        case .failure(let error):
          Runner.fatal(
            ConfigurationBuilder.engineError("Cannot start the VZ guest", error), paths: self.paths)
        }
      }
    }
  }

  /// Answers `request`; `reply` is called once, on the main queue.
  func handle(_ request: ControlRequest, reply: @escaping @Sendable (ControlResponse) -> Void) {
    let done: (Result<Void, any Error>, String) -> Void = { result, what in
      switch result {
      case .success: reply(.success(self.state, pid: self.pid))
      case .failure(let error):
        reply(.failure(ConfigurationBuilder.engineError(what, error), state: self.state))
      }
    }
    switch request.command {
    case .status:
      reply(.success(state, pid: pid))
    case .pause:
      guard machine.canPause else { return reply(refusal(request.command)) }
      machine.pause { result in
        MainActor.assumeIsolated {
          done(result, "pause failed")
          if case .success = result { self.record("guest paused") }
        }
      }
    case .resume:
      guard machine.canResume else { return reply(refusal(request.command)) }
      machine.resume { result in
        MainActor.assumeIsolated {
          if case .success = result { self.hasRun = true }
          done(result, "resume failed")
          if case .success = result { self.record("guest resumed") }
        }
      }
    case .stop:
      guard machine.canRequestStop else { return reply(refusal(request.command)) }
      do {
        try machine.requestStop()
        record("guest asked to stop")
        reply(.success(state, pid: pid))
      } catch {
        done(.failure(error), "requestStop failed")
      }
    case .kill:
      guard machine.canStop else { return reply(refusal(request.command)) }
      machine.stop { error in
        MainActor.assumeIsolated {
          done(error.map { .failure($0) } ?? .success(()), "stop failed")
          if error == nil { self.guestEnded("guest killed") }
        }
      }
    case .save:
      guard machine.state == .paused else { return reply(refusal(request.command)) }
      let url = URL(filePath: request.path ?? "")
      machine.saveMachineStateTo(url: url) { error in
        MainActor.assumeIsolated {
          done(error.map { .failure($0) } ?? .success(()), "save failed")
          if error == nil { self.record("guest state saved to \(url.path)") }
        }
      }
    case .restore:
      guard machine.state == .stopped else { return reply(refusal(request.command)) }
      let url = URL(filePath: request.path ?? "")
      machine.restoreMachineStateFrom(url: url) { error in
        MainActor.assumeIsolated {
          if error == nil { self.hasRun = true }
          done(error.map { .failure($0) } ?? .success(()), "restore failed")
          if error == nil { self.record("guest state restored from \(url.path)") }
        }
      }
    case .exit:
      if machine.canStop {
        machine.stop { _ in
          MainActor.assumeIsolated {
            reply(.success(self.state, pid: self.pid))
            self.finish("runner exit requested")
          }
        }
      } else {
        reply(.success(state, pid: pid))
        finish("runner exit requested")
      }
    }
  }

  private func refusal(_ command: ControlCommand) -> ControlResponse {
    let needs =
      switch command {
      case .pause, .stop, .kill: "running"
      case .resume, .save: "paused"
      case .restore: "stopped (a runner started with --hold)"
      case .status, .exit: "any state"
      }
    return .failure(
      VMLabError(
        code: .wrongState,
        message: "The guest is \(state.rawValue); \(command.rawValue) needs it \(needs)",
        hint: "Check status and send a command the state allows.",
        data: ["state": .string(state.rawValue), "command": .string(command.rawValue)]),
      state: state)
  }

  /// The guest stopped after running: the runner has nothing left to serve.
  func guestEnded(_ why: String) {
    guard hasRun else { return }
    finish(why)
  }

  /// Logs, then exits shortly so pending replies reach their clients.
  func finish(_ why: String) {
    guard !exiting else { return }
    exiting = true
    record("runner exiting: \(why)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      Runner.cleanUp(self.paths)
      Foundation.exit(0)
    }
  }

  private func record(_ message: String) {
    logger.info("\(message)")
    let events = events
    Task { try? await events.append(.lifecycle, "vz: " + message) }
  }

  /// Removes the socket and pid file, if they are still this process's.
  nonisolated static func cleanUp(_ paths: VZRunnerPaths) {
    guard paths.recordedPID() == getpid() else { return }
    unlink(paths.controlSocket.path)
    unlink(paths.pidFile.path)
  }

  /// Writes the startup error line the launcher reads from `vz.log`, cleans up and exits 1.
  nonisolated static func fatal(_ error: VMLabError, paths: VZRunnerPaths) -> Never {
    let json = (try? JSONEncoder().encode(error)).map { String(decoding: $0, as: UTF8.self) }
    FileHandle.standardError.write(
      Data((VZRunnerLauncher.fatalPrefix + (json ?? "{}") + "\n").utf8))
    cleanUp(paths)
    Foundation.exit(1)
  }
}

extension Runner: @preconcurrency VZVirtualMachineDelegate {
  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    guestEnded("guest stopped")
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
    logger.error("guest stopped with error: \(error.localizedDescription)")
    hasRun = true
    guestEnded("guest stopped with error: \(error.localizedDescription)")
  }
}
