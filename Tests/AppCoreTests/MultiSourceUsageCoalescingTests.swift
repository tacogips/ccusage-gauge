import Foundation
import Testing
@testable import AppCore

@Suite("MultiSourceUsageCoalescingTests")
struct MultiSourceUsageCoalescingTests {
  @Test func sameKeyMetricsAreSummedNotReplaced() {
    let rows = [
      CCUsageMetricRecord(
        date: "2026-07-28", agent: "codex", model: "gpt-5.6-sol",
        costUSD: Decimal(string: "1.25")!, inputTokens: 125, outputTokens: 10,
        cacheCreationTokens: 5, cacheReadTokens: 50
      ),
      CCUsageMetricRecord(
        date: "2026-07-28", agent: "codex", model: "gpt-5.6-sol",
        costUSD: Decimal(string: "2.5")!, inputTokens: 250, outputTokens: 20,
        cacheCreationTokens: 10, cacheReadTokens: 100
      ),
      CCUsageMetricRecord(
        date: "2026-07-28", agent: "claude", model: "claude-opus-4-8",
        costUSD: 5, inputTokens: 500, outputTokens: 0,
        cacheCreationTokens: 0, cacheReadTokens: 0
      )
    ]
    let coalesced = coalescingSameKeyMetrics(rows)
    #expect(coalesced.count == 2)
    let codex = coalesced.first { $0.agent == "codex" }
    #expect(codex?.costUSD == Decimal(string: "3.75"))
    #expect(codex?.inputTokens == 375)
    #expect(codex?.outputTokens == 30)
    #expect(codex?.cacheCreationTokens == 15)
    #expect(codex?.cacheReadTokens == 150)
    #expect(coalesced.first { $0.agent == "claude" }?.costUSD == 5)
  }

  @Test func distinctMetricKeysAreUntouched() {
    let rows = [
      CCUsageMetricRecord(
        date: "2026-07-27", agent: "codex", model: "gpt-5.6-sol",
        costUSD: 1, inputTokens: 1, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0
      ),
      CCUsageMetricRecord(
        date: "2026-07-28", agent: "codex", model: "gpt-5.6-sol",
        costUSD: 2, inputTokens: 2, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0
      ),
      CCUsageMetricRecord(
        date: "2026-07-28", agent: "codex", model: "gpt-5.6-sol",
        costUSD: 3, inputTokens: 3, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0,
        machine: "remote-a"
      )
    ]
    #expect(coalescingSameKeyMetrics(rows) == rows)
  }

  @Test func sameKeySessionsAreSummed() {
    let timestamp = Date(timeIntervalSince1970: 1_785_000_000)
    let rows = [
      CCUsageSessionMetricRecord(
        timestamp: timestamp, agent: "codex", model: "gpt-5.6-sol",
        costUSD: Decimal(string: "1.25")!, inputTokens: 125
      ),
      CCUsageSessionMetricRecord(
        timestamp: timestamp, agent: "codex", model: "gpt-5.6-sol",
        costUSD: Decimal(string: "2.5")!, inputTokens: 250
      ),
      CCUsageSessionMetricRecord(
        timestamp: timestamp.addingTimeInterval(60), agent: "codex", model: "gpt-5.6-sol",
        costUSD: 4, inputTokens: 400
      )
    ]
    let coalesced = coalescingSameKeySessions(rows)
    #expect(coalesced.count == 2)
    let merged = coalesced.first { $0.timestamp == timestamp }
    #expect(merged?.costUSD == Decimal(string: "3.75"))
    #expect(merged?.inputTokens == 375)
    #expect(coalesced.first { $0.timestamp != timestamp }?.costUSD == 4)
  }

  @Test func sameTimestampPointsSumCostAndUnionModels() {
    let timestamp = Date(timeIntervalSince1970: 1_785_000_000)
    let rows = [
      CCUsageCostRecord(timestamp: timestamp, costUSD: Decimal(string: "1.25")!, models: ["gpt-5.6-sol"]),
      CCUsageCostRecord(timestamp: timestamp, costUSD: Decimal(string: "2.5")!, models: ["gpt-5.6-sol"]),
      CCUsageCostRecord(timestamp: timestamp, costUSD: 5, models: ["claude-opus-4-8"]),
      CCUsageCostRecord(timestamp: timestamp, costUSD: 7, models: ["gpt-5.6-sol"], machine: "remote-a")
    ]
    let coalesced = coalescingSameKeyPoints(rows)
    #expect(coalesced.count == 2)
    let local = coalesced.first { $0.machine == "local" }
    #expect(local?.costUSD == Decimal(string: "8.75"))
    #expect(local?.models == ["gpt-5.6-sol", "claude-opus-4-8"])
    #expect(coalesced.first { $0.machine == "remote-a" }?.costUSD == 7)
  }
}
