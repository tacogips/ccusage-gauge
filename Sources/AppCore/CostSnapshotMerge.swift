import Foundation

private struct CostPointKey: Hashable {
  let timestamp: Date
  let machine: String
}

private struct MetricRowKey: Hashable {
  let date: String
  let agent: String
  let model: String
  let machine: String
}

private struct SessionRowKey: Hashable {
  let timestamp: Date
  let agent: String
  let model: String
  let machine: String
  let quality: UsageDataQuality
}

func mergingSnapshots(
  existing: CostSnapshot?,
  fresh: CostSnapshot,
  calendar: Calendar
) -> CostSnapshot {
  guard let existing else { return fresh }
  var points: [CostPointKey: CCUsageCostRecord] = [:]
  existing.points.forEach { points[CostPointKey(timestamp: $0.timestamp, machine: $0.machine)] = $0 }
  fresh.points.forEach { points[CostPointKey(timestamp: $0.timestamp, machine: $0.machine)] = $0 }
  var metrics: [MetricRowKey: CCUsageMetricRecord] = [:]
  existing.dashboardMetrics.forEach {
    metrics[MetricRowKey(date: $0.date, agent: $0.agent, model: $0.model, machine: $0.machine)] = $0
  }
  fresh.dashboardMetrics.forEach {
    metrics[MetricRowKey(date: $0.date, agent: $0.agent, model: $0.model, machine: $0.machine)] = $0
  }
  var sessions: [SessionRowKey: CCUsageSessionMetricRecord] = [:]
  existing.dashboardSessions.forEach {
    sessions[
      SessionRowKey(
        timestamp: $0.timestamp,
        agent: $0.agent,
        model: $0.model,
        machine: $0.machine,
        quality: $0.dataQuality
      )
    ] = $0
  }
  fresh.dashboardSessions.forEach {
    sessions[
      SessionRowKey(
        timestamp: $0.timestamp,
        agent: $0.agent,
        model: $0.model,
        machine: $0.machine,
        quality: $0.dataQuality
      )
    ] = $0
  }
  let mergedMetrics = metrics.values.sorted(by: metricsInIncreasingOrder)
  let mergedSessions = sessions.values.sorted(by: sessionsInIncreasingOrder)
  let interval = DateInterval(start: fresh.activeBoundaryAt, end: max(fresh.generatedAt, fresh.activeBoundaryAt))
  let cost = selectedPeriodCost(
    cycle: fresh.resetCycle,
    interval: interval,
    metrics: mergedMetrics,
    sessions: mergedSessions,
    calendar: calendar
  )
  return CostSnapshot(
    generatedAt: max(existing.generatedAt, fresh.generatedAt),
    activeBoundaryAt: fresh.activeBoundaryAt,
    costSinceResetUSD: cost,
    budget: BudgetSummary(spentUSD: cost, budgetUSD: fresh.budget.budgetUSD),
    resetCycle: fresh.resetCycle,
    refreshIntervalSeconds: fresh.refreshIntervalSeconds,
    points: points.values.sorted { $0.timestamp < $1.timestamp },
    dashboardMetrics: mergedMetrics,
    dashboardSessions: mergedSessions
  )
}
