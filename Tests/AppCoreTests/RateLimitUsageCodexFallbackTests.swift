import Foundation
import Testing
@testable import AppCore

@Suite struct RateLimitUsageCodexFallbackTests {
  private func event(_ timestamp: String, _ limits: String) -> String {
    "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":\(limits)}}"
  }
  @Test func scanningAndLimits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("a-old.jsonl"), new = root.appendingPathComponent("b-new.jsonl")
    let limits = #"{"primary":{"used_percent":77,"window_minutes":10080,"resets_in_seconds":60},"secondary":null,"plan_type":"pro"}"#
    let t1 = "2026-01-01T00:00:00Z", t2 = "2026-01-02T00:00:00.000Z"
    try event(t1, limits).write(to: old, atomically: true, encoding: .utf8)
    try (event(t1, limits) + "\n" + event(t2, limits) + "\n" + event(t2, "null") + "\n" + #"{"type":"token_count","broken":}"#).write(to: new, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: old.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: new.path)
    let fallback = CodexRateLimitSessionFallback(sessionsRoot: root)
    let result = try #require(await fallback.latestObservation())
    #expect(result.observedAt == ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z"))
    #expect(result.planType == "pro" && result.windows.first?.kind == .weekly)
    #expect(result.windows.first?.resetsAt == result.observedAt.addingTimeInterval(60))
    try event(t2, "null").write(to: new, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: new.path)
    #expect(await fallback.latestObservation()?.observedAt == ISO8601DateFormatter().date(from: t1))
    #expect(await CodexRateLimitSessionFallback(sessionsRoot: root, maxFiles: 1).latestObservation() == nil)
    #expect(await CodexRateLimitSessionFallback(sessionsRoot: root.appendingPathComponent("missing")).latestObservation() == nil)
  }
}
