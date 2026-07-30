import Foundation

public struct RecentPoint: Codable, Equatable, Sendable {
  public let timestamp: Date
  public let costUSD: Decimal
  public let models: [String]
  public let machine: String
}

/// Dashboard read responses that can carry a router-injected machine `scope` sibling. The field is
/// encoded only when set (synthesized `encodeIfPresent`), so the non-scoped `DashboardRouter` path
/// stays byte-identical while `MachineDashboardRouter` attaches `scope` in a single encoding pass.
public protocol ScopedDashboardResponse {
  var scope: DashboardScope? { get set }
}

public struct RecentResponse: Codable, Equatable, Sendable, ScopedDashboardResponse {
  public let series: [RecentPoint]
  public let totalUSD: Decimal
  public var scope: DashboardScope?
  public init(series: [RecentPoint], totalUSD: Decimal, scope: DashboardScope? = nil) {
    self.series = series
    self.totalUSD = totalUSD
    self.scope = scope
  }
}
public struct DayResponse: Codable, Equatable, Sendable, ScopedDashboardResponse {
  public let date: String
  public let series: [RecentPoint]
  public let totalUSD: Decimal
  public var scope: DashboardScope?
  public init(date: String, series: [RecentPoint], totalUSD: Decimal, scope: DashboardScope? = nil) {
    self.date = date
    self.series = series
    self.totalUSD = totalUSD
    self.scope = scope
  }
}
public struct PeriodResponse: Codable, Equatable, Sendable, ScopedDashboardResponse {
  public let range: String
  public let series: [RecentPoint]
  public let totalUSD: Decimal
  public var scope: DashboardScope?
  public init(range: String, series: [RecentPoint], totalUSD: Decimal, scope: DashboardScope? = nil) {
    self.range = range
    self.series = series
    self.totalUSD = totalUSD
    self.scope = scope
  }
}
public struct BudgetResponse: Codable, Equatable, Sendable, ScopedDashboardResponse {
  public let budgetUSD: Decimal?
  public let spentUSD: Decimal
  public let remainingUSD: Decimal?
  public let overageUSD: Decimal
  public let usagePercentage: Decimal?
  public let visualFraction: Decimal?
  public let resetCycle: String
  public let activeBoundaryAt: Date
  public let refreshIntervalSeconds: Int
  public var scope: DashboardScope?
  public init(
    budgetUSD: Decimal?,
    spentUSD: Decimal,
    remainingUSD: Decimal?,
    overageUSD: Decimal,
    usagePercentage: Decimal?,
    visualFraction: Decimal?,
    resetCycle: String,
    activeBoundaryAt: Date,
    refreshIntervalSeconds: Int,
    scope: DashboardScope? = nil
  ) {
    self.budgetUSD = budgetUSD
    self.spentUSD = spentUSD
    self.remainingUSD = remainingUSD
    self.overageUSD = overageUSD
    self.usagePercentage = usagePercentage
    self.visualFraction = visualFraction
    self.resetCycle = resetCycle
    self.activeBoundaryAt = activeBoundaryAt
    self.refreshIntervalSeconds = refreshIntervalSeconds
    self.scope = scope
  }
}

public struct DashboardMetricTotals: Codable, Equatable, Sendable {
  public let costUSD: Decimal
  public let inputTokens: Int
  public let outputTokens: Int
  public let cacheCreationTokens: Int
  public let cacheReadTokens: Int
  public let totalTokens: Int
}

public struct DashboardMetricsResponse: Codable, Equatable, Sendable, ScopedDashboardResponse {
  public let range: String
  public let rows: [CCUsageMetricRecord]
  public let totals: DashboardMetricTotals
  public var scope: DashboardScope?
  public var rangeLoad: DashboardRangeLoadProgress?
  public init(range: String, rows: [CCUsageMetricRecord], totals: DashboardMetricTotals, scope: DashboardScope? = nil) {
    self.range = range
    self.rows = rows
    self.totals = totals
    self.scope = scope
    rangeLoad = nil
  }
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
  public let directory: String?
}

public typealias DashboardDirectorySelections = [String: Set<String>]

public struct DashboardCostResponse: Codable, Equatable, Sendable, ScopedDashboardResponse {
  public let range: String
  public let granularity: String
  public let timelineStart: Date?
  public let timelineEndExclusive: Date?
  public let rows: [DashboardCostRow]
  public let totalUSD: Decimal
  public var machineLatestEvents: [MachineLatestEvent]?
  public var scope: DashboardScope?
  public var rangeLoad: DashboardRangeLoadProgress?
  public init(
    range: String,
    granularity: String,
    timelineStart: Date?,
    timelineEndExclusive: Date?,
    rows: [DashboardCostRow],
    totalUSD: Decimal,
    machineLatestEvents: [MachineLatestEvent]? = nil,
    scope: DashboardScope? = nil
  ) {
    self.range = range
    self.granularity = granularity
    self.timelineStart = timelineStart
    self.timelineEndExclusive = timelineEndExclusive
    self.rows = rows
    self.totalUSD = totalUSD
    self.machineLatestEvents = machineLatestEvents
    self.scope = scope
    rangeLoad = nil
  }
}

public struct DashboardRangeLoadProgress: Codable, Equatable, Sendable {
  public let requestedStart: Date?
  public let requestedEnd: Date?
  public let completed: Int
  public let total: Int
  public let isLoading: Bool
  public let isPartial: Bool
  public let failedMachineIds: [String]

  public init(
    requestedStart: Date?,
    requestedEnd: Date?,
    completed: Int,
    total: Int,
    isLoading: Bool,
    isPartial: Bool,
    failedMachineIds: [String]
  ) {
    self.requestedStart = requestedStart
    self.requestedEnd = requestedEnd
    self.completed = completed
    self.total = total
    self.isLoading = isLoading
    self.isPartial = isPartial
    self.failedMachineIds = failedMachineIds
  }
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

  public func budget(
    snapshot: CostSnapshot,
    directorySelections: DashboardDirectorySelections = [:]
  ) -> BudgetResponse {
    let summary: BudgetSummary
    if directorySelections.isEmpty {
      summary = snapshot.budget
    } else {
      let interval = DateInterval(
        start: snapshot.activeBoundaryAt,
        end: max(snapshot.activeBoundaryAt, snapshot.generatedAt)
      )
      let spent = snapshot.dashboardSessions
        .filter {
          isWithin($0.timestamp, interval: interval)
            && matchesDirectory(machine: $0.machine, directory: $0.directory, selections: directorySelections)
        }
        .reduce(Decimal.zero) { $0 + $1.costUSD }
      summary = BudgetSummary(spentUSD: spent, budgetUSD: snapshot.budget.budgetUSD)
    }
    return BudgetResponse(
      budgetUSD: summary.budgetUSD,
      spentUSD: summary.spentUSD,
      remainingUSD: summary.remainingUSD,
      overageUSD: summary.overageUSD,
      usagePercentage: summary.usagePercentage,
      visualFraction: summary.visualFraction,
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
    now: Date = Date(),
    directorySelections: DashboardDirectorySelections = [:]
  ) throws -> DashboardMetricsResponse {
    let interval = try queryInterval(range: range, startDate: startDate, endDate: endDate, now: now)
    if range == "recent12h" || !directorySelections.isEmpty {
      let rows = aggregateSessions(
        snapshot.dashboardSessions,
        interval: interval,
        includeDirectory: !directorySelections.isEmpty,
        directorySelections: directorySelections
      )
      return DashboardMetricsResponse(range: range, rows: rows, totals: metricTotals(rows))
    }
    // One formatter and one memo per call: row dates repeat heavily (~30-90 unique days),
    // so parsing collapses to O(unique days) instead of O(rows) DateFormatter builds.
    let parse = memoizedDayParser()
    let rows = snapshot.dashboardMetrics.filter { row in
      guard let interval, let date = parse(row.date) else { return interval == nil }
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
    now: Date = Date(),
    directorySelections: DashboardDirectorySelections = [:],
    directoryBreakdown: Bool = false
  ) throws -> DashboardCostResponse {
    let interval = try queryInterval(range: range, startDate: startDate, endDate: endDate, now: now)
    let rows: [DashboardCostRow]
    let directoryResolved = directoryBreakdown || !directorySelections.isEmpty
    switch granularity {
    case "15min", "hourly", "6hour":
      let sessions = directoryResolved
        ? snapshot.dashboardSessions
        : collapsedSessions(snapshot.dashboardSessions)
      rows = sessions.compactMap { record in
        guard isWithin(record.timestamp, interval: interval) else { return nil }
        guard matchesDirectory(
          machine: record.machine,
          directory: record.directory,
          selections: directorySelections
        ) else { return nil }
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
          machine: record.machine,
          directory: directoryResolved ? record.directory : nil
        )
      }
    case "daily":
      let records = directoryResolved
        ? aggregateSessions(
          snapshot.dashboardSessions,
          interval: interval,
          includeDirectory: true,
          directorySelections: directorySelections
        )
        : snapshot.dashboardMetrics
      let parse = memoizedDayParser()
      rows = records.compactMap { record in
        guard let timestamp = parse(record.date), isWithin(timestamp, interval: interval) else { return nil }
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
          machine: record.machine,
          directory: directoryResolved ? record.directory : nil
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

  public func parseDay(_ text: String) -> Date? { makeDayFormatter().date(from: text) }

  private func isWithin(_ date: Date, interval: DateInterval?) -> Bool {
    guard let interval else { return true }
    return date >= interval.start && date < interval.end
  }

  private func formatDay(_ date: Date) -> String { makeDayFormatter().string(from: date) }

  /// Returns a `String -> Date?` parser backed by one formatter and one memo, so a hot
  /// loop over metric rows builds at most one `DateFormatter` and parses each distinct
  /// day string once.
  private func memoizedDayParser() -> (String) -> Date? {
    let formatter = makeDayFormatter()
    var memo: [String: Date?] = [:]
    return { text in
      if let index = memo.index(forKey: text) { return memo[index].value }
      let value = formatter.date(from: text)
      memo[text] = value
      return value
    }
  }

  /// Returns a `Date -> day-string` formatter backed by one formatter and a per-day memo.
  /// Timestamps within the same calendar day format identically, so the memo collapses a
  /// per-row session loop to O(unique days) `DateFormatter` calls.
  private func memoizedDayFormatter() -> (Date) -> String {
    let formatter = makeDayFormatter()
    let calendar = self.calendar
    var memo: [Date: String] = [:]
    return { date in
      let key = calendar.startOfDay(for: date)
      if let cached = memo[key] { return cached }
      let value = formatter.string(from: date)
      memo[key] = value
      return value
    }
  }

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
    interval: DateInterval?,
    includeDirectory: Bool = false,
    directorySelections: DashboardDirectorySelections = [:]
  ) -> [CCUsageMetricRecord] {
    struct Key: Hashable {
      let date: String
      let agent: String
      let model: String
      let machine: String
      let directory: String?
    }
    struct Values {
      var costUSD = Decimal.zero
      var inputTokens = 0
      var outputTokens = 0
      var cacheCreationTokens = 0
      var cacheReadTokens = 0
    }
    var groups: [Key: Values] = [:]
    let day = memoizedDayFormatter()
    for session in sessions where isWithin(session.timestamp, interval: interval) {
      guard matchesDirectory(
        machine: session.machine,
        directory: session.directory,
        selections: directorySelections
      ) else { continue }
      let key = Key(
        date: day(session.timestamp),
        agent: session.agent,
        model: session.model,
        machine: session.machine,
        directory: includeDirectory ? session.directory : nil
      )
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
        machine: key.machine,
        directory: key.directory
      )
    }.sorted {
      ($0.date, $0.agent, $0.model, $0.machine, $0.directory ?? "")
        < ($1.date, $1.agent, $1.model, $1.machine, $1.directory ?? "")
    }
  }

  private func collapsedSessions(
    _ sessions: [CCUsageSessionMetricRecord]
  ) -> [CCUsageSessionMetricRecord] {
    struct Key: Hashable {
      let timestamp: Date
      let agent: String
      let model: String
      let machine: String
      let quality: UsageDataQuality
    }
    struct Values {
      var costUSD = Decimal.zero
      var inputTokens = 0
      var outputTokens = 0
      var cacheCreationTokens = 0
      var cacheReadTokens = 0
    }
    var groups: [Key: Values] = [:]
    for session in sessions {
      let key = Key(
        timestamp: session.timestamp,
        agent: session.agent,
        model: session.model,
        machine: session.machine,
        quality: session.dataQuality
      )
      var values = groups[key, default: Values()]
      values.costUSD += session.costUSD
      values.inputTokens += session.inputTokens
      values.outputTokens += session.outputTokens
      values.cacheCreationTokens += session.cacheCreationTokens
      values.cacheReadTokens += session.cacheReadTokens
      groups[key] = values
    }
    return groups.map { key, values in
      CCUsageSessionMetricRecord(
        timestamp: key.timestamp,
        agent: key.agent,
        model: key.model,
        costUSD: values.costUSD,
        inputTokens: values.inputTokens,
        outputTokens: values.outputTokens,
        cacheCreationTokens: values.cacheCreationTokens,
        cacheReadTokens: values.cacheReadTokens,
        dataQuality: key.quality,
        machine: key.machine
      )
    }.sorted(by: sessionsInIncreasingOrder)
  }

  private func matchesDirectory(
    machine: String,
    directory: String?,
    selections: DashboardDirectorySelections
  ) -> Bool {
    guard let selected = selections[machine], !selected.isEmpty else { return true }
    guard let directory else { return false }
    return selected.contains(directory)
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

  private func makeDayFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }
}

public enum DashboardQueryError: Error, Sendable { case invalidRange, invalidCustomRange, invalidGranularity }
