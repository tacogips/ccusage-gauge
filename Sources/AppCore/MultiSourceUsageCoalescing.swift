import Foundation

// Multiple session sources on one machine legitimately produce rows that share
// (date/timestamp, agent, model, machine). Downstream snapshot merging keys
// rows by exactly those fields with replace semantics, so same-key rows must
// be summed at the collection boundary or all but one source is dropped.

private struct MetricCoalesceKey: Hashable {
  let date: String
  let agent: String
  let model: String
  let machine: String
  let directory: String?
}

private struct SessionCoalesceKey: Hashable {
  let timestamp: Date
  let agent: String
  let model: String
  let machine: String
  let quality: UsageDataQuality
  let directory: String?
}

private struct PointCoalesceKey: Hashable {
  let timestamp: Date
  let machine: String
  let directory: String?
}

func coalescingSameKeyMetrics(_ rows: [CCUsageMetricRecord]) -> [CCUsageMetricRecord] {
  guard rows.count > 1 else { return rows }
  var order: [MetricCoalesceKey] = []
  var grouped: [MetricCoalesceKey: CCUsageMetricRecord] = [:]
  for row in rows {
    let key = MetricCoalesceKey(
      date: row.date,
      agent: row.agent,
      model: row.model,
      machine: row.machine,
      directory: row.directory
    )
    if let existing = grouped[key] {
      grouped[key] = CCUsageMetricRecord(
        date: row.date,
        agent: row.agent,
        model: row.model,
        costUSD: existing.costUSD + row.costUSD,
        inputTokens: existing.inputTokens + row.inputTokens,
        outputTokens: existing.outputTokens + row.outputTokens,
        cacheCreationTokens: existing.cacheCreationTokens + row.cacheCreationTokens,
        cacheReadTokens: existing.cacheReadTokens + row.cacheReadTokens,
        machine: row.machine,
        directory: row.directory
      )
    } else {
      order.append(key)
      grouped[key] = row
    }
  }
  guard order.count < rows.count else { return rows }
  return order.compactMap { grouped[$0] }
}

func coalescingSameKeySessions(_ rows: [CCUsageSessionMetricRecord]) -> [CCUsageSessionMetricRecord] {
  guard rows.count > 1 else { return rows }
  var order: [SessionCoalesceKey] = []
  var grouped: [SessionCoalesceKey: CCUsageSessionMetricRecord] = [:]
  for row in rows {
    let key = SessionCoalesceKey(
      timestamp: row.timestamp,
      agent: row.agent,
      model: row.model,
      machine: row.machine,
      quality: row.dataQuality,
      directory: row.directory
    )
    if let existing = grouped[key] {
      grouped[key] = CCUsageSessionMetricRecord(
        timestamp: row.timestamp,
        agent: row.agent,
        model: row.model,
        costUSD: existing.costUSD + row.costUSD,
        inputTokens: existing.inputTokens + row.inputTokens,
        outputTokens: existing.outputTokens + row.outputTokens,
        cacheCreationTokens: existing.cacheCreationTokens + row.cacheCreationTokens,
        cacheReadTokens: existing.cacheReadTokens + row.cacheReadTokens,
        dataQuality: row.dataQuality,
        machine: row.machine,
        directory: row.directory
      )
    } else {
      order.append(key)
      grouped[key] = row
    }
  }
  guard order.count < rows.count else { return rows }
  return order.compactMap { grouped[$0] }
}

func coalescingSameKeyPoints(_ rows: [CCUsageCostRecord]) -> [CCUsageCostRecord] {
  guard rows.count > 1 else { return rows }
  var order: [PointCoalesceKey] = []
  var grouped: [PointCoalesceKey: CCUsageCostRecord] = [:]
  for row in rows {
    let key = PointCoalesceKey(
      timestamp: row.timestamp,
      machine: row.machine,
      directory: row.directory
    )
    if let existing = grouped[key] {
      var models = existing.models
      for model in row.models where !models.contains(model) { models.append(model) }
      grouped[key] = CCUsageCostRecord(
        timestamp: row.timestamp,
        costUSD: existing.costUSD + row.costUSD,
        models: models,
        machine: row.machine,
        directory: row.directory
      )
    } else {
      order.append(key)
      grouped[key] = row
    }
  }
  guard order.count < rows.count else { return rows }
  return order.compactMap { grouped[$0] }
}
