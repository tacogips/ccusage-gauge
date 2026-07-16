import Foundation
import Testing
@testable import AppCore

private actor SnapshotLoadCounter {
  private(set) var value = 0

  func increment() { value += 1 }
}

private actor SnapshotRangeRecorder {
  private(set) var earliestDate: Date?
  private(set) var requestCount = 0

  func record(_ date: Date?) {
    earliestDate = date
    requestCount += 1
  }
}

private actor ControlledSnapshotLoader {
  private let snapshot: CostSnapshot
  private var requests: [Date?] = []
  private var continuations: [CheckedContinuation<CostSnapshot, Never>] = []

  init(snapshot: CostSnapshot) { self.snapshot = snapshot }

  func load(_ date: Date?) async -> CostSnapshot {
    requests.append(date)
    return await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  var requestDates: [Date?] { requests }

  func releaseAll() {
    let waiting = continuations
    continuations.removeAll()
    for continuation in waiting { continuation.resume(returning: snapshot) }
  }
}

private actor CacheClearCounter {
  private(set) var value = 0

  func increment() { value += 1 }
}

@Suite("DashboardQueryTests") struct DashboardQueryTests {
  @Test func groupsSelectedDayAndBudget() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!
    let points = [CCUsageCostRecord(timestamp: now, costUSD: 2, models: ["a"]), CCUsageCostRecord(timestamp: now.addingTimeInterval(-86_400), costUSD: 5, models: ["b"])]
    let snapshot = CostSnapshot(generatedAt: now, activeBoundaryAt: now.addingTimeInterval(-3600), costSinceResetUSD: 2, budget: BudgetSummary(spentUSD: 2, budgetUSD: 10), resetCycle: .daily, points: points)
    let query = DashboardQueryService(calendar: calendar)
    #expect(query.day(snapshot: snapshot, date: now).totalUSD == 2)
    #expect(query.budget(snapshot: snapshot).remainingUSD == 8)
    #expect(query.budget(snapshot: snapshot).usagePercentage == 20)
    #expect(query.budget(snapshot: snapshot).refreshIntervalSeconds == 20)
  }

  @Test func aggregatesDetailedMetricsForExactAgentAndModelRows() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let metrics = [
      CCUsageMetricRecord(date: "2026-07-16", agent: "codex", model: "gpt-5.6-sol", costUSD: 2.5, inputTokens: 10, outputTokens: 3, cacheCreationTokens: 0, cacheReadTokens: 20),
      CCUsageMetricRecord(date: "2026-07-16", agent: "claude", model: "claude-opus-4-8", costUSD: 1.25, inputTokens: 4, outputTokens: 2, cacheCreationTokens: 5, cacheReadTokens: 8),
      CCUsageMetricRecord(date: "2026-07-15", agent: "codex", model: "gpt-5.5", costUSD: 4, inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0)
    ]
    let snapshot = CostSnapshot(generatedAt: now, activeBoundaryAt: now, costSinceResetUSD: 0, budget: BudgetSummary(spentUSD: 0, budgetUSD: nil), resetCycle: .daily, points: [], dashboardMetrics: metrics)
    let response = try DashboardQueryService(calendar: calendar).metrics(snapshot: snapshot, range: "today", now: now)
    #expect(response.rows.count == 2)
    #expect(response.totals.costUSD == Decimal(string: "3.75"))
    #expect(response.totals.totalTokens == 52)
  }

  @Test func selectsHourlySessionAndDailyCostSources() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let metrics = [CCUsageMetricRecord(date: "2026-07-16", agent: "codex", model: "gpt-5.6-sol", costUSD: 4, inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0)]
    let sessions = [CCUsageSessionMetricRecord(
      timestamp: now.addingTimeInterval(-3_600),
      agent: "codex",
      model: "gpt-5.6-sol",
      costUSD: 2.5,
      inputTokens: 10,
      outputTokens: 3,
      cacheCreationTokens: 0,
      cacheReadTokens: 20
    )]
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now,
      costSinceResetUSD: 0,
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: [],
      dashboardMetrics: metrics,
      dashboardSessions: sessions
    )
    let query = DashboardQueryService(calendar: calendar)
    let hourly = try query.costSeries(snapshot: snapshot, granularity: "hourly", range: "today", now: now)
    let quarterHourly = try query.costSeries(snapshot: snapshot, granularity: "15min", range: "today", now: now)
    let sixHourly = try query.costSeries(snapshot: snapshot, granularity: "6hour", range: "today", now: now)
    let daily = try query.costSeries(snapshot: snapshot, granularity: "daily", range: "today", now: now)
    #expect(hourly.totalUSD == Decimal(string: "2.5"))
    #expect(hourly.timelineStart == calendar.startOfDay(for: now))
    #expect(hourly.timelineEndExclusive == now)
    #expect(quarterHourly.rows == hourly.rows)
    #expect(sixHourly.rows == hourly.rows)
    #expect(hourly.rows.first?.totalTokens == 33)
    #expect(daily.totalUSD == 4)
    #expect(daily.rows.first?.totalTokens == 2)
    #expect(throws: DashboardQueryError.invalidGranularity) {
      try query.costSeries(snapshot: snapshot, granularity: "weekly", range: "today", now: now)
    }
  }

  @Test func monthCostSeriesIncludesContinuousTimelineBoundsThroughNow() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:34:56Z")!
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now,
      costSinceResetUSD: 0,
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: []
    )

    let response = try DashboardQueryService(calendar: calendar).costSeries(
      snapshot: snapshot,
      granularity: "hourly",
      range: "month",
      now: now
    )

    #expect(response.timelineStart == ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
    #expect(response.timelineEndExclusive == now)
    #expect(response.rows.isEmpty)
  }

  @Test func recentTwelveHoursUsesOnlySessionsInsideRollingWindow() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let sessions = [
      CCUsageSessionMetricRecord(
        timestamp: now.addingTimeInterval(-11 * 3_600),
        agent: "codex",
        model: "recent-model",
        costUSD: 2,
        inputTokens: 3,
        outputTokens: 4
      ),
      CCUsageSessionMetricRecord(
        timestamp: now.addingTimeInterval(-13 * 3_600),
        agent: "claude",
        model: "old-model",
        costUSD: 9,
        inputTokens: 10
      )
    ]
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now,
      costSinceResetUSD: 0,
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: [],
      dashboardSessions: sessions
    )
    let query = DashboardQueryService(calendar: calendar)
    let metrics = try query.metrics(snapshot: snapshot, range: "recent12h", now: now)
    let hourly = try query.costSeries(snapshot: snapshot, granularity: "hourly", range: "recent12h", now: now)
    #expect(metrics.rows.map(\.model) == ["recent-model"])
    #expect(metrics.totals.costUSD == 2)
    #expect(metrics.totals.totalTokens == 7)
    #expect(hourly.rows.map(\.model) == ["recent-model"])
  }

  @Test func yesterdayExcludesRowsAtTodayBoundary() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let metrics = [
      CCUsageMetricRecord(date: "2026-07-15", agent: "claude", model: "yesterday-model", costUSD: 1, inputTokens: 1, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0),
      CCUsageMetricRecord(date: "2026-07-16", agent: "codex", model: "today-model", costUSD: 2, inputTokens: 1, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
    ]
    let sessions = [
      CCUsageSessionMetricRecord(timestamp: ISO8601DateFormatter().date(from: "2026-07-15T23:59:59Z")!, agent: "claude", model: "yesterday-model", costUSD: 1),
      CCUsageSessionMetricRecord(timestamp: ISO8601DateFormatter().date(from: "2026-07-16T00:00:00Z")!, agent: "codex", model: "today-model", costUSD: 2)
    ]
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now,
      costSinceResetUSD: 0,
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: [],
      dashboardMetrics: metrics,
      dashboardSessions: sessions
    )
    let query = DashboardQueryService(calendar: calendar)
    #expect(try query.metrics(snapshot: snapshot, range: "yesterday", now: now).rows.map(\.model) == ["yesterday-model"])
    #expect(try query.costSeries(snapshot: snapshot, granularity: "hourly", range: "yesterday", now: now).rows.map(\.model) == ["yesterday-model"])
  }

  @Test func customRangeIncludesBothWholeCalendarDays() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let formatter = ISO8601DateFormatter()
    let firstDay = formatter.date(from: "2026-07-14T00:00:00Z")!
    let secondDayEnd = formatter.date(from: "2026-07-15T23:59:59Z")!
    let outside = formatter.date(from: "2026-07-16T00:00:00Z")!
    let points = [
      CCUsageCostRecord(timestamp: firstDay, costUSD: 1, models: ["a"]),
      CCUsageCostRecord(timestamp: secondDayEnd, costUSD: 2, models: ["b"]),
      CCUsageCostRecord(timestamp: outside, costUSD: 4, models: ["c"])
    ]
    let snapshot = CostSnapshot(
      generatedAt: outside,
      activeBoundaryAt: firstDay,
      costSinceResetUSD: 7,
      budget: BudgetSummary(spentUSD: 7, budgetUSD: nil),
      resetCycle: .daily,
      points: points
    )
    let query = DashboardQueryService(calendar: calendar)
    let response = try query.period(snapshot: snapshot, startDate: firstDay, endDate: secondDayEnd)
    #expect(response.totalUSD == 3)
    #expect(response.series.count == 2)
    #expect(throws: DashboardQueryError.invalidCustomRange) {
      try query.period(snapshot: snapshot, startDate: outside, endDate: firstDay)
    }
  }
}

@Suite("StaticAssetResolverTests") struct StaticAssetResolverTests {
  @Test func explicitRootIsAuthoritative() throws {
    let explicit = try temporaryDirectory()
    let executable = try temporaryDirectory().appendingPathComponent("bin/ccusage-gauge")
    let resolver = StaticAssetResolver(explicitRoot: explicit, executableURL: executable)
    #expect(resolver.roots() == [explicit])
    #expect(resolver.resolve(path: "/") == nil)
  }

  @Test func resolvesFormulaAndCaskLayouts() throws {
    let root = try temporaryDirectory()
    let formulaExecutable = root.appendingPathComponent("formula/bin/ccusage-gauge")
    let formulaAssets = root.appendingPathComponent("formula/share/ccusage-gauge/web")
    try FileManager.default.createDirectory(at: formulaAssets, withIntermediateDirectories: true)
    try Data("formula".utf8).write(to: formulaAssets.appendingPathComponent("index.html"))
    #expect(StaticAssetResolver(executableURL: formulaExecutable).resolve(path: "/") != nil)

    let caskExecutable = root.appendingPathComponent("CCUsageGauge.app/Contents/MacOS/ccusage-gauge")
    let caskAssets = root.appendingPathComponent("CCUsageGauge.app/Contents/Resources/Web")
    try FileManager.default.createDirectory(at: caskAssets, withIntermediateDirectories: true)
    try Data("cask".utf8).write(to: caskAssets.appendingPathComponent("index.html"))
    #expect(StaticAssetResolver(executableURL: caskExecutable).resolve(path: "/") != nil)
  }
}

@Suite("APIRouteTests") struct APIRouteTests {
  @Test func preloadStartsWeeklyAndHistoricalLoadsConcurrently() async throws {
    let root = try temporaryDirectory()
    try Data("<h1>dashboard</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now,
      costSinceResetUSD: 0,
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: []
    )
    let loader = ControlledSnapshotLoader(snapshot: snapshot)
    let router = DashboardRouter(
      rangeSnapshotProvider: { await loader.load($0) },
      assetResolver: StaticAssetResolver(explicitRoot: root)
    )
    let preload = Task { await router.preloadSnapshot() }

    for _ in 0..<1_000 {
      if await loader.requestDates.count == 2 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    let requests = await loader.requestDates
    #expect(requests.count == 2)
    #expect(requests.contains(where: { $0 == nil }))
    #expect(requests.contains(where: { $0 != nil }))

    await loader.releaseAll()
    await preload.value
  }

  @Test func initialSnapshotWarmsPreviousMonthAfterCurrentWeek() async throws {
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now,
      costSinceResetUSD: 0,
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: []
    )
    let recorder = SnapshotRangeRecorder()
    let cache = DashboardSnapshotCache(
      maxAgeSeconds: 60,
      now: { now },
      progressiveLoader: { date, progress in
        await recorder.record(date)
        let total = date == nil ? 1 : 9
        await progress?(SnapshotLoadProgress(completed: 0, total: total))
        await progress?(SnapshotLoadProgress(completed: total, total: total))
        return snapshot
      }
    )

    _ = try await cache.snapshot()
    let weeklyStatus = await cache.status()
    #expect(weeklyStatus.phase == .loadingHistory)
    #expect(weeklyStatus.completed == 0)
    #expect(weeklyStatus.total == 1)
    #expect(weeklyStatus.isLoading)
    _ = try await cache.warmHistoricalCoverage()
    let readyStatus = await cache.status()

    var calendar = Calendar.current
    calendar.timeZone = TimeZone.current
    let monthStart = try #require(calendar.dateInterval(of: .month, for: now)?.start)
    let expected = try #require(calendar.date(byAdding: .month, value: -1, to: monthStart))
    #expect(await recorder.requestCount == 2)
    #expect(await recorder.earliestDate == expected)
    #expect(readyStatus.phase == .ready)
    #expect(readyStatus.completed == 9)
    #expect(readyStatus.total == 9)
    #expect(!readyStatus.isLoading)
  }

  @Test func clearingCacheInvalidatesPersistentAndSnapshotCaches() async throws {
    let root = try temporaryDirectory()
    try Data("<h1>dashboard</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
    let now = Date()
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now,
      costSinceResetUSD: 0,
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: []
    )
    let loads = SnapshotLoadCounter()
    let clears = CacheClearCounter()
    let router = DashboardRouter(
      rangeSnapshotProvider: { _ in
        await loads.increment()
        return snapshot
      },
      assetResolver: StaticAssetResolver(explicitRoot: root),
      cacheClearer: { await clears.increment() }
    )

    #expect(await router.route(target: "/api/metrics?range=today").status == 200)
    #expect(await loads.value == 1)
    #expect(await router.route(target: "/api/cache", method: "DELETE").status == 200)
    #expect(await clears.value == 1)
    for _ in 0..<1_000 {
      if await loads.value == 3 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await loads.value == 3)
    #expect(await router.route(target: "/api/metrics?range=today").status == 200)
    #expect(await loads.value == 3)
    #expect(await router.route(target: "/api/cache", method: "POST").status == 405)
  }

  @Test func customRangeRequestsOlderSnapshotCoverage() async throws {
    let root = try temporaryDirectory()
    try Data("<h1>dashboard</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
    let now = Date()
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now,
      costSinceResetUSD: 0,
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: []
    )
    let recorder = SnapshotRangeRecorder()
    let query = DashboardQueryService()
    let expected = try #require(query.parseDay("2026-04-01"))
    let router = DashboardRouter(
      rangeSnapshotProvider: {
        await recorder.record($0)
        return snapshot
      },
      queryService: query,
      assetResolver: StaticAssetResolver(explicitRoot: root)
    )

    let response = await router.route(target: "/api/metrics?range=custom&start=2026-04-01&end=2026-04-30")

    #expect(response.status == 200)
    #expect(await recorder.earliestDate == expected)
  }

  @Test func coalescesConcurrentSnapshotRequests() async throws {
    let root = try temporaryDirectory()
    try Data("<h1>dashboard</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
    let now = Date()
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now,
      costSinceResetUSD: 0,
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: []
    )
    let counter = SnapshotLoadCounter()
    let router = DashboardRouter(
      snapshotProvider: {
        await counter.increment()
        try await Task.sleep(for: .milliseconds(50))
        return snapshot
      },
      assetResolver: StaticAssetResolver(explicitRoot: root)
    )
    async let metrics = router.route(target: "/api/metrics?range=today")
    async let cost = router.route(target: "/api/cost-series?range=today&granularity=hourly")
    async let budget = router.route(target: "/api/budget")
    let responses = await [metrics, cost, budget]
    #expect(responses.allSatisfy { $0.status == 200 })
    #expect(await counter.value == 1)
    #expect(await router.route(target: "/api/refresh").status == 200)
    #expect(await counter.value == 2)
  }

  @Test func servesRoutesAndValidatesInput() async throws {
    let root = try temporaryDirectory()
    try Data("<h1>dashboard</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
    let now = Date()
    let snapshot = CostSnapshot(generatedAt: now, activeBoundaryAt: now, costSinceResetUSD: 0, budget: BudgetSummary(spentUSD: 0, budgetUSD: nil), resetCycle: .daily, points: [])
    let router = DashboardRouter(snapshotProvider: { snapshot }, assetResolver: StaticAssetResolver(explicitRoot: root))
    #expect(await router.route(target: "/").status == 200)
    #expect(await router.route(target: "/api/recent").status == 200)
    #expect(await router.route(target: "/api/refresh").status == 200)
    #expect(await router.route(target: "/api/day?date=bad").status == 400)
    #expect(await router.route(target: "/api/period?range=custom&start=2026-07-16&end=2026-07-15").status == 400)
    #expect(await router.route(target: "/api/metrics?range=today").status == 200)
    #expect(await router.route(target: "/api/metrics?range=recent12h").status == 200)
    #expect(await router.route(target: "/api/load-status").status == 200)
    #expect(await router.route(target: "/api/cost-series?range=today&granularity=hourly").status == 200)
    #expect(await router.route(target: "/api/cost-series?range=today&granularity=15min").status == 200)
    #expect(await router.route(target: "/api/cost-series?range=today&granularity=weekly").status == 400)
    #expect(await router.route(target: "/api/missing").status == 404)
  }

  @Test func reportsMissingAssetsWithoutListing() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let router = DashboardRouter(snapshotProvider: { throw CCUsageError.invalidJSON }, assetResolver: StaticAssetResolver(explicitRoot: root))
    let response = await router.route(target: "/")
    #expect(response.status == 503)
    #expect(String(data: response.body, encoding: .utf8)?.contains("assets_missing") == true)
  }
}
