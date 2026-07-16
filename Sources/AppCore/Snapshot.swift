import Foundation

private func selectedPeriodCost(
  cycle: ResetCycle,
  interval: DateInterval,
  metrics: [CCUsageMetricRecord],
  sessions: [CCUsageSessionMetricRecord],
  calendar: Calendar
) -> Decimal {
  switch cycle {
  case .hourly, .customHours:
    return sessions
      .filter { interval.contains($0.timestamp) }
      .reduce(Decimal.zero) { $0 + $1.costUSD }
  case .daily, .weekly, .monthly:
    return metrics
      .filter { record in
        let components = record.date.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3,
              let date = calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2])) else {
          return false
        }
        return interval.contains(date)
      }
      .reduce(Decimal.zero) { $0 + $1.costUSD }
  }
}

public struct CostSnapshot: Codable, Equatable, Sendable {
  public let generatedAt: Date
  public let activeBoundaryAt: Date
  public let costSinceResetUSD: Decimal
  public let budget: BudgetSummary
  public let resetCycle: ResetCycle
  public let refreshIntervalSeconds: Int
  public let points: [CCUsageCostRecord]
  public let dashboardMetrics: [CCUsageMetricRecord]
  public let dashboardSessions: [CCUsageSessionMetricRecord]

  public init(
    generatedAt: Date,
    activeBoundaryAt: Date,
    costSinceResetUSD: Decimal,
    budget: BudgetSummary,
    resetCycle: ResetCycle,
    refreshIntervalSeconds: Int = AppConfiguration.defaultPollIntervalSeconds,
    points: [CCUsageCostRecord],
    dashboardMetrics: [CCUsageMetricRecord] = [],
    dashboardSessions: [CCUsageSessionMetricRecord] = []
  ) {
    self.generatedAt = generatedAt
    self.activeBoundaryAt = activeBoundaryAt
    self.costSinceResetUSD = costSinceResetUSD
    self.budget = budget
    self.resetCycle = resetCycle
    self.refreshIntervalSeconds = refreshIntervalSeconds
    self.points = points
    self.dashboardMetrics = dashboardMetrics
    self.dashboardSessions = dashboardSessions
  }

  public func applying(state: AppState, now: Date = Date()) -> CostSnapshot? {
    guard let baseline = state.baseline else { return nil }
    let calculator = ResetWindowCalculator()
    guard let interval = try? calculator.aggregationInterval(for: state.resetCycle, now: now) else { return nil }
    let cost = selectedPeriodCost(
      cycle: state.resetCycle,
      interval: interval,
      metrics: dashboardMetrics,
      sessions: dashboardSessions,
      calendar: calculator.calendar
    )
    return CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: baseline.activeBoundaryAt,
      costSinceResetUSD: cost,
      budget: BudgetSummary(spentUSD: cost, budgetUSD: state.budgetUSD),
      resetCycle: state.resetCycle,
      refreshIntervalSeconds: state.refreshIntervalSeconds ?? refreshIntervalSeconds,
      points: points,
      dashboardMetrics: dashboardMetrics,
      dashboardSessions: dashboardSessions
    )
  }
}

public struct SnapshotService: Sendable {
  public let stateStore: StateStore
  public let client: CCUsageClient
  public let calculator: ResetWindowCalculator
  public let defaultRefreshIntervalSeconds: Int
  public let aggregationCache: UsageAggregationCache?

  public init(
    stateStore: StateStore,
    client: CCUsageClient,
    calculator: ResetWindowCalculator = ResetWindowCalculator(),
    defaultRefreshIntervalSeconds: Int = AppConfiguration.defaultPollIntervalSeconds,
    aggregationCache: UsageAggregationCache? = nil
  ) {
    self.stateStore = stateStore
    self.client = client
    self.calculator = calculator
    self.defaultRefreshIntervalSeconds = defaultRefreshIntervalSeconds
    self.aggregationCache = aggregationCache
  }

  public func snapshot(now: Date = Date(), defaultCycle: ResetCycle = .daily) async throws -> CostSnapshot {
    let loaded = try await stateStore.load(defaultCycle: defaultCycle)
    let state = try calculator.validatedState(loaded, now: now)
    if state != loaded { try await stateStore.save(state) }
    guard let baseline = state.baseline else { throw SnapshotError.missingBaseline }
    let todayStart = calculator.calendar.startOfDay(for: now)
    let today = formatDay(todayStart)
    var cached = await aggregationCache?.load(now: now)
    if let cachedThrough = cached?.cachedThrough, parseDay(cachedThrough) == nil {
      await aggregationCache?.purge()
      cached = nil
    }
    let since = cached.flatMap { nextUncachedDay(after: $0.cachedThrough, today: todayStart) }
    async let blockRecords = client.blocks()
    async let metricRecords = client.detailedDaily(since: since, until: since == nil ? nil : today)
    async let sessionRecords = client.detailedSessions(since: since, until: since == nil ? nil : today)
    let points = try await blockRecords
    let freshMetrics = try await metricRecords
    let freshSessions = try await sessionRecords
    let historicalMetrics = (cached?.metrics ?? []) + freshMetrics.filter { $0.date < today }
    let historicalSessions = (cached?.sessions ?? []) + freshSessions.filter { $0.timestamp < todayStart }
    let dashboardMetrics = (cached == nil ? freshMetrics : historicalMetrics + freshMetrics.filter { $0.date >= today })
      .sorted { ($0.date, $0.agent, $0.model) < ($1.date, $1.agent, $1.model) }
    let dashboardSessions = (cached == nil ? freshSessions : historicalSessions + freshSessions.filter { $0.timestamp >= todayStart })
      .sorted { $0.timestamp < $1.timestamp }
    if let aggregationCache,
       let yesterday = calculator.calendar.date(byAdding: .day, value: -1, to: todayStart) {
      let cachedThrough = formatDay(yesterday)
      if cached == nil || cached?.cachedThrough != cachedThrough {
        try? await aggregationCache.save(
          metrics: historicalMetrics,
          sessions: historicalSessions,
          cachedThrough: cachedThrough,
          createdAt: cached?.createdAt,
          now: now
        )
      }
    }
    let interval = try calculator.aggregationInterval(for: state.resetCycle, now: now)
    let cost = selectedPeriodCost(
      cycle: state.resetCycle,
      interval: interval,
      metrics: dashboardMetrics,
      sessions: dashboardSessions,
      calendar: calculator.calendar
    )
    return CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: baseline.activeBoundaryAt,
      costSinceResetUSD: cost,
      budget: BudgetSummary(spentUSD: cost, budgetUSD: state.budgetUSD),
      resetCycle: state.resetCycle,
      refreshIntervalSeconds: state.refreshIntervalSeconds ?? defaultRefreshIntervalSeconds,
      points: points,
      dashboardMetrics: dashboardMetrics,
      dashboardSessions: dashboardSessions
    )
  }

  private func nextUncachedDay(after text: String, today: Date) -> String? {
    guard let cachedThrough = parseDay(text),
          let next = calculator.calendar.date(byAdding: .day, value: 1, to: cachedThrough) else { return nil }
    return formatDay(min(next, today))
  }

  private func parseDay(_ text: String) -> Date? { dayFormatter.date(from: text) }
  private func formatDay(_ date: Date) -> String { dayFormatter.string(from: date) }

  private var dayFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calculator.calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calculator.calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
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
  public let refreshIntervalSeconds: Int
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
  public let inputTokens: Int
  public let outputTokens: Int
  public let cacheCreationTokens: Int
  public let cacheReadTokens: Int
  public let totalTokens: Int
}

public struct DashboardCostResponse: Codable, Equatable, Sendable {
  public let range: String
  public let granularity: String
  public let timelineStart: Date?
  public let timelineEndExclusive: Date?
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
      activeBoundaryAt: snapshot.activeBoundaryAt,
      refreshIntervalSeconds: snapshot.refreshIntervalSeconds
    )
  }

  public func metrics(
    snapshot: CostSnapshot,
    range: String,
    startDate: Date? = nil,
    endDate: Date? = nil,
    now: Date = Date()
  ) throws -> DashboardMetricsResponse {
    let interval = try queryInterval(range: range, startDate: startDate, endDate: endDate, now: now)
    if range == "recent12h" {
      let rows = aggregateSessions(snapshot.dashboardSessions, interval: interval)
      return DashboardMetricsResponse(range: range, rows: rows, totals: metricTotals(rows))
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
    case "15min", "hourly":
      rows = snapshot.dashboardSessions.compactMap { record in
        guard isWithin(record.timestamp, interval: interval) else { return nil }
        return DashboardCostRow(
          timestamp: record.timestamp,
          agent: record.agent,
          model: record.model,
          costUSD: record.costUSD,
          inputTokens: record.inputTokens,
          outputTokens: record.outputTokens,
          cacheCreationTokens: record.cacheCreationTokens,
          cacheReadTokens: record.cacheReadTokens,
          totalTokens: record.totalTokens
        )
      }
    case "daily":
      rows = snapshot.dashboardMetrics.compactMap { record in
        guard let timestamp = parseDay(record.date), isWithin(timestamp, interval: interval) else { return nil }
        return DashboardCostRow(
          timestamp: timestamp,
          agent: record.agent,
          model: record.model,
          costUSD: record.costUSD,
          inputTokens: record.inputTokens,
          outputTokens: record.outputTokens,
          cacheCreationTokens: record.cacheCreationTokens,
          cacheReadTokens: record.cacheReadTokens,
          totalTokens: record.totalTokens
        )
      }
    default: throw DashboardQueryError.invalidGranularity
    }
    return DashboardCostResponse(
      range: range,
      granularity: granularity,
      timelineStart: interval?.start ?? rows.map(\.timestamp).min(),
      timelineEndExclusive: interval.map { max($0.start, min($0.end, now)) } ?? rows.map(\.timestamp).max(),
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

  private func aggregateSessions(
    _ sessions: [CCUsageSessionMetricRecord],
    interval: DateInterval?
  ) -> [CCUsageMetricRecord] {
    struct Key: Hashable { let date: String; let agent: String; let model: String }
    struct Values {
      var costUSD = Decimal.zero
      var inputTokens = 0
      var outputTokens = 0
      var cacheCreationTokens = 0
      var cacheReadTokens = 0
    }
    var groups: [Key: Values] = [:]
    for session in sessions where isWithin(session.timestamp, interval: interval) {
      let key = Key(date: formatDay(session.timestamp), agent: session.agent, model: session.model)
      var values = groups[key, default: Values()]
      values.costUSD += session.costUSD
      values.inputTokens += session.inputTokens
      values.outputTokens += session.outputTokens
      values.cacheCreationTokens += session.cacheCreationTokens
      values.cacheReadTokens += session.cacheReadTokens
      groups[key] = values
    }
    return groups.map { key, values in
      CCUsageMetricRecord(
        date: key.date,
        agent: key.agent,
        model: key.model,
        costUSD: values.costUSD,
        inputTokens: values.inputTokens,
        outputTokens: values.outputTokens,
        cacheCreationTokens: values.cacheCreationTokens,
        cacheReadTokens: values.cacheReadTokens
      )
    }.sorted { ($0.date, $0.agent, $0.model) < ($1.date, $1.agent, $1.model) }
  }

  private func queryInterval(
    range: String,
    startDate: Date?,
    endDate: Date?,
    now: Date
  ) throws -> DateInterval? {
    switch range {
    case "all": return nil
    case "recent12h": return DateInterval(start: now.addingTimeInterval(-12 * 3_600), end: now)
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
