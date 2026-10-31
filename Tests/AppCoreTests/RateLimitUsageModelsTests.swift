import Foundation
import Testing
@testable import AppCore

@Suite struct RateLimitUsageModelsTests {
  @Test func windowMathAndClassification() throws {
    let window = try RateLimitWindow(windowSeconds: 18000, usedPercent: 47, resetsAt: nil)
    #expect(window.remainingPercent == 53 && window.pieFraction == 0.47 && window.kind == .fiveHour)
    let over = try RateLimitWindow(windowSeconds: 604800, usedPercent: 120, resetsAt: nil)
    #expect(over.remainingPercent == 0 && over.pieFraction == 1 && over.kind == .weekly)
    #expect(try RateLimitWindow(windowSeconds: 3600, usedPercent: 0, resetsAt: nil).kind == .other)
    #expect(throws: RateLimitErrorCode.invalidResponse) { try RateLimitWindow(windowSeconds: 18000, usedPercent: -1, resetsAt: nil) }
    #expect(throws: RateLimitErrorCode.invalidResponse) { try RateLimitWindow(windowSeconds: 18000, usedPercent: .nan, resetsAt: nil) }
  }
  @Test func slotsAndExplicitNulls() throws {
    let a = try RateLimitWindow(windowSeconds: 604800, usedPercent: 1, resetsAt: nil)
    let b = try RateLimitWindow(windowSeconds: 18000, usedPercent: 2, resetsAt: nil)
    let c = try RateLimitWindow(windowSeconds: 604800, usedPercent: 3, resetsAt: nil)
    let slots = ProviderRateLimits.slots([a, b, c])
    #expect(slots.weekly == a && slots.fiveHour == b && slots.other == [c])
    let provider = ProviderRateLimits(provider: .claude, status: .ok, errorCode: nil, message: nil, planType: nil,
                                      fetchedAt: nil, stale: false, fiveHour: b, weekly: nil, otherWindows: [])
    let data = try JSONEncoder().encode(RateLimitsResponse(generatedAt: Date(), providers: [provider]))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == Set(["generatedAt", "scope", "providers"]))
    let item = try #require((json["providers"] as? [[String: Any]])?.first)
    #expect(item["errorCode"] is NSNull)
    #expect((item["fiveHour"] as? [String: Any])?["resetsAt"] is NSNull)
    #expect(item["credits"] is NSNull)
  }
  @Test func creditsRoundTrip() throws {
    let credits = RateLimitCredits(unit: .usd, enabled: true, used: 1.5, limit: 10)
    #expect(credits.usedPercent == 15 && credits.pieFraction == 0.15)
    let provider = ProviderRateLimits(provider: .claude, status: .ok, errorCode: nil, message: nil, planType: nil,
                                      fetchedAt: nil, stale: false, fiveHour: nil, weekly: nil, otherWindows: [], credits: credits)
    let data = try JSONEncoder().encode(provider)
    #expect(try JSONDecoder().decode(ProviderRateLimits.self, from: data) == provider)
    let item = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let encoded = try #require(item["credits"] as? [String: Any])
    #expect(encoded["unit"] as? String == "usd" && encoded["balance"] is NSNull)
  }
  @Test func redaction() {
    let secret = RedactedSecret(testClaudeToken)
    #expect(String(describing: secret) == "<redacted>")
    var output = ""; dump(secret, to: &output)
    #expect(!output.contains(testClaudeToken))
  }
}
