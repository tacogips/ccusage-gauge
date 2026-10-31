import Foundation

public enum RateLimitDisplayFormatting {
  public static func entry(for chart: PieChartID, in response: RateLimitsResponse?) -> (provider: ProviderRateLimits?, window: RateLimitWindow?) {
    guard let providerID = chart.provider else { return (nil, nil) }
    let provider = response?.providers.first { $0.provider == providerID }
    switch chart {
    case .claude5h, .codex5h: return (provider, provider?.fiveHour)
    case .claudeWeekly, .codexWeekly: return (provider, provider?.weekly)
    case .budget, .claudeCredit, .codexCredit: return (provider, nil)
    }
  }

  public static func credits(for chart: PieChartID, in response: RateLimitsResponse?) -> RateLimitCredits? {
    guard chart.isCredit else { return nil }
    return entry(for: chart, in: response).provider?.credits
  }

  public static func title(for chart: PieChartID) -> String {
    switch chart {
    case .budget: "Budget"
    case .claude5h: "Claude Code 5h"
    case .claudeWeekly: "Claude Code weekly"
    case .claudeCredit: "Claude Code credit"
    case .codex5h: "Codex 5h"
    case .codexWeekly: "Codex weekly"
    case .codexCredit: "Codex credit"
    }
  }

  public static func fraction(for chart: PieChartID, in response: RateLimitsResponse?) -> Double? {
    chart.isCredit ? credits(for: chart, in: response)?.pieFraction : entry(for: chart, in: response).window?.pieFraction
  }

  public static func ratioLabel(for chart: PieChartID, in response: RateLimitsResponse?) -> String {
    guard chart != .budget else { return "" }
    guard let fraction = fraction(for: chart, in: response) else { return "--" }
    return "\(Int((fraction * 100).rounded()))%"
  }

  public static func statusTitle(selection: [PieChartID], budgetText: String, response: RateLimitsResponse?) -> String {
    RatioTextSelection.normalized(selection).map { chart in
      chart == .budget ? budgetText : ratioLabel(for: chart, in: response)
    }.joined(separator: " · ")
  }

  public static func resetText(resetsAt: Date?, now: Date) -> String {
    guard let resetsAt else { return "reset time unknown" }
    let seconds = resetsAt.timeIntervalSince(now)
    guard seconds > 0 else { return "reset due" }
    guard seconds >= 60 else { return "resets in <1m" }
    let minutes = Int(seconds / 60)
    if minutes >= 1440 { return "resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
    return "resets in \(minutes / 60)h \(minutes % 60)m"
  }

  /// Short description of extended usage, e.g. "$12.34 / $50 used (25%)" or "62,500 credits left".
  public static func creditSummary(_ credits: RateLimitCredits) -> String {
    if credits.unlimited { return "unlimited" }
    guard credits.enabled else { return credits.unit == .usd ? "not enabled" : "no credits" }
    let percent = credits.usedPercent.map { "\(Int($0.rounded()))%" }
    switch credits.unit {
    case .usd:
      switch (credits.used, credits.limit) {
      case let (used?, limit?): return "\(usd(used)) / \(usd(limit)) used" + (percent.map { " (\($0))" } ?? "")
      case let (used?, nil): return "\(usd(used)) used"
      default: return percent.map { "\($0) used" } ?? "enabled"
      }
    case .credits:
      return credits.balance.map { "\(number($0)) credits left" } ?? "available"
    }
  }

  public static func menuLine(for chart: PieChartID, response: RateLimitsResponse?, now: Date) -> String {
    let (provider, window) = entry(for: chart, in: response)
    let name = title(for: chart)
    let stale = provider?.status == .stale ? " (stale)" : ""
    if let credits = credits(for: chart, in: response) { return "\(name): \(creditSummary(credits))\(stale)" }
    if let window {
      return "\(name): \(Int(window.remainingPercent.rounded()))% left, \(resetText(resetsAt: window.resetsAt, now: now))\(stale)"
    }
    guard let provider else { return "\(name): loading" }
    if provider.status == .unauthorized { return "\(name): unauthorized - sign in again with the CLI" }
    if chart.isCredit && provider.status == .ok { return "\(name): unavailable" }
    return "\(name): \(provider.message ?? "unavailable")"
  }

  /// Tooltip lines for every provider whose extended usage is active.
  public static func creditLines(response: RateLimitsResponse?, now: Date) -> [String] {
    [PieChartID.claudeCredit, .codexCredit].compactMap { chart in
      guard let credits = credits(for: chart, in: response), credits.enabled || credits.unlimited else { return nil }
      return menuLine(for: chart, response: response, now: now)
    }
  }

  public static func pieFraction(_ window: RateLimitWindow?) -> Double? { window?.pieFraction }

  private static func usd(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.minimumFractionDigits = value.rounded() == value ? 0 : 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
  }

  private static func number(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }
}
