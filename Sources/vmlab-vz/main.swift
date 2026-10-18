// The VZ runner: one process per Virtualization.framework guest, driven over a control socket.
import ArgumentParser
import Dispatch
import Foundation
import VMLabCore
import VMLabVZ
import Virtualization

struct VZRunnerCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vmlab-vz",
    abstract: "Run one Virtualization.framework guest.",
    subcommands: [Run.self, Capabilities.self])

  /// What Virtualization.framework supports on this host, for `HostProbe` (Core cannot ask it).
  struct Capabilities: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print the host's Virtualization.framework capabilities as JSON.")

    func run() throws {
      let supported = VZGenericPlatformConfiguration.isNestedVirtualizationSupported
      print("{\"\(HostProbe.nestedKey)\":\(supported)}")
    }
  }

  struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Boot the guest described by <vm-dir>/vz-config.json and serve control.sock.",
      discussion: """
        Writes <vm-dir>/vz.pid and answers newline-delimited JSON on <vm-dir>/control.sock \
        (status, pause, resume, stop, kill, save, restore, exit). The runner ignores SIGHUP \
        and runs in its own process group, so it outlives the process that launched it; SIGTERM \
        or SIGINT stops the guest, and the runner exits once the guest stops.
        """)

    @Argument(help: "The VM directory.")
    var vmDirectory: String

    @Flag(help: "Build the machine but do not start it (for restore).")
    var hold = false

    func run() throws {
      signal(SIGPIPE, SIG_IGN)
      let paths = VZRunnerPaths(vmDirectory: URL(filePath: vmDirectory).standardizedFileURL)
      let socket = paths.controlSocket.path
      if VZRunnerPaths.answers(socket) {
        Runner.fatal(
          VMLabError(
            code: .wrongState, message: "A VZ runner already serves \(paths.vmDirectory.path)",
            hint: "Attach to it, or send it exit first.", data: ["socket": .string(socket)]),
          paths: paths)
      }
      do {
        try "\(getpid())\n".write(to: paths.pidFile, atomically: true, encoding: .utf8)
      } catch {
        Runner.fatal(
          VMLabError(
            code: .internal, message: "Cannot write \(paths.pidFile.path): \(error)",
            hint: "Check that the VM directory is writable."), paths: paths)
      }
      let hold = hold
      MainActor.assumeIsolated {
        let built: BuiltMachine
        do throws(VMLabError) {
          built = try ConfigurationBuilder.build(
            try VZRunnerConfig.read(from: paths.config))
        } catch {
          Runner.fatal(error, paths: paths)
        }
        let runner = Runner(paths: paths, machine: built)
        let server: ControlServer
        do {
          server = try ControlServer(path: socket) { request, reply in
            DispatchQueue.main.async {
              MainActor.assumeIsolated { runner.handle(request, reply: reply) }
            }
          }
        } catch {
          Runner.fatal(
            VMLabError(
              code: .internal, message: "Cannot listen on \(socket): \(error)",
              hint: "Check the VM directory and that the path is under 104 bytes."), paths: paths)
        }
        server.start()
        signal(SIGHUP, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
          signal(sig, SIG_IGN)
          let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
          source.setEventHandler {
            MainActor.assumeIsolated {
              runner.handle(ControlRequest(.exit)) { _ in }
            }
          }
          source.resume()
          Signals.sources.append(source)
        }
        if !hold { runner.start() }
      }
      dispatchMain()
    }
  }
}

/// Keeps the signal sources alive for the life of the process.
@MainActor enum Signals {
  static var sources: [any DispatchSourceSignal] = []
}

extension VZRunnerPaths {
  /// Whether a runner already answers on `socket`.
  static func answers(_ socket: String) -> Bool {
    LivenessProbe.canConnect(unixSocket: socket)
  }
}

VMLabLogging.bootstrap()
VZRunnerCommand.main()
