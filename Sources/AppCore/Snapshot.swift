import Foundation

private struct AgentModelDay: Hashable {
  let day: String
  let agent: String
  let model: String
}

private struct AgentModelBucket: Hashable {
  let timestamp: Date
  let agent: String
  let model: String
}

private struct UsageLoadResult: Sendable {
  let metrics: [CCUsageMetricRecord]
  let sessions: [CCUsageSessionMetricRecord]
}

private struct UsagePartition: Sendable {
  var metrics: [CCUsageMetricRecord] = []
  var sessions: [CCUsageSessionMetricRecord] = []
  var events: [TimestampedUsageEvent] = []
}

public struct SnapshotLoadProgress: Equatable, Sendable {
  public let completed: Int
  public let total: Int

  public init(completed: Int, total: Int) {
    self.completed = completed
    self.total = total
  }
}

public typealias SnapshotLoadProgressHandler = @Sendable (SnapshotLoadProgress) async -> Void

let maximumConcurrentRangeLoads = 20

func boundedConcurrentMap<Input: Sendable, Output: Sendable>(
  _ inputs: [Input],
  limit: Int,
  progress: (@Sendable (Int, Int) async -> Void)? = nil,
  operation: @escaping @Sendable (Input) async throws -> Output
) async throws -> [Output] {
  await progress?(0, inputs.count)
  guard !inputs.isEmpty else { return [] }
  return try await withThrowingTaskGroup(of: Output.self) { group in
    var iterator = inputs.makeIterator()
    for _ in 0..<min(max(1, limit), inputs.count) {
      guard let input = iterator.next() else { break }
      group.addTask { try await operation(input) }
    }
    var results: [Output] = []
    for try await result in group {
      results.append(result)
      await progress?(results.count, inputs.count)
      if let input = iterator.next() {
        group.addTask { try await operation(input) }
      }
    }
    return results
  }
}

private struct UsageBucketTotals {
  var costUSD = Decimal.zero
  var inputTokens = 0
  var outputTokens = 0
  var cacheCreationTokens = 0
  var cacheReadTokens = 0
}

private struct AuthoritativeUsageTotals {
  var costUSD = Decimal.zero
  var inputTokens = 0
  var outputTokens = 0
  var cacheCreationTokens = 0
  var cacheReadTokens = 0
}

private func reconciledTimestampedSessions(
  events: [TimestampedUsageEvent],
  metrics: [CCUsageMetricRecord],
  calendar: Calendar
) -> [CCUsageSessionMetricRecord] {
  let formatter = DateFormatter()
  formatter.calendar = calendar
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = calendar.timeZone
  formatter.dateFormat = "yyyy-MM-dd"

  let totalsByModelDay = Dictionary(grouping: metrics) {
    AgentModelDay(day: $0.date, agent: $0.agent.lowercased(), model: $0.model)
  }.mapValues { rows in
    rows.reduce(into: AuthoritativeUsageTotals()) { totals, row in
      totals.costUSD += row.costUSD
      totals.inputTokens += row.inputTokens
      totals.outputTokens += row.outputTokens
      totals.cacheCreationTokens += row.cacheCreationTokens
      totals.cacheReadTokens += row.cacheReadTokens
    }
  }

  let eventsByModelDay = Dictionary(grouping: events) {
    AgentModelDay(day: formatter.string(from: $0.timestamp), agent: $0.agent, model: $0.model)
  }
  let allocatedEvents = eventsByModelDay.flatMap { key, groupedEvents -> [CCUsageSessionMetricRecord] in
    guard let authoritative = totalsByModelDay[key] else { return [] }
    let sortedEvents = groupedEvents.sorted { ($0.timestamp, $0.identity) < ($1.timestamp, $1.identity) }
    let totalWeight = sortedEvents.reduce(Decimal.zero) { $0 + $1.relativeCostWeight }
    let rawInputTokens = sortedEvents.reduce(0) { $0 + $1.inputTokens }
    let rawOutputTokens = sortedEvents.reduce(0) { $0 + $1.outputTokens }
    let rawCacheCreationTokens = sortedEvents.reduce(0) { $0 + $1.cacheCreationTokens }
    let rawCacheReadTokens = sortedEvents.reduce(0) { $0 + $1.cacheReadTokens }
    var allocatedCost = Decimal.zero
    var allocatedInputTokens = 0
    var allocatedOutputTokens = 0
    var allocatedCacheCreationTokens = 0
    var allocatedCacheReadTokens = 0
    return sortedEvents.enumerated().map { index, event in
      let cost: Decimal
      if index == sortedEvents.count - 1 {
        cost = authoritative.costUSD - allocatedCost
      } else if totalWeight > 0 {
        cost = authoritative.costUSD * event.relativeCostWeight / totalWeight
      } else {
        cost = authoritative.costUSD / Decimal(sortedEvents.count)
      }
      let inputTokens = reconciledTokenCount(
        target: authoritative.inputTokens,
        raw: event.inputTokens,
        rawTotal: rawInputTokens,
        allocated: allocatedInputTokens,
        index: index,
        count: sortedEvents.count
      )
      let outputTokens = reconciledTokenCount(
        target: authoritative.outputTokens,
        raw: event.outputTokens,
        rawTotal: rawOutputTokens,
        allocated: allocatedOutputTokens,
        index: index,
        count: sortedEvents.count
      )
      let cacheCreationTokens = reconciledTokenCount(
        target: authoritative.cacheCreationTokens,
        raw: event.cacheCreationTokens,
        rawTotal: rawCacheCreationTokens,
        allocated: allocatedCacheCreationTokens,
        index: index,
        count: sortedEvents.count
      )
      let cacheReadTokens = reconciledTokenCount(
        target: authoritative.cacheReadTokens,
        raw: event.cacheReadTokens,
        rawTotal: rawCacheReadTokens,
        allocated: allocatedCacheReadTokens,
        index: index,
        count: sortedEvents.count
      )
      allocatedCost += cost
      allocatedInputTokens += inputTokens
      allocatedOutputTokens += outputTokens
      allocatedCacheCreationTokens += cacheCreationTokens
      allocatedCacheReadTokens += cacheReadTokens
      return CCUsageSessionMetricRecord(
        timestamp: event.timestamp,
        agent: event.agent,
        model: event.model,
        costUSD: cost,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheCreationTokens: cacheCreationTokens,
        cacheReadTokens: cacheReadTokens,
        dataQuality: .timestamped
      )
    }
  }
  var buckets: [AgentModelBucket: UsageBucketTotals] = [:]
  for event in allocatedEvents {
    let bucketTimestamp = Date(
      timeIntervalSince1970: floor(event.timestamp.timeIntervalSince1970 / 900) * 900
    )
    let key = AgentModelBucket(timestamp: bucketTimestamp, agent: event.agent, model: event.model)
    var totals = buckets[key] ?? UsageBucketTotals()
    totals.costUSD += event.costUSD
    totals.inputTokens += event.inputTokens
    totals.outputTokens += event.outputTokens
    totals.cacheCreationTokens += event.cacheCreationTokens
    totals.cacheReadTokens += event.cacheReadTokens
    buckets[key] = totals
  }
  return buckets.map { key, totals in
    CCUsageSessionMetricRecord(
      timestamp: key.timestamp,
      agent: key.agent,
      model: key.model,
      costUSD: totals.costUSD,
      inputTokens: totals.inputTokens,
      outputTokens: totals.outputTokens,
      cacheCreationTokens: totals.cacheCreationTokens,
      cacheReadTokens: totals.cacheReadTokens,
      dataQuality: .timestamped
    )
  }.sorted { ($0.timestamp, $0.model) < ($1.timestamp, $1.model) }
}

private func reconciledTokenCount(
  target: Int,
  raw: Int,
  rawTotal: Int,
  allocated: Int,
  index: Int,
  count: Int
) -> Int {
  if index == count - 1 { return target - allocated }
  if rawTotal > 0 {
    return NSDecimalNumber(decimal: Decimal(target) * Decimal(raw) / Decimal(rawTotal)).intValue
  }
  return target / count
}

func selectedPeriodCost(
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
  public let claudeUsageEventLoader: ClaudeUsageEventLoader?
  public let codexUsageEventLoader: CodexUsageEventLoader?
  private let usageEventCoordinator: TimestampedUsageEventLoadCoordinator

  public init(
    stateStore: StateStore,
    client: CCUsageClient,
    calculator: ResetWindowCalculator = ResetWindowCalculator(),
    defaultRefreshIntervalSeconds: Int = AppConfiguration.defaultPollIntervalSeconds,
    aggregationCache: UsageAggregationCache? = nil,
    claudeUsageEventLoader: ClaudeUsageEventLoader? = nil,
    codexUsageEventLoader: CodexUsageEventLoader? = nil
  ) {
    self.stateStore = stateStore
    self.client = client
    self.calculator = calculator
    self.defaultRefreshIntervalSeconds = defaultRefreshIntervalSeconds
    self.aggregationCache = aggregationCache
    self.claudeUsageEventLoader = claudeUsageEventLoader
    self.codexUsageEventLoader = codexUsageEventLoader
    usageEventCoordinator = TimestampedUsageEventLoadCoordinator()
  }

  public func snapshot(
    now: Date = Date(),
    defaultCycle: ResetCycle = .daily,
    earliestDate: Date? = nil,
    progress: SnapshotLoadProgressHandler? = nil
  ) async throws -> CostSnapshot {
    let loaded = try await stateStore.load(defaultCycle: defaultCycle)
    let state = try calculator.validatedState(loaded, now: now)
    if state != loaded { try await stateStore.save(state) }
    guard let baseline = state.baseline else { throw SnapshotError.missingBaseline }
    let todayStart = calculator.calendar.startOfDay(for: now)
    let today = formatDay(todayStart)
    let cached = await validAggregationCache(now: now)
    let initialFrom = initialCoverageStart(for: todayStart)
    let requestedFrom = earliestDate.map { calculator.calendar.startOfDay(for: $0) }
    let desiredFrom = min(requestedFrom ?? initialFrom, initialFrom)
    let ranges = missingUsageRanges(desiredFrom: desiredFrom, todayStart: todayStart, cached: cached)
    async let blockRecords = client.blocks(since: formatDay(initialFrom), until: today)
    async let usageRecords = loadUsage(ranges: ranges, progress: progress)
    let (points, loadedRanges) = try await (blockRecords, usageRecords)
    let freshMetrics = loadedRanges.flatMap(\.metrics)
    let freshSessions = loadedRanges.flatMap(\.sessions)
    let historicalMetrics = (cached?.metrics ?? []) + freshMetrics.filter { $0.date < today }
    let historicalSessions = (cached?.sessions ?? []) + freshSessions.filter { $0.timestamp < todayStart }
    let dashboardMetrics = (cached == nil ? freshMetrics : historicalMetrics + freshMetrics.filter { $0.date >= today })
      .sorted { ($0.date, $0.agent, $0.model) < ($1.date, $1.agent, $1.model) }
    let dashboardSessions = (cached == nil ? freshSessions : historicalSessions + freshSessions.filter { $0.timestamp >= todayStart })
      .sorted { $0.timestamp < $1.timestamp }
    try Task.checkCancellation()
    if let aggregationCache,
       let yesterday = calculator.calendar.date(byAdding: .day, value: -1, to: todayStart) {
      let cachedThrough = formatDay(yesterday)
      let existingFrom = cached.flatMap { parseDay($0.cachedFrom) } ?? desiredFrom
      let cachedFrom = formatDay(min(existingFrom, desiredFrom))
      if cached == nil || cached?.cachedFrom != cachedFrom || cached?.cachedThrough != cachedThrough {
        try? await aggregationCache.save(
          metrics: historicalMetrics,
          sessions: historicalSessions,
          cachedFrom: cachedFrom,
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

  public func menuBarSnapshot(now: Date = Date(), defaultCycle: ResetCycle = .daily) async throws -> CostSnapshot {
    let loaded = try await stateStore.load(defaultCycle: defaultCycle)
    let state = try calculator.validatedState(loaded, now: now)
    if state != loaded { try await stateStore.save(state) }
    guard let baseline = state.baseline else { throw SnapshotError.missingBaseline }
    let interval = try calculator.aggregationInterval(for: state.resetCycle, now: now)
    let todayStart = calculator.calendar.startOfDay(for: now)
    let desiredFrom = calculator.calendar.startOfDay(for: interval.start)
    let cached = await validAggregationCache(now: now)
    let ranges = missingUsageRanges(desiredFrom: desiredFrom, todayStart: todayStart, cached: cached)
    let metrics: [CCUsageMetricRecord]
    let sessions: [CCUsageSessionMetricRecord]
    switch state.resetCycle {
    case .daily, .weekly, .monthly:
      metrics = (cached?.metrics ?? []) + (try await loadMetrics(ranges: ranges))
      sessions = []
    case .hourly, .customHours:
      let loadedRanges = try await loadUsage(ranges: ranges)
      metrics = (cached?.metrics ?? []) + loadedRanges.flatMap(\.metrics)
      sessions = (cached?.sessions ?? []) + loadedRanges.flatMap(\.sessions)
    }
    let cost = selectedPeriodCost(
      cycle: state.resetCycle,
      interval: interval,
      metrics: metrics,
      sessions: sessions,
      calendar: calculator.calendar
    )
    return CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: baseline.activeBoundaryAt,
      costSinceResetUSD: cost,
      budget: BudgetSummary(spentUSD: cost, budgetUSD: state.budgetUSD),
      resetCycle: state.resetCycle,
      refreshIntervalSeconds: state.refreshIntervalSeconds ?? defaultRefreshIntervalSeconds,
      points: [],
      dashboardMetrics: metrics,
      dashboardSessions: sessions
    )
  }

  public func clearAggregationCache() async {
    await aggregationCache?.purge()
  }

  private func nextUncachedDay(after text: String, today: Date) -> String? {
    guard let cachedThrough = parseDay(text),
          let next = calculator.calendar.date(byAdding: .day, value: 1, to: cachedThrough) else { return nil }
    return formatDay(min(next, today))
  }

  private func initialCoverageStart(for today: Date) -> Date {
    calculator.calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
  }

  private func validAggregationCache(now: Date) async -> AggregationCachePayload? {
    guard let cached = await aggregationCache?.load(now: now) else { return nil }
    guard parseDay(cached.cachedFrom) != nil,
          parseDay(cached.cachedThrough) != nil,
          cached.cachedFrom <= cached.cachedThrough else {
      await aggregationCache?.purge()
      return nil
    }
    return cached
  }

  private func missingUsageRanges(
    desiredFrom: Date,
    todayStart: Date,
    cached: AggregationCachePayload?
  ) -> [(since: String, until: String)] {
    let today = formatDay(todayStart)
    guard let cached, let cachedFrom = parseDay(cached.cachedFrom) else {
      return weekPartitionedRanges(from: desiredFrom, through: todayStart)
    }
    var ranges: [(since: String, until: String)] = []
    if desiredFrom < cachedFrom,
       let olderUntil = calculator.calendar.date(byAdding: .day, value: -1, to: cachedFrom) {
      ranges.append(contentsOf: weekPartitionedRanges(from: desiredFrom, through: olderUntil))
    }
    if let since = nextUncachedDay(after: cached.cachedThrough, today: todayStart) {
      ranges.append((since, today))
    }
    return ranges
  }

  private func weekPartitionedRanges(from start: Date, through end: Date) -> [(since: String, until: String)] {
    guard start <= end else { return [] }
    var ranges: [(since: String, until: String)] = []
    var cursor = start
    while cursor <= end {
      guard let week = calculator.calendar.dateInterval(of: .weekOfYear, for: cursor),
            let weekEnd = calculator.calendar.date(byAdding: .day, value: -1, to: week.end) else {
        return [(formatDay(start), formatDay(end))]
      }
      let rangeEnd = min(weekEnd, end)
      ranges.append((formatDay(cursor), formatDay(rangeEnd)))
      guard let next = calculator.calendar.date(byAdding: .day, value: 1, to: rangeEnd) else { break }
      cursor = next
    }
    return ranges
  }

  private func loadMetrics(ranges: [(since: String, until: String)]) async throws -> [CCUsageMetricRecord] {
    guard !ranges.isEmpty else { return [] }
    let usage = try await client.detailedUsage()
    return usage.metrics.filter { record in
      ranges.contains { $0.since <= record.date && record.date <= $0.until }
    }
  }

  private func loadUsage(
    ranges: [(since: String, until: String)],
    progress: SnapshotLoadProgressHandler? = nil
  ) async throws -> [UsageLoadResult] {
    await progress?(SnapshotLoadProgress(completed: 0, total: ranges.count))
    async let detailedUsage = client.detailedUsage()
    async let timestampedUsageEvents = loadRecentTimestampedEvents(ranges: ranges)
    let (usage, timestampedEvents) = try await (detailedUsage, timestampedUsageEvents)
    let partitions = partitionUsage(usage, timestampedEvents: timestampedEvents, ranges: ranges)
    return try await boundedConcurrentMap(
      Array(partitions.indices),
      limit: maximumConcurrentRangeLoads,
      progress: { completed, total in
        await progress?(SnapshotLoadProgress(completed: completed, total: total))
      },
      operation: { index in
        let partition = partitions[index]
        return usageResult(
          metrics: partition.metrics,
          sessions: partition.sessions,
          timestampedEvents: partition.events
        )
      }
    )
  }

  private func partitionUsage(
    _ usage: CCUsageDetailedUsage,
    timestampedEvents: [TimestampedUsageEvent],
    ranges: [(since: String, until: String)]
  ) -> [UsagePartition] {
    var rangeIndexByDay: [String: Int] = [:]
    for (index, range) in ranges.enumerated() {
      guard var day = parseDay(range.since), let end = parseDay(range.until) else { continue }
      while day <= end {
        rangeIndexByDay[formatDay(day)] = index
        guard let next = calculator.calendar.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
      }
    }
    var partitions = Array(repeating: UsagePartition(), count: ranges.count)
    for record in usage.metrics {
      guard let index = rangeIndexByDay[record.date] else { continue }
      partitions[index].metrics.append(record)
    }
    for record in usage.sessions {
      guard let index = rangeIndexByDay[formatDay(record.timestamp)] else { continue }
      partitions[index].sessions.append(record)
    }
    for event in timestampedEvents {
      guard let index = rangeIndexByDay[formatDay(event.timestamp)] else { continue }
      partitions[index].events.append(event)
    }
    return partitions
  }

  private func loadRecentTimestampedEvents(
    ranges: [(since: String, until: String)]
  ) async throws -> [TimestampedUsageEvent] {
    guard let latestDayText = ranges.map(\.until).max(),
          let latestDay = parseDay(latestDayText),
          let currentMonth = calculator.calendar.dateInterval(of: .month, for: latestDay),
          let recentStartDate = calculator.calendar.date(byAdding: .month, value: -1, to: currentMonth.start) else {
      return []
    }
    let recentStart = formatDay(recentStartDate)
    let recentRanges = ranges.filter { $0.until >= recentStart }
    guard let since = recentRanges.map({ max($0.since, recentStart) }).min(),
          let until = recentRanges.map(\.until).max() else { return [] }
    return try await usageEventCoordinator.events(
      claudeLoader: claudeUsageEventLoader,
      codexLoader: codexUsageEventLoader,
      since: since,
      until: until,
      calendar: calculator.calendar
    )
  }

  private func usageResult(
    metrics: [CCUsageMetricRecord],
    sessions: [CCUsageSessionMetricRecord],
    timestampedEvents: [TimestampedUsageEvent]
  ) -> UsageLoadResult {
    let timestampedKeys = Set(timestampedEvents.map {
      AgentModelDay(day: formatDay($0.timestamp), agent: $0.agent, model: $0.model)
    })
    let fallbackSessions = sessions.filter { row in
      !timestampedKeys.contains(AgentModelDay(
        day: formatDay(row.timestamp),
        agent: row.agent.lowercased(),
        model: row.model
      ))
    }
    return UsageLoadResult(
      metrics: metrics,
      sessions: fallbackSessions + reconciledTimestampedSessions(
        events: timestampedEvents,
        metrics: metrics,
        calendar: calculator.calendar
      )
    )
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
  public let machine: String
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
  public let dataQuality: String
  public let machine: String
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
      RecentPoint(timestamp: $0.timestamp, costUSD: $0.costUSD, models: $0.models, machine: $0.machine)
    }
    return RecentResponse(series: points, totalUSD: points.reduce(0) { $0 + $1.costUSD })
  }

  public func day(snapshot: CostSnapshot, date: Date) -> DayResponse {
    let points = snapshot.points.filter { calendar.isDate($0.timestamp, inSameDayAs: date) }.map {
      RecentPoint(timestamp: $0.timestamp, costUSD: $0.costUSD, models: $0.models, machine: $0.machine)
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
      RecentPoint(timestamp: $0.timestamp, costUSD: $0.costUSD, models: $0.models, machine: $0.machine)
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
      .map { RecentPoint(timestamp: $0.timestamp, costUSD: $0.costUSD, models: $0.models, machine: $0.machine) }
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
    case "15min", "hourly", "6hour":
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
          totalTokens: record.totalTokens,
          dataQuality: record.dataQuality.rawValue,
          machine: record.machine
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
          totalTokens: record.totalTokens,
          dataQuality: "daily",
          machine: record.machine
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
    struct Key: Hashable { let date: String; let agent: String; let model: String; let machine: String }
    struct Values {
      var costUSD = Decimal.zero
      var inputTokens = 0
      var outputTokens = 0
      var cacheCreationTokens = 0
      var cacheReadTokens = 0
    }
    var groups: [Key: Values] = [:]
    for session in sessions where isWithin(session.timestamp, interval: interval) {
      let key = Key(date: formatDay(session.timestamp), agent: session.agent, model: session.model, machine: session.machine)
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
        cacheReadTokens: values.cacheReadTokens,
        machine: key.machine
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
