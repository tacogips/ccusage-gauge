import Foundation
@preconcurrency import Network

public struct StaticAssetResolver: Sendable {
  public let explicitRoot: URL?
  public let executableURL: URL

  public init(explicitRoot: URL? = nil, executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0])) {
    self.explicitRoot = explicitRoot
    self.executableURL = executableURL
  }

  public func roots() -> [URL] {
    if let explicitRoot { return [explicitRoot] }
    var candidates: [URL] = []
    let executableDirectory = executableURL.deletingLastPathComponent()
    if let entries = try? FileManager.default.contentsOfDirectory(at: executableDirectory, includingPropertiesForKeys: nil) {
      candidates.append(contentsOf: entries.filter { $0.pathExtension == "bundle" }.map { $0.appendingPathComponent("Web", isDirectory: true) })
    }
    if let mainResources = Bundle.main.resourceURL { candidates.append(mainResources.appendingPathComponent("Web", isDirectory: true)) }
    candidates.append(executableDirectory.appendingPathComponent("../share/ccusage-gauge/web", isDirectory: true).standardizedFileURL)
    candidates.append(executableDirectory.appendingPathComponent("../Resources/Web", isDirectory: true).standardizedFileURL)
    return candidates
  }

  public func resolve(path: String) -> URL? {
    let requested = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
    guard !requested.contains("..") else { return nil }
    for root in roots() {
      let candidate = root.appendingPathComponent(requested)
      if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
      let index = root.appendingPathComponent("index.html")
      if !path.hasPrefix("/api/"), FileManager.default.isReadableFile(atPath: index.path) { return index }
    }
    return nil
  }
}

public struct HTTPResponse: Sendable {
  public let status: Int
  public let contentType: String
  public let body: Data

  public init(status: Int, contentType: String, body: Data) {
    self.status = status
    self.contentType = contentType
    self.body = body
  }
}

public struct DashboardRouter: Sendable {
  public typealias SnapshotProvider = @Sendable () async throws -> CostSnapshot
  private let snapshotProvider: SnapshotProvider
  private let queryService: DashboardQueryService
  private let assetResolver: StaticAssetResolver

  public init(snapshotProvider: @escaping SnapshotProvider, queryService: DashboardQueryService = DashboardQueryService(), assetResolver: StaticAssetResolver) {
    self.snapshotProvider = snapshotProvider
    self.queryService = queryService
    self.assetResolver = assetResolver
  }

  public func route(target: String, method: String = "GET") async -> HTTPResponse {
    guard method == "GET" else { return errorResponse(status: 405, code: "method_not_allowed", message: "Only GET is supported") }
    guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
      return errorResponse(status: 400, code: "invalid_request", message: "Invalid request target")
    }
    let path = components.path
    if path.hasPrefix("/api/") {
      if path == "/api/health" {
        return HTTPResponse(status: 200, contentType: "application/json", body: Data("{\"status\":\"ok\"}".utf8))
      }
      do {
        let snapshot = try await snapshotProvider()
        switch path {
        case "/api/recent":
          let limit = components.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 48
          guard (1...500).contains(limit) else { return errorResponse(status: 400, code: "invalid_limit", message: "limit must be 1...500") }
          return json(queryService.recent(snapshot: snapshot, limit: limit))
        case "/api/day":
          guard let text = components.queryItems?.first(where: { $0.name == "date" })?.value,
                let date = queryService.parseDay(text) else {
            return errorResponse(status: 400, code: "invalid_date", message: "date must use YYYY-MM-DD")
          }
          return json(queryService.day(snapshot: snapshot, date: date))
        case "/api/period":
          let range = components.queryItems?.first(where: { $0.name == "range" })?.value ?? "today"
          if range == "custom" {
            guard let startText = components.queryItems?.first(where: { $0.name == "start" })?.value,
                  let endText = components.queryItems?.first(where: { $0.name == "end" })?.value,
                  let startDate = queryService.parseDay(startText),
                  let endDate = queryService.parseDay(endText) else {
              return errorResponse(status: 400, code: "invalid_custom_range", message: "custom range requires start and end dates in YYYY-MM-DD format")
            }
            return json(try queryService.period(snapshot: snapshot, startDate: startDate, endDate: endDate))
          }
          return json(try queryService.period(snapshot: snapshot, range: range))
        case "/api/metrics":
          let range = components.queryItems?.first(where: { $0.name == "range" })?.value ?? "today"
          if range == "custom" {
            guard let startText = components.queryItems?.first(where: { $0.name == "start" })?.value,
                  let endText = components.queryItems?.first(where: { $0.name == "end" })?.value,
                  let startDate = queryService.parseDay(startText),
                  let endDate = queryService.parseDay(endText) else {
              return errorResponse(status: 400, code: "invalid_custom_range", message: "custom range requires start and end dates in YYYY-MM-DD format")
            }
            return json(try queryService.metrics(snapshot: snapshot, range: range, startDate: startDate, endDate: endDate))
          }
          return json(try queryService.metrics(snapshot: snapshot, range: range))
        case "/api/cost-series":
          let range = components.queryItems?.first(where: { $0.name == "range" })?.value ?? "today"
          let granularity = components.queryItems?.first(where: { $0.name == "granularity" })?.value ?? "hourly"
          if range == "custom" {
            guard let startText = components.queryItems?.first(where: { $0.name == "start" })?.value,
                  let endText = components.queryItems?.first(where: { $0.name == "end" })?.value,
                  let startDate = queryService.parseDay(startText),
                  let endDate = queryService.parseDay(endText) else {
              return errorResponse(status: 400, code: "invalid_custom_range", message: "custom range requires start and end dates in YYYY-MM-DD format")
            }
            return json(try queryService.costSeries(snapshot: snapshot, granularity: granularity, range: range, startDate: startDate, endDate: endDate))
          }
          return json(try queryService.costSeries(snapshot: snapshot, granularity: granularity, range: range))
        case "/api/budget": return json(queryService.budget(snapshot: snapshot))
        default: return errorResponse(status: 404, code: "not_found", message: "API route not found")
        }
      } catch DashboardQueryError.invalidRange {
        return errorResponse(status: 400, code: "invalid_range", message: "range must be today, yesterday, week, or month")
      } catch DashboardQueryError.invalidCustomRange {
        return errorResponse(status: 400, code: "invalid_custom_range", message: "custom range start must not be after end")
      } catch DashboardQueryError.invalidGranularity {
        return errorResponse(status: 400, code: "invalid_granularity", message: "granularity must be hourly or daily")
      } catch {
        return errorResponse(status: 503, code: "usage_unavailable", message: "Usage data is temporarily unavailable")
      }
    }
    guard let file = assetResolver.resolve(path: path), let data = try? Data(contentsOf: file) else {
      return errorResponse(status: 503, code: "assets_missing", message: "Dashboard assets are not installed")
    }
    return HTTPResponse(status: 200, contentType: Self.contentType(for: file.pathExtension), body: data)
  }

  private func json<T: Encodable>(_ value: T) -> HTTPResponse {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let body = try? encoder.encode(value) else { return errorResponse(status: 500, code: "encoding_failed", message: "Response encoding failed") }
    return HTTPResponse(status: 200, contentType: "application/json", body: body)
  }

  private func errorResponse(status: Int, code: String, message: String) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]], options: [.sortedKeys])) ?? Data()
    return HTTPResponse(status: status, contentType: "application/json", body: body)
  }

  private static func contentType(for extensionName: String) -> String {
    switch extensionName.lowercased() {
    case "html": "text/html; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "js": "text/javascript; charset=utf-8"
    case "svg": "image/svg+xml"
    default: "application/octet-stream"
    }
  }
}

public final class DashboardHTTPServer: @unchecked Sendable {
  private let router: DashboardRouter
  private let queue = DispatchQueue(label: "ccusage-gauge.http")
  private let lock = NSLock()
  private var listener: NWListener?

  public init(router: DashboardRouter) { self.router = router }

  public func start(port: UInt16) throws {
    lock.lock()
    defer { lock.unlock() }
    guard listener == nil else { return }
    guard let networkPort = NWEndpoint.Port(rawValue: port) else { throw HTTPServerError.invalidPort }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: networkPort)
    let created = try NWListener(using: parameters)
    created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    created.stateUpdateHandler = { state in
      if case .failed = state { created.cancel() }
    }
    created.start(queue: queue)
    listener = created
  }

  public func stop() {
    lock.lock()
    let current = listener
    listener = nil
    lock.unlock()
    current?.cancel()
  }

  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return listener != nil
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
      guard let self, let data, error == nil,
            let request = String(data: data, encoding: .utf8),
            let firstLine = request.split(separator: "\r\n").first else {
        connection.cancel()
        return
      }
      let parts = firstLine.split(separator: " ")
      guard parts.count >= 2 else { connection.cancel(); return }
      let method = String(parts[0])
      let target = String(parts[1])
      Task {
        let response = await self.router.route(target: target, method: method)
        self.send(response, through: connection)
      }
    }
  }

  private func send(_ response: HTTPResponse, through connection: NWConnection) {
    let reason: String = switch response.status {
    case 200: "OK"
    case 400: "Bad Request"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 503: "Service Unavailable"
    default: "Internal Server Error"
    }
    let header = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
    var data = Data(header.utf8)
    data.append(response.body)
    connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
  }
}

public enum HTTPServerError: Error, Sendable { case invalidPort }
