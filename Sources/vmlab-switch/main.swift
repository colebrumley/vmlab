// The user-space Ethernet switch for private segments: one process per segment.
import ArgumentParser
import Dispatch
import Foundation
import Logging
import VMLabCore
import VMLabSwitch

struct VMLabSwitchCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vmlab-switch",
    abstract: "Run the Ethernet switch for one private segment.",
    discussion: """
      Frames arrive on $VMLAB_HOME/segments/<name>/switch.sock (unix datagram); a connection to \
      stats.sock returns the counters as JSON. SIGTERM or SIGINT stops the switch and removes its \
      sockets.
      """)

  @Argument(help: "The segment name ([a-z0-9-], at most 32 characters).")
  var name: String

  func run() throws {
    let paths: SegmentPaths
    do {
      paths = try SegmentPaths(name: name)
    } catch let error as SwitchError {
      throw ValidationError(error.description)
    }
    let logger = Logger(label: "vmlab-switch")
    let server: SwitchServer
    do {
      server = try SwitchServer(paths: paths)
    } catch let error as SwitchError {
      logger.error("\(error.description)")
      throw ExitCode.failure
    }
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
      source.setEventHandler { server.stop() }
      source.resume()
      sources.append(source)
    }
    logger.info("switching segment \(name) on \(paths.switchSocket.path)")
    server.run()
    for source in sources { source.cancel() }
    logger.info("stopped")
  }
}

VMLabLogging.bootstrap()
VMLabSwitchCommand.main()
