import Foundation
import Logging
import MCP
import VMLabCore

#if canImport(System)
  import System
#else
  @preconcurrency import SystemPackage
#endif

/// The MCP server on the official Swift SDK: `initialize` and `ping` (the SDK's), `tools/list`
/// (the built tools, `ToolHandlers.specs`) and `tools/call` (`ToolHandlers.call`), with
/// `notifications/progress` for calls that carry a progress token. `notifications/cancelled`
/// cancels the Swift task of that call (the SDK tracks it by request id); the handler stops, and
/// no response is sent. A `VMLabError` is a result with
/// `isError: true` and the Appendix D object as its text; an unknown tool is a JSON-RPC error.
public enum VMLabServer {
  /// The `serverInfo.name` sent in `initialize`.
  public static let name = "vmlab"

  static let logger = Logger(label: "vmlab.mcp")

  /// Runs the server on the file descriptors `input` and `output` (stdin and stdout by default)
  /// until `input` reaches end of file. Reconciles the store first (Lifecycle.swift), so records
  /// match their engine processes before the first call.
  /// On the way out it ends this process's background-job readers (`jobs`); the jobs keep
  /// running in their guests.
  public static func run(
    context: ToolContext, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
    jobs: ExecJobs = .shared
  ) async throws {
    do {
      for change in try await context.store.reconcile() {
        logger.info(
          "reconciled \(change.id): \(change.from.rawValue) -> \(change.to.rawValue) (\(change.reason))"
        )
      }
    } catch {
      logger.warning("reconcile at start failed: \(error.message)")
    }
    // Watch the guests already running (panics, QMP events, dead peers) without delaying serving.
    let manager = context.manager
    Task { await manager.monitorLiveGuests() }
    let server = await makeServer(context: context)
    let transport = StdioTransport(
      input: FileDescriptor(rawValue: input), output: FileDescriptor(rawValue: output),
      logger: Logger(label: "vmlab.mcp.stdio"))
    logger.info(
      "serving \(ToolHandlers.specs.count) tools over stdio, home \(context.home.path)")
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
    await server.stop()
    await jobs.stopReaders()
    logger.info("stdin closed; server stopped")
  }

  /// A server with the vmlab handlers registered, not yet started.
  static func makeServer(context: ToolContext) async -> Server {
    let server = Server(
      name: name, version: VMLabMCP.version,
      capabilities: .init(tools: .init(listChanged: false)))
    await register(on: server, context: context)
    return server
  }

  /// Registers `tools/list` and `tools/call`.
  static func register(on server: Server, context: ToolContext) async {
    await server.withMethodHandler(ListTools.self) { _ in
      ListTools.Result(tools: ToolHandlers.specs.map(tool))
    }
    await server.withMethodHandler(CallTool.self) { [weak server] params in
      guard ToolHandlers.handler(named: params.name) != nil else {
        throw MCPError.invalidParams(
          "Unknown tool: \(params.name). The tools are: "
            + ToolHandlers.specs.map(\.name).joined(separator: ", ") + ".")
      }
      var callContext = context
      if let token = params._meta?.progressToken, let server {
        callContext.progress = ToolProgress { progress, total, message in
          let notification = ProgressNotification.message(
            .init(progressToken: token, progress: progress, total: total, message: message))
          do {
            try await server.notify(notification)
          } catch {
            logger.debug("progress notification not sent: \(error)")
          }
        }
      }
      let arguments = params.arguments.map { JSONValue.object($0.mapValues(jsonValue)) } ?? .null
      do {
        let result = try await ToolHandlers.call(
          params.name, arguments: arguments, context: callContext)
        // A cancelled request gets no response (MCP); the SDK drops it on CancellationError.
        try Task.checkCancellation()
        return callResult(result)
      } catch is CancellationError {
        logger.info("\(params.name) cancelled")
        throw CancellationError()
      } catch let error as VMLabError {
        if Task.isCancelled {
          logger.info("\(params.name) cancelled: \(error.message)")
          throw CancellationError()
        }
        logger.info("\(params.name) refused: \(error.code.rawValue): \(error.message)")
        return refusal(error)
      } catch {
        let wrapped = ToolRendering.internalError(error, doing: params.name)
        logger.error("\(params.name) failed: \(error)")
        return refusal(wrapped)
      }
    }
  }

  /// The `tools/list` entry of one spec.
  static func tool(_ spec: ToolSpec) -> Tool {
    Tool(name: spec.name, description: spec.description, inputSchema: value(spec.inputSchema))
  }

  /// A handler's result as MCP content: one text block of JSON, then one image block per image.
  static func callResult(_ result: ToolResult) -> CallTool.Result {
    let images: [Tool.Content] = result.images.map {
      .image(
        data: $0.data.base64EncodedString(), mimeType: $0.mimeType, annotations: nil, _meta: nil)
    }
    return CallTool.Result(content: [text(result.text)] + images, isError: false)
  }

  /// A refusal: `isError: true` with the Appendix D object as the only text block.
  static func refusal(_ error: VMLabError) -> CallTool.Result {
    CallTool.Result(content: [text(ToolRendering.json(error))], isError: true)
  }

  static func text(_ text: String) -> Tool.Content {
    .text(text: text, annotations: nil, _meta: nil)
  }

  /// Core's `JSONValue` as the SDK's `Value`; integral numbers become integers so schemas read
  /// `"minimum": 1`, not `1.0`.
  static func value(_ json: JSONValue) -> Value {
    switch json {
    case .null: .null
    case .bool(let bool): .bool(bool)
    case .number(let number):
      if let int = Int(exactly: number) { .int(int) } else { .double(number) }
    case .string(let string): .string(string)
    case .array(let array): .array(array.map(value))
    case .object(let object): .object(object.mapValues(value))
    }
  }

  /// The SDK's `Value` as Core's `JSONValue`. Binary data arrives as its data URL string.
  static func jsonValue(_ value: Value) -> JSONValue {
    switch value {
    case .null: .null
    case .bool(let bool): .bool(bool)
    case .int(let int): .number(Double(int))
    case .double(let double): .number(double)
    case .string(let string): .string(string)
    case .data(let mimeType, let data):
      .string("data:\(mimeType ?? "application/octet-stream");base64,\(data.base64EncodedString())")
    case .array(let array): .array(array.map(jsonValue))
    case .object(let object): .object(object.mapValues(jsonValue))
    }
  }
}
