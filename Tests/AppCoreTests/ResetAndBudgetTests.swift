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
    let calculator = ResetWindowCalculator(calendar: calendar)
    #expect(try calculator.scheduledBoundary(for: .daily, now: now) == ISO8601DateFormatter().date(from: "2026-07-15T00:00:00Z"))
    #expect(try calculator.scheduledBoundary(for: .weekly, now: now) == ISO8601DateFormatter().date(from: "2026-07-13T00:00:00Z"))
    #expect(try calculator.scheduledBoundary(for: .monthly, now: now) == ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
    #expect(try calculator.scheduledBoundary(for: .customHours(6), now: now) == ISO8601DateFormatter().date(from: "2026-07-15T06:30:00Z"))
  }

  @Test func laterManualResetWinsAndOlderOneDoesNot() throws {
    let now = ISO8601DateFormatter().date(from: "2026-07-15T12:30:00Z")!
    let calculator = ResetWindowCalculator(calendar: calendar)
    let later = now.addingTimeInterval(-60)
    let laterBaseline = try calculator.baseline(for: AppState(resetCycle: .daily, lastManualResetAt: later), now: now)
    #expect(laterBaseline.activeBoundaryAt == later)
    #expect(laterBaseline.boundaryKind == .manual)
    let older = now.addingTimeInterval(-172_800)
    let olderBaseline = try calculator.baseline(for: AppState(resetCycle: .daily, lastManualResetAt: older), now: now)
    #expect(olderBaseline.boundaryKind == .scheduled)
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
  @Test func immediatelyAppliesResetBoundaryAndBudgetWithoutReloadingUsage() throws {
    let formatter = ISO8601DateFormatter()
    let now = formatter.date(from: "2026-07-15T12:30:00Z")!
    let beforeReset = now.addingTimeInterval(-300)
    let afterReset = now.addingTimeInterval(1)
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: beforeReset,
      costSinceResetUSD: 7,
      budget: BudgetSummary(spentUSD: 7, budgetUSD: 10),
      resetCycle: .daily,
      points: [
        CCUsageCostRecord(timestamp: beforeReset, costUSD: 7, models: ["gpt"]),
        CCUsageCostRecord(timestamp: afterReset, costUSD: 2, models: ["gpt"])
      ]
    )
    let baseline = ResetBaseline(
      scheduledBoundaryAt: beforeReset,
      manualResetAtConsidered: now,
      activeBoundaryAt: now,
      boundaryKind: .manual,
      cycle: .daily,
      calendarIdentifier: "gregorian",
      timeZoneIdentifier: "UTC",
      computedAt: now
    )

    let updated = try #require(snapshot.applying(
      state: AppState(budgetUSD: 20, resetCycle: .daily, lastManualResetAt: now, baseline: baseline),
      now: afterReset
    ))

    #expect(updated.costSinceResetUSD == 2)
    #expect(updated.budget.spentUSD == 2)
    #expect(updated.budget.budgetUSD == 20)
    #expect(updated.activeBoundaryAt == now)
  }
}
