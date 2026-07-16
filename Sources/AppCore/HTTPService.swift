import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

public actor DashboardSnapshotCache {
  public typealias Loader = @Sendable () async throws -> CostSnapshot

  private let loader: Loader
  private let maxAgeSeconds: TimeInterval
  private let now: @Sendable () -> Date
  private var latest: CostSnapshot?
  private var loadedAt: Date?
  private var inFlight: Task<CostSnapshot, Error>?

  public init(
    maxAgeSeconds: TimeInterval = 1,
    now: @escaping @Sendable () -> Date = Date.init,
    loader: @escaping Loader
  ) {
    self.maxAgeSeconds = max(0, maxAgeSeconds)
    self.now = now
    self.loader = loader
  }

  public func snapshot(forceRefresh: Bool = false) async throws -> CostSnapshot {
    let requestedAt = now()
    if !forceRefresh, let latest, let loadedAt,
       requestedAt.timeIntervalSince(loadedAt) <= maxAgeSeconds {
      return latest
    }
    if let inFlight { return try await inFlight.value }

    let task = Task { try await loader() }
    inFlight = task
    do {
      let snapshot = try await task.value
      latest = snapshot
      loadedAt = now()
      inFlight = nil
      return snapshot
    } catch {
      inFlight = nil
      throw error
    }
  }
}

public struct DashboardRouter: Sendable {
  public typealias SnapshotProvider = @Sendable () async throws -> CostSnapshot
  private let snapshotCache: DashboardSnapshotCache
  private let queryService: DashboardQueryService
  private let assetResolver: StaticAssetResolver

  public init(
    snapshotProvider: @escaping SnapshotProvider,
    snapshotCacheMaxAgeSeconds: TimeInterval = 60,
    queryService: DashboardQueryService = DashboardQueryService(),
    assetResolver: StaticAssetResolver
  ) {
    snapshotCache = DashboardSnapshotCache(maxAgeSeconds: snapshotCacheMaxAgeSeconds, loader: snapshotProvider)
    self.queryService = queryService
    self.assetResolver = assetResolver
  }

  public func preloadSnapshot() async {
    _ = try? await snapshotCache.snapshot()
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
        if path == "/api/refresh" {
          _ = try await snapshotCache.snapshot(forceRefresh: true)
          return json(["status": "ok"])
        }
        let snapshot = try await snapshotCache.snapshot()
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
        return errorResponse(status: 400, code: "invalid_range", message: "range must be recent12h, today, yesterday, week, month, or custom")
      } catch DashboardQueryError.invalidCustomRange {
        return errorResponse(status: 400, code: "invalid_custom_range", message: "custom range start must not be after end")
      } catch DashboardQueryError.invalidGranularity {
        return errorResponse(status: 400, code: "invalid_granularity", message: "granularity must be 15min, hourly, 6hour, or daily")
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
  private let acceptQueue = DispatchQueue(label: "ccusage-gauge.http.accept")
  private let clientQueue = DispatchQueue(label: "ccusage-gauge.http.client", attributes: .concurrent)
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var listenerGeneration: UInt64 = 0

  public init(router: DashboardRouter) { self.router = router }

  public func start(port: UInt16) throws {
    lock.lock()
    defer { lock.unlock() }
    guard listener < 0 else { return }
    guard port > 0 else { throw HTTPServerError.invalidPort }

    let descriptor = socket(AF_INET, Self.streamSocketType, 0)
    guard descriptor >= 0 else { throw HTTPServerError.socketFailure(errno) }
    var reuseAddress: Int32 = 1
    guard setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_REUSEADDR,
      &reuseAddress,
      socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
      Self.closeSocket(descriptor)
      throw HTTPServerError.socketFailure(errno)
    }

    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0, listen(descriptor, SOMAXCONN) == 0 else {
      let code = errno
      Self.closeSocket(descriptor)
      throw HTTPServerError.socketFailure(code)
    }

    listenerGeneration &+= 1
    let generation = listenerGeneration
    listener = descriptor
    acceptQueue.async { [weak self] in self?.acceptConnections(from: descriptor, generation: generation) }
    Task { await router.preloadSnapshot() }
  }

  public func stop() {
    lock.lock()
    let descriptor = listener
    listener = -1
    listenerGeneration &+= 1
    lock.unlock()
    guard descriptor >= 0 else { return }
    Self.closeSocket(descriptor)
  }

  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return listener >= 0
  }

  private func acceptConnections(from descriptor: Int32, generation: UInt64) {
    while true {
      guard isCurrentListener(descriptor, generation: generation) else { return }
      let client = accept(descriptor, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        clearListener(descriptor, generation: generation)
        return
      }
      Self.configureClient(client)
      clientQueue.async { [weak self] in
        guard let self else {
          Self.closeSocket(client)
          return
        }
        self.receiveRequest(from: client)
      }
    }
  }

  private func isCurrentListener(_ descriptor: Int32, generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return listener == descriptor && listenerGeneration == generation
  }

  private func clearListener(_ descriptor: Int32, generation: UInt64) {
    lock.lock()
    let ownsListener = listener == descriptor && listenerGeneration == generation
    if ownsListener {
      listener = -1
      listenerGeneration &+= 1
    }
    lock.unlock()
    if ownsListener { Self.closeSocket(descriptor) }
  }

  private func receiveRequest(from descriptor: Int32) {
    guard let request = Self.readRequest(from: descriptor) else {
      Self.closeSocket(descriptor)
      return
    }
    let parts = request.split(separator: " ")
    guard parts.count >= 2 else {
      Self.closeSocket(descriptor)
      return
    }
    let method = String(parts[0])
    let target = String(parts[1])
    let router = router
    Task {
      let response = await router.route(target: target, method: method)
      Self.send(response, through: descriptor)
      Self.closeSocket(descriptor)
    }
  }

  private static func readRequest(from descriptor: Int32) -> String? {
    let headerTerminator = Data("\r\n\r\n".utf8)
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while received.count < 16_384 {
      let count = buffer.withUnsafeMutableBytes { bytes in
        recv(descriptor, bytes.baseAddress, bytes.count, 0)
      }
      if count > 0 {
        received.append(contentsOf: buffer.prefix(count))
        if received.range(of: headerTerminator) != nil { break }
      } else if count == 0 {
        return nil
      } else if errno != EINTR {
        return nil
      }
    }
    guard received.range(of: headerTerminator) != nil,
          let request = String(data: received, encoding: .utf8) else { return nil }
    return request.components(separatedBy: "\r\n")[0]
  }

  private static func send(_ response: HTTPResponse, through descriptor: Int32) {
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
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = systemSend(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
        } else if count < 0, errno == EINTR {
          continue
        } else {
          return
        }
      }
    }
  }

  private static func configureClient(_ descriptor: Int32) {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size)
    )
    _ = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_SNDTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size)
    )
    #if canImport(Darwin)
    var noSigPipe: Int32 = 1
    _ = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSigPipe,
      socklen_t(MemoryLayout<Int32>.size)
    )
    #endif
  }

  private static func closeSocket(_ descriptor: Int32) {
    guard descriptor >= 0 else { return }
    _ = systemShutdown(descriptor)
    systemClose(descriptor)
  }

  private static var streamSocketType: Int32 {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
  }
}

public enum HTTPServerError: Error, Sendable {
  case invalidPort
  case socketFailure(Int32)
}

private var shutdownBoth: Int32 {
  #if canImport(Glibc)
  Int32(SHUT_RDWR)
  #else
  SHUT_RDWR
  #endif
}

private func systemSend(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
  #if canImport(Glibc)
  Glibc.send(descriptor, buffer, count, Int32(MSG_NOSIGNAL))
  #else
  Darwin.send(descriptor, buffer, count, 0)
  #endif
}

private func systemShutdown(_ descriptor: Int32) -> Int32 {
  #if canImport(Glibc)
  Glibc.shutdown(descriptor, shutdownBoth)
  #else
  Darwin.shutdown(descriptor, shutdownBoth)
  #endif
}

private func systemClose(_ descriptor: Int32) {
  #if canImport(Glibc)
  _ = Glibc.close(descriptor)
  #else
  _ = Darwin.close(descriptor)
  #endif
}
