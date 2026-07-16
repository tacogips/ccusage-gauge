import Foundation
import Testing
@testable import AppCore

@Suite("ResetWindowTests") struct ResetWindowTests {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    value.firstWeekday = 2
    return value
  }

  @Test func calculatesCalendarAndCustomBoundaries() throws {
    let now = ISO8601DateFormatter().date(from: "2026-07-15T12:30:00Z")!
    var sundayFirstCalendar = calendar
    sundayFirstCalendar.firstWeekday = 1
    let calculator = ResetWindowCalculator(calendar: sundayFirstCalendar)
    #expect(try calculator.scheduledBoundary(for: .hourly, now: now) == ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
    #expect(try calculator.scheduledBoundary(for: .daily, now: now) == ISO8601DateFormatter().date(from: "2026-07-15T00:00:00Z"))
    #expect(try calculator.scheduledBoundary(for: .weekly, now: now) == ISO8601DateFormatter().date(from: "2026-07-13T00:00:00Z"))
    #expect(try calculator.scheduledBoundary(for: .monthly, now: now) == ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
    #expect(try calculator.scheduledBoundary(for: .customHours(6), now: now) == ISO8601DateFormatter().date(from: "2026-07-15T06:30:00Z"))
  }

  @Test func calendarPeriodsHaveExclusiveNextBoundary() throws {
    let now = ISO8601DateFormatter().date(from: "2026-07-15T12:30:00Z")!
    let calculator = ResetWindowCalculator(calendar: calendar)
    #expect(try calculator.aggregationInterval(for: .hourly, now: now).end == ISO8601DateFormatter().date(from: "2026-07-15T13:00:00Z"))
    #expect(try calculator.aggregationInterval(for: .daily, now: now).end == ISO8601DateFormatter().date(from: "2026-07-16T00:00:00Z"))
    #expect(try calculator.aggregationInterval(for: .weekly, now: now).end == ISO8601DateFormatter().date(from: "2026-07-20T00:00:00Z"))
  }

  @Test func selectedCycleExclusivelyDeterminesBoundary() throws {
    let now = ISO8601DateFormatter().date(from: "2026-07-15T12:30:00Z")!
    let calculator = ResetWindowCalculator(calendar: calendar)
    let baseline = try calculator.baseline(for: AppState(resetCycle: .daily), now: now)
    #expect(baseline.activeBoundaryAt == ISO8601DateFormatter().date(from: "2026-07-15T00:00:00Z"))
  }
}

@Suite("BudgetSummaryTests") struct BudgetSummaryTests {
  @Test func capsOnlyVisualFractionAndPreservesOverage() {
    let summary = BudgetSummary(spentUSD: 125, budgetUSD: 100)
    #expect(summary.remainingUSD == 0)
    #expect(summary.overageUSD == 25)
    #expect(summary.usagePercentage == 125)
    #expect(summary.visualFraction == 1)
    #expect(summary.spentUSD == 125)
  }

  @Test func omitsPercentageWhenBudgetIsNotPositive() {
    #expect(BudgetSummary(spentUSD: 10, budgetUSD: nil).usagePercentage == nil)
    #expect(BudgetSummary(spentUSD: 10, budgetUSD: 0).usagePercentage == nil)
  }
}

@Suite("CostSnapshotMutationTests") struct CostSnapshotMutationTests {
  @Test func immediatelyAppliesSelectedPeriodAndBudgetWithoutReloadingUsage() throws {
    let formatter = ISO8601DateFormatter()
    let now = formatter.date(from: "2026-07-15T12:30:00Z")!
    let beforeBoundary = now.addingTimeInterval(-3600)
    let afterBoundary = now.addingTimeInterval(1)
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: beforeBoundary,
      costSinceResetUSD: 7,
      budget: BudgetSummary(spentUSD: 7, budgetUSD: 10),
      resetCycle: .hourly,
      points: [],
      dashboardSessions: [
        CCUsageSessionMetricRecord(timestamp: beforeBoundary, agent: "codex", model: "gpt", costUSD: 7),
        CCUsageSessionMetricRecord(timestamp: afterBoundary, agent: "codex", model: "gpt", costUSD: 2)
      ]
    )
    let baseline = ResetBaseline(
      scheduledBoundaryAt: now.addingTimeInterval(-1800),
      activeBoundaryAt: now.addingTimeInterval(-1800),
      cycle: .hourly,
      calendarIdentifier: "gregorian",
      timeZoneIdentifier: "UTC",
      computedAt: now
    )

    let updated = try #require(snapshot.applying(
      state: AppState(budgetUSD: 20, resetCycle: .hourly, baseline: baseline),
      now: afterBoundary
    ))

    #expect(updated.costSinceResetUSD == 2)
    #expect(updated.budget.spentUSD == 2)
    #expect(updated.budget.budgetUSD == 20)
    #expect(updated.activeBoundaryAt == now.addingTimeInterval(-1800))
  }
}
