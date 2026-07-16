import Foundation

public struct CostSnapshot: Codable, Equatable, Sendable {
  public let generatedAt: Date
  public let activeBoundaryAt: Date
  public let costSinceResetUSD: Decimal
  public let budget: BudgetSummary
  public let resetCycle: ResetCycle
  public let points: [CCUsageCostRecord]
  public let dashboardMetrics: [CCUsageMetricRecord]
  public let dashboardSessions: [CCUsageSessionMetricRecord]

  public init(
    generatedAt: Date,
    activeBoundaryAt: Date,
    costSinceResetUSD: Decimal,
    budget: BudgetSummary,
    resetCycle: ResetCycle,
    points: [CCUsageCostRecord],
    dashboardMetrics: [CCUsageMetricRecord] = [],
    dashboardSessions: [CCUsageSessionMetricRecord] = []
  ) {
    self.generatedAt = generatedAt
    self.activeBoundaryAt = activeBoundaryAt
    self.costSinceResetUSD = costSinceResetUSD
    self.budget = budget
    self.resetCycle = resetCycle
    self.points = points
    self.dashboardMetrics = dashboardMetrics
    self.dashboardSessions = dashboardSessions
  }
}

public struct SnapshotService: Sendable {
  public let stateStore: StateStore
  public let client: CCUsageClient
  public let calculator: ResetWindowCalculator

  public init(stateStore: StateStore, client: CCUsageClient, calculator: ResetWindowCalculator = ResetWindowCalculator()) {
    self.stateStore = stateStore
    self.client = client
    self.calculator = calculator
  }

  public func snapshot(now: Date = Date(), defaultCycle: ResetCycle = .daily) async throws -> CostSnapshot {
    let loaded = try await stateStore.load(defaultCycle: defaultCycle)
    let state = try calculator.validatedState(loaded, now: now)
    if state != loaded { try await stateStore.save(state) }
    guard let baseline = state.baseline else { throw SnapshotError.missingBaseline }
    async let blockRecords = client.blocks()
    async let metricRecords = client.detailedDaily()
    async let sessionRecords = client.detailedSessions()
    let points = try await blockRecords
    let dashboardMetrics = try await metricRecords
    let dashboardSessions = try await sessionRecords
    let cost = points
      .filter { $0.timestamp >= baseline.activeBoundaryAt && $0.timestamp <= now }
      .reduce(Decimal.zero) { $0 + $1.costUSD }
    return CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: baseline.activeBoundaryAt,
      costSinceResetUSD: cost,
      budget: BudgetSummary(spentUSD: cost, budgetUSD: state.budgetUSD),
      resetCycle: state.resetCycle,
      points: points,
      dashboardMetrics: dashboardMetrics,
      dashboardSessions: dashboardSessions
    )
  }
}

public enum SnapshotError: Error, Sendable { case missingBaseline }

public actor SnapshotCache {
  public private(set) var latest: CostSnapshot?
  public private(set) var lastError: String?
  private var refreshing = false

  public init() {}

  public func refresh(using service: SnapshotService, now: Date = Date()) async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    do {
      latest = try await service.snapshot(now: now)
      lastError = nil
    } catch {
      lastError = String(describing: error)
    }
  }
}

public actor PollingService {
  public let cache: SnapshotCache
  private let service: SnapshotService
  private var task: Task<Void, Never>?

  public init(service: SnapshotService, cache: SnapshotCache = SnapshotCache()) {
    self.service = service
    self.cache = cache
  }

  public func start(intervalSeconds: Int) {
    guard task == nil else { return }
    let service = self.service
    let cache = self.cache
    task = Task {
      while !Task.isCancelled {
        await cache.refresh(using: service)
        do { try await Task.sleep(for: .seconds(max(intervalSeconds, 1))) } catch { break }
      }
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
  }
}

public struct RecentPoint: Codable, Equatable, Sendable {
  public let timestamp: Date
  public let costUSD: Decimal
  public let models: [String]
}

public struct RecentResponse: Codable, Equatable, Sendable { public let series: [RecentPoint]; public let totalUSD: Decimal }
public struct DayResponse: Codable, Equatable, Sendable { public let date: String; public let series: [RecentPoint]; public let totalUSD: Decimal }
public struct PeriodResponse: Codable, Equatable, Sendable { public let range: String; public let series: [RecentPoint]; public let totalUSD: Decimal }
public struct BudgetResponse: Codable, Equatable, Sendable {
  public let budgetUSD: Decimal?
  public let spentUSD: Decimal
  public let remainingUSD: Decimal?
  public let overageUSD: Decimal
  public let usagePercentage: Decimal?
  public let visualFraction: Decimal?
  public let resetCycle: String
  public let activeBoundaryAt: Date
}

public struct DashboardMetricTotals: Codable, Equatable, Sendable {
  public let costUSD: Decimal
  public let inputTokens: Int
  public let outputTokens: Int
  public let cacheCreationTokens: Int
  public let cacheReadTokens: Int
  public let totalTokens: Int
}

public struct DashboardMetricsResponse: Codable, Equatable, Sendable {
  public let range: String
  public let rows: [CCUsageMetricRecord]
  public let totals: DashboardMetricTotals
}

public struct DashboardCostRow: Codable, Equatable, Sendable {
  public let timestamp: Date
  public let agent: String
  public let model: String
  public let costUSD: Decimal
}

public struct DashboardCostResponse: Codable, Equatable, Sendable {
  public let range: String
  public let granularity: String
  public let rows: [DashboardCostRow]
  public let totalUSD: Decimal
}

public struct DashboardQueryService: Sendable {
  public var calendar: Calendar

  public init(calendar: Calendar = .current) { self.calendar = calendar }

  public func recent(snapshot: CostSnapshot, limit: Int = 48) -> RecentResponse {
    let points = snapshot.points.suffix(max(1, min(limit, 500))).map {
      RecentPoint(timestamp: $0.timestamp, costUSD: $0.costUSD, models: $0.models)
    }
    return RecentResponse(series: points, totalUSD: points.reduce(0) { $0 + $1.costUSD })
  }

  public func day(snapshot: CostSnapshot, date: Date) -> DayResponse {
    let points = snapshot.points.filter { calendar.isDate($0.timestamp, inSameDayAs: date) }.map {
      RecentPoint(timestamp: $0.timestamp, costUSD: $0.costUSD, models: $0.models)
    }
    return DayResponse(date: formatDay(date), series: points, totalUSD: points.reduce(0) { $0 + $1.costUSD })
  }

  public func period(snapshot: CostSnapshot, range: String, now: Date = Date()) throws -> PeriodResponse {
    let interval: DateInterval
    switch range {
    case "today": interval = DateInterval(start: calendar.startOfDay(for: now), end: now)
    case "yesterday":
      let today = calendar.startOfDay(for: now)
      guard let start = calendar.date(byAdding: .day, value: -1, to: today) else { throw DashboardQueryError.invalidRange }
      interval = DateInterval(start: start, end: today)
    case "week": guard let value = calendar.dateInterval(of: .weekOfYear, for: now) else { throw DashboardQueryError.invalidRange }; interval = value
    case "month": guard let value = calendar.dateInterval(of: .month, for: now) else { throw DashboardQueryError.invalidRange }; interval = value
    default: throw DashboardQueryError.invalidRange
    }
    let points = snapshot.points.filter { isWithin($0.timestamp, interval: interval) }.map {
      RecentPoint(timestamp: $0.timestamp, costUSD: $0.costUSD, models: $0.models)
    }
    return PeriodResponse(range: range, series: points, totalUSD: points.reduce(0) { $0 + $1.costUSD })
  }

  public func period(snapshot: CostSnapshot, startDate: Date, endDate: Date) throws -> PeriodResponse {
    let start = calendar.startOfDay(for: startDate)
    let endDay = calendar.startOfDay(for: endDate)
    guard start <= endDay,
          let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay) else {
      throw DashboardQueryError.invalidCustomRange
    }
    let points = snapshot.points
      .filter { $0.timestamp >= start && $0.timestamp < endExclusive }
      .map { RecentPoint(timestamp: $0.timestamp, costUSD: $0.costUSD, models: $0.models) }
    return PeriodResponse(range: "custom", series: points, totalUSD: points.reduce(0) { $0 + $1.costUSD })
  }

  public func budget(snapshot: CostSnapshot) -> BudgetResponse {
    BudgetResponse(
      budgetUSD: snapshot.budget.budgetUSD,
      spentUSD: snapshot.budget.spentUSD,
      remainingUSD: snapshot.budget.remainingUSD,
      overageUSD: snapshot.budget.overageUSD,
      usagePercentage: snapshot.budget.usagePercentage,
      visualFraction: snapshot.budget.visualFraction,
      resetCycle: snapshot.resetCycle.label,
      activeBoundaryAt: snapshot.activeBoundaryAt
    )
  }

  public func metrics(
    snapshot: CostSnapshot,
    range: String,
    startDate: Date? = nil,
    endDate: Date? = nil,
    now: Date = Date()
  ) throws -> DashboardMetricsResponse {
    let interval: DateInterval?
    switch range {
    case "all": interval = nil
    case "today": interval = DateInterval(start: calendar.startOfDay(for: now), end: now)
    case "yesterday":
      let today = calendar.startOfDay(for: now)
      guard let start = calendar.date(byAdding: .day, value: -1, to: today) else { throw DashboardQueryError.invalidRange }
      interval = DateInterval(start: start, end: today)
    case "week": interval = calendar.dateInterval(of: .weekOfYear, for: now)
    case "month": interval = calendar.dateInterval(of: .month, for: now)
    case "custom":
      guard let startDate, let endDate else { throw DashboardQueryError.invalidCustomRange }
      let start = calendar.startOfDay(for: startDate)
      let endDay = calendar.startOfDay(for: endDate)
      guard start <= endDay,
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) else {
        throw DashboardQueryError.invalidCustomRange
      }
      interval = DateInterval(start: start, end: end)
    default: throw DashboardQueryError.invalidRange
    }
    let rows = snapshot.dashboardMetrics.filter { row in
      guard let interval, let date = parseDay(row.date) else { return interval == nil }
      return isWithin(date, interval: interval)
    }
    return DashboardMetricsResponse(range: range, rows: rows, totals: metricTotals(rows))
  }

  public func costSeries(
    snapshot: CostSnapshot,
    granularity: String,
    range: String,
    startDate: Date? = nil,
    endDate: Date? = nil,
    now: Date = Date()
  ) throws -> DashboardCostResponse {
    let interval = try queryInterval(range: range, startDate: startDate, endDate: endDate, now: now)
    let rows: [DashboardCostRow]
    switch granularity {
    case "hourly":
      rows = snapshot.dashboardSessions.compactMap { record in
        guard isWithin(record.timestamp, interval: interval) else { return nil }
        return DashboardCostRow(timestamp: record.timestamp, agent: record.agent, model: record.model, costUSD: record.costUSD)
      }
    case "daily":
      rows = snapshot.dashboardMetrics.compactMap { record in
        guard let timestamp = parseDay(record.date), isWithin(timestamp, interval: interval) else { return nil }
        return DashboardCostRow(timestamp: timestamp, agent: record.agent, model: record.model, costUSD: record.costUSD)
      }
    default: throw DashboardQueryError.invalidGranularity
    }
    return DashboardCostResponse(
      range: range,
      granularity: granularity,
      rows: rows,
      totalUSD: rows.reduce(0) { $0 + $1.costUSD }
    )
  }

  public func parseDay(_ text: String) -> Date? { dayFormatter.date(from: text) }

  private func isWithin(_ date: Date, interval: DateInterval?) -> Bool {
    guard let interval else { return true }
    return date >= interval.start && date < interval.end
  }

  private func formatDay(_ date: Date) -> String { dayFormatter.string(from: date) }

  private func metricTotals(_ rows: [CCUsageMetricRecord]) -> DashboardMetricTotals {
    DashboardMetricTotals(
      costUSD: rows.reduce(0) { $0 + $1.costUSD },
      inputTokens: rows.reduce(0) { $0 + $1.inputTokens },
      outputTokens: rows.reduce(0) { $0 + $1.outputTokens },
      cacheCreationTokens: rows.reduce(0) { $0 + $1.cacheCreationTokens },
      cacheReadTokens: rows.reduce(0) { $0 + $1.cacheReadTokens },
      totalTokens: rows.reduce(0) { $0 + $1.totalTokens }
    )
  }

  private func queryInterval(
    range: String,
    startDate: Date?,
    endDate: Date?,
    now: Date
  ) throws -> DateInterval? {
    switch range {
    case "all": return nil
    case "today": return DateInterval(start: calendar.startOfDay(for: now), end: now)
    case "yesterday":
      let today = calendar.startOfDay(for: now)
      guard let start = calendar.date(byAdding: .day, value: -1, to: today) else { throw DashboardQueryError.invalidRange }
      return DateInterval(start: start, end: today)
    case "week":
      guard let value = calendar.dateInterval(of: .weekOfYear, for: now) else { throw DashboardQueryError.invalidRange }
      return value
    case "month":
      guard let value = calendar.dateInterval(of: .month, for: now) else { throw DashboardQueryError.invalidRange }
      return value
    case "custom":
      guard let startDate, let endDate else { throw DashboardQueryError.invalidCustomRange }
      let start = calendar.startOfDay(for: startDate)
      let endDay = calendar.startOfDay(for: endDate)
      guard start <= endDay,
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) else {
        throw DashboardQueryError.invalidCustomRange
      }
      return DateInterval(start: start, end: end)
    default: throw DashboardQueryError.invalidRange
    }
  }

  private var dayFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }
}

public enum DashboardQueryError: Error, Sendable { case invalidRange, invalidCustomRange, invalidGranularity }
