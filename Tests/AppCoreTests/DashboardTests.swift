import Foundation
import Testing
@testable import AppCore

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
    let sessions = [CCUsageSessionMetricRecord(timestamp: now.addingTimeInterval(-3_600), agent: "codex", model: "gpt-5.6-sol", costUSD: 2.5)]
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
    #expect(try query.costSeries(snapshot: snapshot, granularity: "hourly", range: "today", now: now).totalUSD == Decimal(string: "2.5"))
    #expect(try query.costSeries(snapshot: snapshot, granularity: "daily", range: "today", now: now).totalUSD == 4)
    #expect(throws: DashboardQueryError.invalidGranularity) {
      try query.costSeries(snapshot: snapshot, granularity: "weekly", range: "today", now: now)
    }
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
  @Test func servesRoutesAndValidatesInput() async throws {
    let root = try temporaryDirectory()
    try Data("<h1>dashboard</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
    let now = Date()
    let snapshot = CostSnapshot(generatedAt: now, activeBoundaryAt: now, costSinceResetUSD: 0, budget: BudgetSummary(spentUSD: 0, budgetUSD: nil), resetCycle: .daily, points: [])
    let router = DashboardRouter(snapshotProvider: { snapshot }, assetResolver: StaticAssetResolver(explicitRoot: root))
    #expect(await router.route(target: "/").status == 200)
    #expect(await router.route(target: "/api/recent").status == 200)
    #expect(await router.route(target: "/api/day?date=bad").status == 400)
    #expect(await router.route(target: "/api/period?range=custom&start=2026-07-16&end=2026-07-15").status == 400)
    #expect(await router.route(target: "/api/metrics?range=today").status == 200)
    #expect(await router.route(target: "/api/cost-series?range=today&granularity=hourly").status == 200)
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
