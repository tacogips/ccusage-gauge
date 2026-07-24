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

/// Merges two already-sorted arrays into one sorted array in O(n). The merge is stable and
/// left-biased on ties: when neither element is strictly smaller, the `left` element is emitted
/// first, so a sorted cache prefix keeps precedence over freshly loaded rows sharing a key.
func mergeSorted<Element>(
  _ left: [Element],
  _ right: [Element],
  by areInIncreasingOrder: (Element, Element) -> Bool
) -> [Element] {
  guard !left.isEmpty else { return right }
  guard !right.isEmpty else { return left }
  var merged: [Element] = []
  merged.reserveCapacity(left.count + right.count)
  var i = left.startIndex
  var j = right.startIndex
  while i < left.endIndex, j < right.endIndex {
    if areInIncreasingOrder(right[j], left[i]) {
      merged.append(right[j]); j = right.index(after: j)
    } else {
      merged.append(left[i]); i = left.index(after: i)
    }
  }
  if i < left.endIndex { merged.append(contentsOf: left[i...]) }
  if j < right.endIndex { merged.append(contentsOf: right[j...]) }
  return merged
}

/// Total order used for `dashboardMetrics`, matching the cache's `ORDER BY date, agent, model`.
func metricsInIncreasingOrder(_ lhs: CCUsageMetricRecord, _ rhs: CCUsageMetricRecord) -> Bool {
  (lhs.date, lhs.agent, lhs.model) < (rhs.date, rhs.agent, rhs.model)
}

/// Ordering for `dashboardSessions`. Only the timestamp is significant (matching the historical
/// output), while the cache's stored `timestamp, agent, model` order is a compatible refinement.
func sessionsInIncreasingOrder(_ lhs: CCUsageSessionMetricRecord, _ rhs: CCUsageSessionMetricRecord) -> Bool {
  lhs.timestamp < rhs.timestamp
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

private func calendarDayString(_ date: Date, calendar: Calendar) -> String {
  let components = calendar.dateComponents([.year, .month, .day], from: date)
  guard let year = components.year, let month = components.month, let day = components.day else {
    return ""
  }
  return String(format: "%04d-%02d-%02d", year, month, day)
}

private func parseCalendarDay(_ text: String, calendar: Calendar) -> Date? {
  let fields = text.split(separator: "-", omittingEmptySubsequences: false)
  guard fields.count == 3,
        fields[0].count == 4,
        fields[1].count == 2,
        fields[2].count == 2,
        let year = Int(fields[0]),
        let month = Int(fields[1]),
        let day = Int(fields[2]) else {
    return nil
  }

  var components = DateComponents()
  components.calendar = calendar
  components.timeZone = calendar.timeZone
  components.year = year
  components.month = month
  components.day = day
  guard let date = calendar.date(from: components),
        calendarDayString(date, calendar: calendar) == text else {
    return nil
  }
  return date
}

private func reconciledTimestampedSessions(
  events: [TimestampedUsageEvent],
  metrics: [CCUsageMetricRecord],
  calendar: Calendar
) -> [CCUsageSessionMetricRecord] {
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
    AgentModelDay(day: calendarDayString($0.timestamp, calendar: calendar), agent: $0.agent, model: $0.model)
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
    let timezone = snapshotTimezoneIdentifier
    async let blockRecords = client.blocks(since: formatDay(initialFrom), until: today, timezone: timezone)
    async let usageRecords = loadUsage(ranges: ranges, progress: progress)
    let (points, loadedRanges) = try await (blockRecords, usageRecords)
    let freshMetrics = loadedRanges.flatMap(\.metrics)
    let freshSessions = loadedRanges.flatMap(\.sessions)
    // The cached prefix is always sorted (SQLite `ORDER BY` on read, and the in-memory payload is
    // re-saved sorted below), so only the fresh partition is sorted and merged instead of re-sorting
    // the whole history each cycle. Output is identical to `(cached + fresh).sorted(by:)`.
    let sortedFreshMetrics = freshMetrics.sorted(by: metricsInIncreasingOrder)
    let sortedFreshSessions = freshSessions.sorted(by: sessionsInIncreasingOrder)
    let historicalMetrics = mergeSorted(
      cached?.metrics ?? [],
      freshMetrics.filter { $0.date < today }.sorted(by: metricsInIncreasingOrder),
      by: metricsInIncreasingOrder
    )
    let historicalSessions = mergeSorted(
      cached?.sessions ?? [],
      freshSessions.filter { $0.timestamp < todayStart }.sorted(by: sessionsInIncreasingOrder),
      by: sessionsInIncreasingOrder
    )
    let dashboardMetrics: [CCUsageMetricRecord]
    let dashboardSessions: [CCUsageSessionMetricRecord]
    if let cached {
      dashboardMetrics = mergeSorted(cached.metrics, sortedFreshMetrics, by: metricsInIncreasingOrder)
      dashboardSessions = mergeSorted(cached.sessions, sortedFreshSessions, by: sessionsInIncreasingOrder)
    } else {
      dashboardMetrics = sortedFreshMetrics
      dashboardSessions = sortedFreshSessions
    }
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

  public func persistedCoverageStart(now: Date = Date()) async -> Date? {
    guard let cached = await validAggregationCache(now: now) else { return nil }
    return parseDay(cached.cachedFrom)
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
    let usagePerRange = try await usageForRanges(ranges)
    return partitionUsage(usagePerRange, timestampedEvents: [], ranges: ranges, formatDay: memoizedDayFormatter()).flatMap(\.metrics)
  }

  private func loadUsage(
    ranges: [(since: String, until: String)],
    progress: SnapshotLoadProgressHandler? = nil
  ) async throws -> [UsageLoadResult] {
    guard !ranges.isEmpty else {
      await progress?(SnapshotLoadProgress(completed: 0, total: 0))
      return []
    }
    async let timestampedUsageEventsTask = loadRecentTimestampedEvents(ranges: ranges)
    let usagePerRange = try await usageForRanges(ranges, progress: progress)
    let timestampedEvents = try await timestampedUsageEventsTask
    // One formatter and memo shared across the partition and result loops: session/event
    // rows repeat days heavily, so day-string formatting collapses to O(unique days).
    let formatDay = memoizedDayFormatter()
    let partitions = partitionUsage(usagePerRange, timestampedEvents: timestampedEvents, ranges: ranges, formatDay: formatDay)
    return partitions.map { partition in
      usageResult(
        metrics: partition.metrics,
        sessions: partition.sessions,
        timestampedEvents: partition.events,
        formatDay: formatDay
      )
    }
  }

  /// Fetches `detailedUsage` for each range concurrently and returns the responses
  /// re-ordered to match `ranges` positionally. `boundedConcurrentMap` yields results
  /// in completion order, so each result is index-tagged and reassembled here; downstream
  /// code can then safely pair `usagePerRange[i]` with `ranges[i]`.
  private func usageForRanges(
    _ ranges: [(since: String, until: String)],
    progress: SnapshotLoadProgressHandler? = nil
  ) async throws -> [CCUsageDetailedUsage] {
    let client = self.client
    let timezone = snapshotTimezoneIdentifier
    let progressBridge: (@Sendable (Int, Int) async -> Void)?
    if let progress {
      progressBridge = { completed, total in
        await progress(SnapshotLoadProgress(completed: completed, total: total))
      }
    } else {
      progressBridge = nil
    }
    let tagged = try await boundedConcurrentMap(
      Array(ranges.indices),
      limit: maximumConcurrentRangeLoads,
      progress: progressBridge,
      operation: { index -> (Int, CCUsageDetailedUsage) in
        let range = ranges[index]
        return (index, try await client.detailedUsage(since: range.since, until: range.until, timezone: timezone))
      }
    )
    var ordered = [CCUsageDetailedUsage?](repeating: nil, count: ranges.count)
    for (index, usage) in tagged { ordered[index] = usage }
    // Fail loudly if reassembly is incomplete: silently dropping a slot would shift the
    // positional pairing downstream and misattribute usage to the wrong range — the exact
    // bug class this index-tagging exists to prevent.
    return try ordered.map { usage in
      guard let usage else { throw SnapshotError.rangeReassemblyFailed }
      return usage
    }
  }

  private func partitionUsage(
    _ usagePerRange: [CCUsageDetailedUsage],
    timestampedEvents: [TimestampedUsageEvent],
    ranges: [(since: String, until: String)],
    formatDay: (Date) -> String
  ) -> [UsagePartition] {
    zip(usagePerRange, ranges).map { usage, range in
      var partition = UsagePartition()
      partition.metrics = usage.metrics.filter { range.since <= $0.date && $0.date <= range.until }
      partition.sessions = usage.sessions.filter { record in
        let day = formatDay(record.timestamp)
        return range.since <= day && day <= range.until
      }
      partition.events = timestampedEvents.filter { event in
        let day = formatDay(event.timestamp)
        return range.since <= day && day <= range.until
      }
      return partition
    }
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
    timestampedEvents: [TimestampedUsageEvent],
    formatDay: (Date) -> String
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

  private func parseDay(_ text: String) -> Date? { parseCalendarDay(text, calendar: calculator.calendar) }
  private func formatDay(_ date: Date) -> String { calendarDayString(date, calendar: calculator.calendar) }

  /// Returns a memoized `Date -> day-string` formatter. Session/event rows within the same
  /// calendar day format identically, so the memo avoids repeating calendar component work.
  /// Calendar components also avoid a swift-corelibs-foundation `DateFormatter` trap for
  /// resolvable IANA aliases such as `US/Eastern`.
  private func memoizedDayFormatter() -> (Date) -> String {
    let calendar = calculator.calendar
    var memo: [Date: String] = [:]
    return { date in
      let key = calendar.startOfDay(for: date)
      if let cached = memo[key] { return cached }
      let value = calendarDayString(date, calendar: calendar)
      memo[key] = value
      return value
    }
  }

  /// IANA timezone identifier that scoped ccusage calls must group/filter in, so the remote
  /// CLI's `--since/--until`, daily `period` strings, and session date bucketing all align with
  /// `calculator.calendar` (the timezone the host uses to compute ranges and partition results).
  /// Fixed-offset zones (e.g. "GMT+0900") are not IANA identifiers, so whole-hour offsets are
  /// normalized to the equivalent "Etc/GMT<-|+>N" zone (IANA inverts the sign: Etc/GMT-9 is
  /// UTC+9). Returns nil only for offsets with no IANA equivalent (e.g. half-hour offsets),
  /// in which case the flag is omitted and behavior falls back to the CLI's local timezone.
  private var snapshotTimezoneIdentifier: String? {
    let timeZone = calculator.calendar.timeZone
    let identifier = timeZone.identifier
    if TimeZone.knownTimeZoneIdentifiers.contains(identifier) { return identifier }
    // Resolvable IANA aliases (e.g. "US/Eastern") are absent from knownTimeZoneIdentifiers
    // but keep their full DST rules, so pass them through unchanged. Fixed-offset
    // identifiers like "GMT+0900" never contain a slash and fall through to Etc/GMT
    // normalization below.
    if identifier == "UTC" || (identifier.contains("/") && TimeZone(identifier: identifier) != nil) {
      return identifier
    }
    let seconds = timeZone.secondsFromGMT()
    guard seconds % 3_600 == 0 else { return nil }
    let hours = seconds / 3_600
    let candidate = hours == 0 ? "Etc/GMT" : "Etc/GMT\(hours > 0 ? "-" : "+")\(abs(hours))"
    // Etc/* zones resolve via TimeZone(identifier:) but are absent from
    // knownTimeZoneIdentifiers, so validate by construction and exact offset instead.
    guard let resolved = TimeZone(identifier: candidate), resolved.secondsFromGMT() == seconds else { return nil }
    return candidate
  }

}

public enum SnapshotError: Error, Sendable { case missingBaseline, rangeReassemblyFailed }

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
