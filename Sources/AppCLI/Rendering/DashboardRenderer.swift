import AppCore
import Foundation

/// Renders dashboard query responses as compact text summaries. Partial
/// aggregate scope is always surfaced: stale and unavailable machines are listed
/// rather than silently dropped.
enum DashboardRenderer {
  static func budget(_ scoped: ScopedResponse<BudgetResponse>) -> String {
    let budget = scoped.body
    var lines = [
      "spent: \(usd(budget.spentUSD))",
      "budget: \(budget.budgetUSD.map(usd) ?? "unset")"
    ]
    if let remaining = budget.remainingUSD {
      lines.append("remaining: \(usd(remaining))")
    }
    if budget.overageUSD > 0 {
      lines.append("overage: \(usd(budget.overageUSD))")
    }
    lines.append("resetCycle: \(budget.resetCycle)")
    lines.append("activeBoundaryAt: \(iso(budget.activeBoundaryAt))")
    lines.append(scopeLine(scoped.scope))
    return lines.joined(separator: "\n")
  }

  static func recent(_ scoped: ScopedResponse<RecentResponse>) -> String {
    seriesSummary(label: "recent", total: scoped.body.totalUSD, count: scoped.body.series.count, scope: scoped.scope)
  }

  static func day(_ scoped: ScopedResponse<DayResponse>) -> String {
    seriesSummary(label: "day \(scoped.body.date)", total: scoped.body.totalUSD, count: scoped.body.series.count, scope: scoped.scope)
  }

  static func period(_ scoped: ScopedResponse<PeriodResponse>) -> String {
    seriesSummary(label: "period \(scoped.body.range)", total: scoped.body.totalUSD, count: scoped.body.series.count, scope: scoped.scope)
  }

  static func metrics(_ scoped: ScopedResponse<DashboardMetricsResponse>) -> String {
    let metrics = scoped.body
    var lines = [
      "range: \(metrics.range)",
      "total: \(usd(metrics.totals.costUSD)) tokens=\(metrics.totals.totalTokens)",
      "rows: \(metrics.rows.count)"
    ]
    for row in metrics.rows {
      lines.append("  \(row.date)  \(row.agent)/\(row.model)  \(usd(row.costUSD))  tokens=\(row.totalTokens)  [\(row.machine)]")
    }
    lines.append(scopeLine(scoped.scope))
    return lines.joined(separator: "\n")
  }

  static func costSeries(_ scoped: ScopedResponse<DashboardCostResponse>) -> String {
    let series = scoped.body
    var lines = [
      "range: \(series.range)",
      "granularity: \(series.granularity)",
      "total: \(usd(series.totalUSD))",
      "rows: \(series.rows.count)"
    ]
    if let start = series.timelineStart, let end = series.timelineEndExclusive {
      lines.append("timeline: \(iso(start)) .. \(iso(end))")
    }
    lines.append(scopeLine(scoped.scope))
    return lines.joined(separator: "\n")
  }

  private static func seriesSummary(label: String, total: Decimal, count: Int, scope: DashboardScope) -> String {
    [
      "\(label): total=\(usd(total)) points=\(count)",
      scopeLine(scope)
    ].joined(separator: "\n")
  }

  private static func scopeLine(_ scope: DashboardScope) -> String {
    var parts = ["scope: requested=\(scope.requested)"]
    parts.append("included=[\(scope.includedMachineIds.joined(separator: ","))]")
    if !scope.staleMachineIds.isEmpty {
      parts.append("stale=[\(scope.staleMachineIds.joined(separator: ","))]")
    }
    if !scope.unavailableMachineIds.isEmpty {
      parts.append("unavailable=[\(scope.unavailableMachineIds.joined(separator: ","))]")
    }
    return parts.joined(separator: " ")
  }

  private static func usd(_ value: Decimal) -> String {
    "$\(NSDecimalNumber(decimal: value).stringValue)"
  }

  private static func iso(_ date: Date) -> String {
    date.ISO8601Format()
  }
}
