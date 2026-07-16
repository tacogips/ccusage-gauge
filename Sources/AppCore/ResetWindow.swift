import Foundation

public struct ResetWindowCalculator: Sendable {
  public var calendar: Calendar

  public init(calendar: Calendar = .current) { self.calendar = calendar }

  public func scheduledBoundary(for cycle: ResetCycle, now: Date) throws -> Date {
    switch cycle {
    case .daily:
      return calendar.startOfDay(for: now)
    case .weekly:
      guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { throw ResetWindowError.boundaryUnavailable }
      return interval.start
    case .monthly:
      guard let interval = calendar.dateInterval(of: .month, for: now) else { throw ResetWindowError.boundaryUnavailable }
      return interval.start
    case .customHours(let hours):
      guard hours > 0, let boundary = calendar.date(byAdding: .hour, value: -hours, to: now) else {
        throw ResetWindowError.boundaryUnavailable
      }
      return boundary
    }
  }

  public func baseline(for state: AppState, now: Date) throws -> ResetBaseline {
    let scheduled = try scheduledBoundary(for: state.resetCycle, now: now)
    let manual = state.lastManualResetAt
    let manualWins = manual.map { $0 > scheduled } ?? false
    return ResetBaseline(
      scheduledBoundaryAt: scheduled,
      manualResetAtConsidered: manual,
      activeBoundaryAt: manualWins ? manual! : scheduled,
      boundaryKind: manualWins ? .manual : .scheduled,
      cycle: state.resetCycle,
      calendarIdentifier: calendar.identifier.debugDescription,
      timeZoneIdentifier: calendar.timeZone.identifier,
      computedAt: now
    )
  }

  public func validatedState(_ state: AppState, now: Date) throws -> AppState {
    let expected = try baseline(for: state, now: now)
    guard let existing = state.baseline,
          existing.scheduledBoundaryAt == expected.scheduledBoundaryAt,
          existing.manualResetAtConsidered == expected.manualResetAtConsidered,
          existing.cycle == expected.cycle,
          existing.calendarIdentifier == expected.calendarIdentifier,
          existing.timeZoneIdentifier == expected.timeZoneIdentifier else {
      var updated = state
      updated.baseline = expected
      return updated
    }
    return state
  }

  public func resetting(_ state: AppState, at now: Date) throws -> AppState {
    var updated = state
    updated.lastManualResetAt = now
    updated.baseline = nil
    return try validatedState(updated, now: now)
  }

  public func changing(_ state: AppState, to cycle: ResetCycle, at now: Date) throws -> AppState {
    var updated = state
    updated.resetCycle = cycle
    updated.baseline = nil
    return try validatedState(updated, now: now)
  }
}

public enum ResetWindowError: Error, Sendable { case boundaryUnavailable }

public struct BudgetSummary: Codable, Equatable, Sendable {
  public let budgetUSD: Decimal?
  public let spentUSD: Decimal
  public let remainingUSD: Decimal?
  public let overageUSD: Decimal
  public let usagePercentage: Decimal?
  public let visualFraction: Decimal?

  public init(spentUSD: Decimal, budgetUSD: Decimal?) {
    let spent = max(spentUSD, 0)
    self.budgetUSD = budgetUSD
    self.spentUSD = spent
    guard let budgetUSD, budgetUSD > 0 else {
      remainingUSD = nil
      overageUSD = 0
      usagePercentage = nil
      visualFraction = nil
      return
    }
    remainingUSD = max(budgetUSD - spent, 0)
    overageUSD = max(spent - budgetUSD, 0)
    usagePercentage = spent / budgetUSD * 100
    visualFraction = min(spent / budgetUSD, 1)
  }
}
