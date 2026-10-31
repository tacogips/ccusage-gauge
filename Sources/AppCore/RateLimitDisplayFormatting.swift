import Foundation

public enum RateLimitDisplayFormatting {
  public static func entry(for chart: PieChartID, in response: RateLimitsResponse?) -> (provider: ProviderRateLimits?, window: RateLimitWindow?) {
    let providerID: RateLimitProvider
    switch chart {
    case .budget: return (nil, nil)
    case .claude5h, .claudeWeekly: providerID = .claude
    case .codex5h, .codexWeekly: providerID = .codex
    }
    let provider = response?.providers.first { $0.provider == providerID }
    switch chart {
    case .claude5h, .codex5h: return (provider, provider?.fiveHour)
    case .claudeWeekly, .codexWeekly: return (provider, provider?.weekly)
    case .budget: return (nil, nil)
    }
  }

  public static func title(for chart: PieChartID) -> String {
    switch chart {
    case .budget: "Budget"
    case .claude5h: "Claude Code 5h"
    case .claudeWeekly: "Claude Code weekly"
    case .codex5h: "Codex 5h"
    case .codexWeekly: "Codex weekly"
    }
  }

  public static func ratioLabel(for chart: PieChartID, in response: RateLimitsResponse?) -> String {
    guard chart != .budget else { return "" }
    guard let window = entry(for: chart, in: response).window else { return "--" }
    return "\(Int((window.pieFraction * 100).rounded()))%"
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

  public static func menuLine(for chart: PieChartID, response: RateLimitsResponse?, now: Date) -> String {
    let (provider, window) = entry(for: chart, in: response)
    let name = title(for: chart)
    if let window {
      let stale = provider?.status == .stale ? " (stale)" : ""
      return "\(name): \(Int(window.remainingPercent.rounded()))% left, \(resetText(resetsAt: window.resetsAt, now: now))\(stale)"
    }
    guard let provider else { return "\(name): loading" }
    if provider.status == .unauthorized { return "\(name): unauthorized - sign in again with the CLI" }
    return "\(name): \(provider.message ?? "unavailable")"
  }

  public static func pieFraction(_ window: RateLimitWindow?) -> Double? { window?.pieFraction }
}
