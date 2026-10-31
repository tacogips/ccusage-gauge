import Foundation
import Testing
@testable import AppCore

struct RateLimitDisplayFormattingTests {
  let now = Date(timeIntervalSince1970: 1_000_000)

  @Test func resetTimes() {
    #expect(RateLimitDisplayFormatting.resetText(resetsAt: now.addingTimeInterval(7980), now: now) == "resets in 2h 13m")
    #expect(RateLimitDisplayFormatting.resetText(resetsAt: now.addingTimeInterval(273600), now: now) == "resets in 3d 4h")
    #expect(RateLimitDisplayFormatting.resetText(resetsAt: now.addingTimeInterval(30), now: now) == "resets in <1m")
    #expect(RateLimitDisplayFormatting.resetText(resetsAt: now.addingTimeInterval(-1), now: now) == "reset due")
    #expect(RateLimitDisplayFormatting.resetText(resetsAt: nil, now: now) == "reset time unknown")
  }

  @Test func entriesAndLines() throws {
    let five = try RateLimitWindow(windowSeconds: 18000, usedPercent: 47, resetsAt: now.addingTimeInterval(7980))
    let weekly = try RateLimitWindow(windowSeconds: 604800, usedPercent: 120, resetsAt: nil)
    let claude = provider(.claude, status: .ok, five: five, weekly: nil)
    let codex = provider(.codex, status: .ok, five: nil, weekly: weekly)
    let response = RateLimitsResponse(generatedAt: now, providers: [claude, codex])
    #expect(RateLimitDisplayFormatting.entry(for: .codexWeekly, in: response).window == weekly)
    #expect(RateLimitDisplayFormatting.entry(for: .codex5h, in: response).window == nil)
    #expect(RateLimitDisplayFormatting.entry(for: .budget, in: response).provider == nil)
    #expect(RateLimitDisplayFormatting.menuLine(for: .claude5h, response: response, now: now) == "Claude Code 5h: 53% left, resets in 2h 13m")
    #expect(RateLimitDisplayFormatting.pieFraction(weekly) == 1)
    #expect(RateLimitDisplayFormatting.pieFraction(nil) == nil)
    let stale = RateLimitsResponse(generatedAt: now, providers: [provider(.claude, status: .stale, five: five, weekly: nil)])
    #expect(RateLimitDisplayFormatting.menuLine(for: .claude5h, response: stale, now: now).hasSuffix(" (stale)"))
    let unauthorized = RateLimitsResponse(generatedAt: now, providers: [provider(.claude, status: .unauthorized, five: nil, weekly: nil)])
    #expect(RateLimitDisplayFormatting.menuLine(for: .claude5h, response: unauthorized, now: now) == "Claude Code 5h: unauthorized - sign in again with the CLI")
    #expect(RateLimitDisplayFormatting.menuLine(for: .claude5h, response: nil, now: now) == "Claude Code 5h: loading")
    let unavailable = RateLimitsResponse(generatedAt: now, providers: [provider(.claude, status: .unavailable, five: nil, weekly: nil)])
    #expect(RateLimitDisplayFormatting.menuLine(for: .claude5h, response: unavailable, now: now) == "Claude Code 5h: unavailable message")
    #expect(PieChartID.allCases.map { RateLimitDisplayFormatting.title(for: $0) } == ["Budget", "Claude Code 5h", "Claude Code weekly", "Codex 5h", "Codex weekly"])
  }

  private func provider(_ id: RateLimitProvider, status: RateLimitStatus, five: RateLimitWindow?, weekly: RateLimitWindow?) -> ProviderRateLimits {
    ProviderRateLimits(provider: id, status: status, errorCode: nil, message: "unavailable message", planType: nil,
                       fetchedAt: now, stale: status == .stale, fiveHour: five, weekly: weekly, otherWindows: [])
  }
}
