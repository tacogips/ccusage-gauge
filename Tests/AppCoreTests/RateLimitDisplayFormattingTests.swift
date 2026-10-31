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
    #expect(PieChartID.allCases.map { RateLimitDisplayFormatting.title(for: $0) } == [
      "Budget", "Claude Code 5h", "Claude Code weekly", "Claude Code credit", "Codex 5h", "Codex weekly", "Codex credit"
    ])
    #expect(PieChartID.menuBarCases == [.budget, .claude5h, .claudeWeekly, .codex5h, .codexWeekly])
  }

  @Test func credits() {
    let claudeCredits = RateLimitCredits(unit: .usd, enabled: true, used: 12.34, limit: 50, usedPercent: 24.68)
    let codexCredits = RateLimitCredits(unit: .credits, enabled: true, balance: 62500)
    let response = RateLimitsResponse(generatedAt: now, providers: [
      provider(.claude, status: .ok, five: nil, weekly: nil, credits: claudeCredits),
      provider(.codex, status: .stale, five: nil, weekly: nil, credits: codexCredits)
    ])
    #expect(RateLimitDisplayFormatting.credits(for: .claudeCredit, in: response) == claudeCredits)
    #expect(RateLimitDisplayFormatting.credits(for: .claude5h, in: response) == nil)
    #expect(RateLimitDisplayFormatting.entry(for: .codexCredit, in: response).window == nil)
    #expect(RateLimitDisplayFormatting.ratioLabel(for: .claudeCredit, in: response) == "25%")
    #expect(RateLimitDisplayFormatting.ratioLabel(for: .codexCredit, in: response) == "--")
    #expect(RateLimitDisplayFormatting.creditLines(response: response, now: now) == [
      "Claude Code credit: $12.34 / $50 used (25%)", "Codex credit: 62,500 credits left (stale)"
    ])
    let summaries: [(RateLimitCredits, String)] = [
      (RateLimitCredits(unit: .usd, enabled: false), "not enabled"),
      (RateLimitCredits(unit: .credits, enabled: false), "no credits"),
      (RateLimitCredits(unit: .credits, enabled: true, unlimited: true), "unlimited"),
      (RateLimitCredits(unit: .credits, enabled: true), "available"),
      (RateLimitCredits(unit: .usd, enabled: true, used: 3), "$3 used"),
      (RateLimitCredits(unit: .usd, enabled: true, usedPercent: 10.4), "10% used"),
      (RateLimitCredits(unit: .usd, enabled: true, used: 5, limit: 20), "$5 / $20 used (25%)"),
      (RateLimitCredits(unit: .usd, enabled: true), "enabled")
    ]
    for (credits, text) in summaries { #expect(RateLimitDisplayFormatting.creditSummary(credits) == text) }
    #expect(RateLimitCredits(unit: .usd, enabled: true, used: 150, limit: 100).pieFraction == 1)
    #expect(RateLimitCredits(unit: .usd, enabled: true, used: .nan, limit: 100).pieFraction == nil)
    let disabled = RateLimitsResponse(generatedAt: now, providers: [
      provider(.claude, status: .ok, five: nil, weekly: nil, credits: RateLimitCredits(unit: .usd, enabled: false)),
      provider(.codex, status: .ok, five: nil, weekly: nil)
    ])
    #expect(RateLimitDisplayFormatting.creditLines(response: disabled, now: now).isEmpty)
    #expect(RateLimitDisplayFormatting.menuLine(for: .codexCredit, response: disabled, now: now) == "Codex credit: unavailable")
    #expect(RateLimitDisplayFormatting.creditLines(response: nil, now: now).isEmpty)
  }

  private func provider(_ id: RateLimitProvider, status: RateLimitStatus, five: RateLimitWindow?, weekly: RateLimitWindow?,
                        credits: RateLimitCredits? = nil) -> ProviderRateLimits {
    ProviderRateLimits(provider: id, status: status, errorCode: nil, message: "unavailable message", planType: nil,
                       fetchedAt: now, stale: status == .stale, fiveHour: five, weekly: weekly, otherWindows: [], credits: credits)
  }
}
