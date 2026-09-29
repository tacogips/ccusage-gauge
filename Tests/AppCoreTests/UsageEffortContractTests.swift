import Foundation
import Testing
@testable import AppCore

@Suite("UsageEffortContractTests")
struct UsageEffortContractTests {
  @Test func normalizesSupportedEffortValues() {
    #expect(UsageEffort.normalized(" High ") == "high")
    #expect(UsageEffort.normalized("xhigh") == "xhigh")
    #expect(UsageEffort.normalized("X_HIGH-2") == "x_high-2")
    #expect(UsageEffort.normalized(String(repeating: "a", count: 32))?.count == 32)
    #expect(UsageEffort.normalized(nil) == nil)
    #expect(UsageEffort.normalized("") == nil)
    #expect(UsageEffort.normalized("   ") == nil)
    #expect(UsageEffort.normalized("a b") == nil)
    #expect(UsageEffort.normalized("high!") == nil)
    #expect(UsageEffort.normalized(String(repeating: "a", count: 33)) == nil)
  }

  @Test func eventNormalizesEffortWithoutChangingIdentity() {
    let high = event(effort: "high")
    let medium = event(effort: " Medium ")
    let unknown = event()

    #expect(high.effort == "high")
    #expect(medium.effort == "medium")
    #expect(unknown.effort == nil)
    #expect(high.identity == medium.identity)
    #expect(high.identity == unknown.identity)
  }

  @Test func sessionRecordDecodesLegacyJSONOmitsNilAndRoundTripsEffort() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = try decoder.decode(CCUsageSessionMetricRecord.self, from: Data(sessionJSON().utf8))
    #expect(legacy.effort == nil)
    #expect(try encodedObject(legacy)["effort"] == nil)

    let record = sessionRecord(effort: "high")
    let decoded = try decoder.decode(CCUsageSessionMetricRecord.self, from: encoder().encode(record))
    #expect(decoded.effort == "high")
  }

  @Test func metricRecordDecodesLegacyJSONOmitsNilAndRoundTripsEffort() throws {
    let decoder = JSONDecoder()
    let legacy = try decoder.decode(CCUsageMetricRecord.self, from: Data(metricJSON().utf8))
    #expect(legacy.effort == nil)
    #expect(try encodedObject(legacy)["effort"] == nil)

    let record = metricRecord(effort: "high")
    let decoded = try decoder.decode(CCUsageMetricRecord.self, from: encoder().encode(record))
    #expect(decoded.effort == "high")
  }

  @Test func metricRecordCopiesPreserveEffortWhenMachineIsRestamped() {
    let session = sessionRecord(effort: "high")
    let restampedSession = CCUsageSessionMetricRecord(
      timestamp: session.timestamp,
      agent: session.agent,
      model: session.model,
      costUSD: session.costUSD,
      inputTokens: session.inputTokens,
      outputTokens: session.outputTokens,
      cacheCreationTokens: session.cacheCreationTokens,
      cacheReadTokens: session.cacheReadTokens,
      dataQuality: session.dataQuality,
      machine: "remote",
      directory: session.directory,
      effort: session.effort
    )
    let metric = metricRecord(effort: "medium")
    let restampedMetric = CCUsageMetricRecord(
      date: metric.date,
      agent: metric.agent,
      model: metric.model,
      costUSD: metric.costUSD,
      inputTokens: metric.inputTokens,
      outputTokens: metric.outputTokens,
      cacheCreationTokens: metric.cacheCreationTokens,
      cacheReadTokens: metric.cacheReadTokens,
      machine: "remote",
      directory: metric.directory,
      effort: metric.effort
    )

    #expect(restampedSession.machine == "remote")
    #expect(restampedSession.effort == "high")
    #expect(restampedMetric.machine == "remote")
    #expect(restampedMetric.effort == "medium")
  }

  private func event(effort: String? = nil) -> TimestampedUsageEvent {
    TimestampedUsageEvent(
      timestamp: Date(timeIntervalSince1970: 0),
      agent: "codex",
      sessionID: "session",
      requestID: "request",
      messageID: "message",
      model: "gpt-test",
      inputTokens: 1,
      outputTokens: 2,
      cacheCreationTokens: 0,
      cacheReadTokens: 3,
      cacheCreationFiveMinuteTokens: 0,
      cacheCreationOneHourTokens: 0,
      effort: effort
    )
  }

  private func sessionRecord(effort: String?) -> CCUsageSessionMetricRecord {
    CCUsageSessionMetricRecord(
      timestamp: Date(timeIntervalSince1970: 1_721_095_200),
      agent: "codex",
      model: "gpt-test",
      costUSD: 1,
      inputTokens: 1,
      outputTokens: 2,
      cacheCreationTokens: 0,
      cacheReadTokens: 3,
      dataQuality: .timestamped,
      effort: effort
    )
  }

  private func metricRecord(effort: String?) -> CCUsageMetricRecord {
    CCUsageMetricRecord(
      date: "2026-07-16",
      agent: "codex",
      model: "gpt-test",
      costUSD: 1,
      inputTokens: 1,
      outputTokens: 2,
      cacheCreationTokens: 0,
      cacheReadTokens: 3,
      effort: effort
    )
  }

  private func sessionJSON() -> String {
    #"{"timestamp":"2024-07-16T00:00:00Z","agent":"codex","model":"gpt-test","costUSD":1,"inputTokens":1,"outputTokens":2,"cacheCreationTokens":0,"cacheReadTokens":3,"dataQuality":"timestamped","machine":"local"}"#
  }

  private func metricJSON() -> String {
    #"{"date":"2026-07-16","agent":"codex","model":"gpt-test","costUSD":1,"inputTokens":1,"outputTokens":2,"cacheCreationTokens":0,"cacheReadTokens":3,"machine":"local"}"#
  }

  private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: encoder().encode(value)) as? [String: Any])
  }
}
