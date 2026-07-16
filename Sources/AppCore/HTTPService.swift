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

public enum DashboardLoadPhase: String, Codable, Equatable, Sendable {
  case idle
  case loadingWeek
  case loadingHistory
  case loadingRange
  case refreshing
  case ready
  case failed
}

public struct DashboardLoadStatus: Codable, Equatable, Sendable {
  public let phase: DashboardLoadPhase
  public let message: String
  public let completed: Int
  public let total: Int
  public let isLoading: Bool
}

public actor DashboardSnapshotCache {
  public typealias Loader = @Sendable (Date?) async throws -> CostSnapshot
  public typealias ProgressiveLoader = @Sendable (Date?, SnapshotLoadProgressHandler?) async throws -> CostSnapshot

  private let loader: ProgressiveLoader
  private let maxAgeSeconds: TimeInterval
  private let now: @Sendable () -> Date
  private var latest: CostSnapshot?
  private var loadedAt: Date?
  private var coverageStart: Date?
  private var inFlight: Task<CostSnapshot, Error>?
  private var inFlightGeneration = 0
  private var inFlightStart: Date?
  private var inFlightRequestedAt: Date?
  private var historicalTask: Task<CostSnapshot, Error>?
  private var historicalGeneration = 0
  private var historicalStart: Date?
  private var historicalProgress = SnapshotLoadProgress(completed: 0, total: 1)
  private var loadStatus = DashboardLoadStatus(
    phase: .idle,
    message: "Waiting to load usage data",
    completed: 0,
    total: 1,
    isLoading: false
  )

  public init(
    maxAgeSeconds: TimeInterval = 1,
    now: @escaping @Sendable () -> Date = Date.init,
    loader: @escaping Loader
  ) {
    self.maxAgeSeconds = max(0, maxAgeSeconds)
    self.now = now
    self.loader = { date, _ in try await loader(date) }
  }

  public init(
    maxAgeSeconds: TimeInterval = 1,
    now: @escaping @Sendable () -> Date = Date.init,
    progressiveLoader: @escaping ProgressiveLoader
  ) {
    self.maxAgeSeconds = max(0, maxAgeSeconds)
    self.now = now
    loader = progressiveLoader
  }

  public func snapshot(earliestDate: Date? = nil, forceRefresh: Bool = false) async throws -> CostSnapshot {
    let requestedAt = now()
    let requiredStart = earliestDate
    if !forceRefresh, let latest, let loadedAt,
       requestedAt.timeIntervalSince(loadedAt) <= maxAgeSeconds,
       covers(requiredStart) {
      return latest
    }
    if let inFlight {
      let generation = inFlightGeneration
      let loadFrom = inFlightStart
      let startedAt = inFlightRequestedAt ?? requestedAt
      do {
        let snapshot = try await inFlight.value
        finish(snapshot, generation: generation, loadFrom: loadFrom, requestedAt: startedAt)
        if covers(requiredStart) { return snapshot }
        return try await self.snapshot(earliestDate: requiredStart)
      } catch {
        clearInFlight(generation: generation)
        markFailed()
        throw error
      }
    }
    if !forceRefresh,
       let requiredStart,
       let historicalTask,
       let historicalStart,
       historicalStart <= requiredStart {
      let generation = historicalGeneration
      do {
        let snapshot = try await historicalTask.value
        finishHistorical(snapshot, generation: generation, loadFrom: historicalStart)
        return snapshot
      } catch {
        clearHistorical(generation: generation)
        markFailed()
        throw error
      }
    }

    let loadFrom = requiredStart ?? coverageStart
    if latest == nil {
      loadStatus = DashboardLoadStatus(
        phase: .loadingWeek,
        message: "Loading this week",
        completed: 0,
        total: 1,
        isLoading: true
      )
    } else if forceRefresh {
      loadStatus = DashboardLoadStatus(
        phase: .refreshing,
        message: "Refreshing usage data",
        completed: 0,
        total: 1,
        isLoading: true
      )
    } else {
      loadStatus = DashboardLoadStatus(
        phase: .loadingRange,
        message: "Loading history by week",
        completed: 0,
        total: 1,
        isLoading: true
      )
    }
    inFlightGeneration += 1
    let generation = inFlightGeneration
    let isInitialLoad = latest == nil
    let task = Task {
      try await loader(loadFrom) { progress in
        await self.updateInFlightProgress(
          progress,
          generation: generation,
          isInitialLoad: isInitialLoad,
          forceRefresh: forceRefresh
        )
      }
    }
    inFlight = task
    inFlightStart = loadFrom
    inFlightRequestedAt = requestedAt
    do {
      let snapshot = try await task.value
      finish(snapshot, generation: generation, loadFrom: loadFrom, requestedAt: requestedAt)
      return snapshot
    } catch {
      clearInFlight(generation: generation)
      markFailed()
      throw error
    }
  }

  public func status() -> DashboardLoadStatus { loadStatus }

  public func clear() {
    inFlight?.cancel()
    inFlightGeneration += 1
    inFlight = nil
    inFlightStart = nil
    inFlightRequestedAt = nil
    historicalTask?.cancel()
    historicalGeneration += 1
    historicalTask = nil
    historicalStart = nil
    historicalProgress = SnapshotLoadProgress(completed: 0, total: 1)
    latest = nil
    loadedAt = nil
    coverageStart = nil
    loadStatus = DashboardLoadStatus(
      phase: .idle,
      message: "Cache cleared",
      completed: 0,
      total: 1,
      isLoading: false
    )
  }

  public func warmHistoricalCoverage() async throws -> CostSnapshot {
    startHistoricalWarm()
    guard let historicalTask, let historicalStart else {
      guard let latest else { throw CancellationError() }
      return latest
    }
    let generation = historicalGeneration
    do {
      let result = try await historicalTask.value
      finishHistorical(result, generation: generation, loadFrom: historicalStart)
      return result
    } catch {
      clearHistorical(generation: generation)
      markFailed()
      throw error
    }
  }

  public func startHistoricalWarm() {
    guard historicalTask == nil else { return }
    let requestedAt = now()
    let calendar = Calendar.current
    let currentMonthStart = calendar.dateInterval(of: .month, for: requestedAt)?.start
      ?? calendar.startOfDay(for: requestedAt)
    let previousMonthStart = calendar.date(byAdding: .month, value: -1, to: currentMonthStart)
      ?? currentMonthStart
    guard !covers(previousMonthStart) else {
      loadStatus = DashboardLoadStatus(
        phase: .ready,
        message: "Usage data is ready",
        completed: 1,
        total: 1,
        isLoading: false
      )
      return
    }
    historicalGeneration += 1
    let generation = historicalGeneration
    historicalStart = previousMonthStart
    historicalProgress = SnapshotLoadProgress(completed: 0, total: 1)
    historicalTask = Task(priority: .utility) {
      try await loader(previousMonthStart) { progress in
        await self.updateHistoricalProgress(progress, generation: generation)
      }
    }
  }

  private func finish(_ snapshot: CostSnapshot, generation: Int, loadFrom: Date?, requestedAt: Date) {
    guard generation == inFlightGeneration else { return }
    let replacesLatest = loadFrom.map { requestedStart in
      coverageStart.map { requestedStart <= $0 } ?? true
    } ?? (coverageStart == nil)
    if replacesLatest {
      latest = snapshot
    }
    loadedAt = now()
    if let loadFrom {
      coverageStart = min(coverageStart ?? defaultCoverageStart(at: requestedAt), loadFrom)
    } else if coverageStart == nil {
      coverageStart = defaultCoverageStart(at: requestedAt)
    }
    if loadStatus.phase == .loadingWeek {
      loadStatus = DashboardLoadStatus(
        phase: .loadingHistory,
        message: "Loading this month and previous month",
        completed: historicalProgress.completed,
        total: max(historicalProgress.total, 1),
        isLoading: true
      )
    } else if loadStatus.phase == .refreshing || loadStatus.phase == .loadingRange {
      loadStatus = DashboardLoadStatus(
        phase: .ready,
        message: "Usage data is ready",
        completed: loadStatus.total,
        total: loadStatus.total,
        isLoading: false
      )
    }
    clearInFlight(generation: generation)
  }

  private func markFailed() {
    loadStatus = DashboardLoadStatus(
      phase: .failed,
      message: "Usage data loading failed",
      completed: loadStatus.completed,
      total: loadStatus.total,
      isLoading: false
    )
  }

  private func updateInFlightProgress(
    _ progress: SnapshotLoadProgress,
    generation: Int,
    isInitialLoad: Bool,
    forceRefresh: Bool
  ) {
    guard generation == inFlightGeneration else { return }
    let total = max(progress.total, 1)
    let completed = progress.total == 0 ? 0 : progress.completed
    if isInitialLoad {
      loadStatus = DashboardLoadStatus(
        phase: .loadingWeek,
        message: "Loading this week",
        completed: completed,
        total: total,
        isLoading: true
      )
    } else if forceRefresh {
      loadStatus = DashboardLoadStatus(
        phase: .refreshing,
        message: "Refreshing usage data",
        completed: completed,
        total: total,
        isLoading: true
      )
    } else {
      loadStatus = DashboardLoadStatus(
        phase: .loadingRange,
        message: "Loading history by week",
        completed: completed,
        total: total,
        isLoading: true
      )
    }
  }

  private func updateHistoricalProgress(_ progress: SnapshotLoadProgress, generation: Int) {
    guard generation == historicalGeneration else { return }
    historicalProgress = progress
    guard latest != nil, loadStatus.phase == .loadingHistory else { return }
    loadStatus = DashboardLoadStatus(
      phase: .loadingHistory,
      message: "Loading this month and previous month",
      completed: progress.completed,
      total: max(progress.total, 1),
      isLoading: true
    )
  }

  private func finishHistorical(
    _ snapshot: CostSnapshot,
    generation: Int,
    loadFrom: Date
  ) {
    guard generation == historicalGeneration else { return }
    if coverageStart.map({ loadFrom <= $0 }) ?? true {
      latest = snapshot
    }
    loadedAt = now()
    coverageStart = min(coverageStart ?? loadFrom, loadFrom)
    if loadStatus.phase == .loadingHistory || loadStatus.phase == .loadingWeek {
      let total = max(historicalProgress.total, 1)
      loadStatus = DashboardLoadStatus(
        phase: .ready,
        message: "Usage data is ready",
        completed: total,
        total: total,
        isLoading: false
      )
    }
    clearHistorical(generation: generation)
  }

  private func clearHistorical(generation: Int) {
    guard generation == historicalGeneration else { return }
    historicalTask = nil
    historicalStart = nil
  }

  private func clearInFlight(generation: Int) {
    guard generation == inFlightGeneration else { return }
    inFlight = nil
    inFlightStart = nil
    inFlightRequestedAt = nil
  }

  private func defaultCoverageStart(at date: Date) -> Date {
    let calendar = Calendar.current
    return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
  }

  private func covers(_ requiredStart: Date?) -> Bool {
    guard let requiredStart else { return true }
    guard let coverageStart else { return false }
    return coverageStart <= requiredStart
  }
}

public struct DashboardRouter: Sendable {
  public typealias SnapshotProvider = @Sendable () async throws -> CostSnapshot
  public typealias RangeSnapshotProvider = @Sendable (Date?) async throws -> CostSnapshot
  public typealias ProgressiveRangeSnapshotProvider = @Sendable (Date?, SnapshotLoadProgressHandler?) async throws -> CostSnapshot
  public typealias CacheClearer = @Sendable () async -> Void
  private let snapshotCache: DashboardSnapshotCache
  private let queryService: DashboardQueryService
  private let assetResolver: StaticAssetResolver
  private let cacheClearer: CacheClearer

  public init(
    snapshotProvider: @escaping SnapshotProvider,
    snapshotCacheMaxAgeSeconds: TimeInterval = 60,
    queryService: DashboardQueryService = DashboardQueryService(),
    assetResolver: StaticAssetResolver,
    cacheClearer: @escaping CacheClearer = {}
  ) {
    snapshotCache = DashboardSnapshotCache(maxAgeSeconds: snapshotCacheMaxAgeSeconds) { _ in try await snapshotProvider() }
    self.queryService = queryService
    self.assetResolver = assetResolver
    self.cacheClearer = cacheClearer
  }

  public init(
    progressiveRangeSnapshotProvider: @escaping ProgressiveRangeSnapshotProvider,
    snapshotCacheMaxAgeSeconds: TimeInterval = 60,
    queryService: DashboardQueryService = DashboardQueryService(),
    assetResolver: StaticAssetResolver,
    cacheClearer: @escaping CacheClearer = {}
  ) {
    snapshotCache = DashboardSnapshotCache(
      maxAgeSeconds: snapshotCacheMaxAgeSeconds,
      progressiveLoader: progressiveRangeSnapshotProvider
    )
    self.queryService = queryService
    self.assetResolver = assetResolver
    self.cacheClearer = cacheClearer
  }

  public init(
    rangeSnapshotProvider: @escaping RangeSnapshotProvider,
    snapshotCacheMaxAgeSeconds: TimeInterval = 60,
    queryService: DashboardQueryService = DashboardQueryService(),
    assetResolver: StaticAssetResolver,
    cacheClearer: @escaping CacheClearer = {}
  ) {
    snapshotCache = DashboardSnapshotCache(maxAgeSeconds: snapshotCacheMaxAgeSeconds, loader: rangeSnapshotProvider)
    self.queryService = queryService
    self.assetResolver = assetResolver
    self.cacheClearer = cacheClearer
  }

  public func preloadSnapshot() async {
    await snapshotCache.startHistoricalWarm()
    _ = try? await snapshotCache.snapshot()
    _ = try? await snapshotCache.warmHistoricalCoverage()
  }

  public func route(target: String, method: String = "GET") async -> HTTPResponse {
    guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
      return errorResponse(status: 400, code: "invalid_request", message: "Invalid request target")
    }
    let path = components.path
    let isCacheClear = path == "/api/cache" && method == "DELETE"
    guard method == "GET" || isCacheClear else {
      return errorResponse(status: 405, code: "method_not_allowed", message: "Method is not supported for this route")
    }
    if path.hasPrefix("/api/") {
      if isCacheClear {
        await snapshotCache.clear()
        await cacheClearer()
        Task(priority: .utility) { await preloadSnapshot() }
        return json(["status": "ok"])
      }
      if path == "/api/health" {
        return HTTPResponse(status: 200, contentType: "application/json", body: Data("{\"status\":\"ok\"}".utf8))
      }
      if path == "/api/load-status" {
        return json(await snapshotCache.status())
      }
      do {
        if path == "/api/refresh" {
          _ = try await snapshotCache.snapshot(forceRefresh: true)
          return json(["status": "ok"])
        }
        let snapshot = try await snapshotCache.snapshot(earliestDate: requestedCoverageStart(for: path, components: components))
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

  private func requestedCoverageStart(for path: String, components: URLComponents) -> Date? {
    if path == "/api/day",
       let text = components.queryItems?.first(where: { $0.name == "date" })?.value {
      return queryService.parseDay(text)
    }
    guard ["/api/period", "/api/metrics", "/api/cost-series"].contains(path),
          let range = components.queryItems?.first(where: { $0.name == "range" })?.value else { return nil }
    if range == "custom",
       let text = components.queryItems?.first(where: { $0.name == "start" })?.value {
      return queryService.parseDay(text)
    }
    let now = Date()
    let calendar = queryService.calendar
    switch range {
    case "recent12h": return now.addingTimeInterval(-12 * 3_600)
    case "today": return calendar.startOfDay(for: now)
    case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
    case "week": return calendar.dateInterval(of: .weekOfYear, for: now)?.start
    case "month": return calendar.dateInterval(of: .month, for: now)?.start
    default: return nil
    }
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
