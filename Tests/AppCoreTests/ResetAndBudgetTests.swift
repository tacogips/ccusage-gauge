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
    #expect(summary.visualFraction == 1)
    #expect(summary.spentUSD == 125)
  }
}
