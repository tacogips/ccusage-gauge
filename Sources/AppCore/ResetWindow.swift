import Foundation

public struct ResetWindowCalculator: Sendable {
  public var calendar: Calendar

  public init(calendar: Calendar = .current) { self.calendar = calendar }

  public func aggregationInterval(for cycle: ResetCycle, now: Date) throws -> DateInterval {
    switch cycle {
    case .hourly:
      guard let interval = calendar.dateInterval(of: .hour, for: now) else { throw ResetWindowError.boundaryUnavailable }
      return interval
    case .daily:
      guard let interval = calendar.dateInterval(of: .day, for: now) else { throw ResetWindowError.boundaryUnavailable }
      return interval
    case .weekly:
      var mondayCalendar = calendar
      mondayCalendar.firstWeekday = 2
      mondayCalendar.minimumDaysInFirstWeek = 4
      guard let interval = mondayCalendar.dateInterval(of: .weekOfYear, for: now) else {
        throw ResetWindowError.boundaryUnavailable
      }
      return interval
    case .monthly:
      guard let interval = calendar.dateInterval(of: .month, for: now) else { throw ResetWindowError.boundaryUnavailable }
      return interval
    case .customHours(let hours):
      guard hours > 0, let start = calendar.date(byAdding: .hour, value: -hours, to: now) else {
        throw ResetWindowError.boundaryUnavailable
      }
      return DateInterval(start: start, end: now)
    }
  }

  public func scheduledBoundary(for cycle: ResetCycle, now: Date) throws -> Date {
    try aggregationInterval(for: cycle, now: now).start
  }

  public func baseline(for state: AppState, now: Date) throws -> ResetBaseline {
    let scheduled = try scheduledBoundary(for: state.resetCycle, now: now)
    return ResetBaseline(
      scheduledBoundaryAt: scheduled,
      activeBoundaryAt: scheduled,
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
          existing.activeBoundaryAt == expected.activeBoundaryAt,
          existing.cycle == expected.cycle,
          existing.calendarIdentifier == expected.calendarIdentifier,
          existing.timeZoneIdentifier == expected.timeZoneIdentifier else {
      var updated = state
      updated.baseline = expected
      return updated
    }
    return state
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
