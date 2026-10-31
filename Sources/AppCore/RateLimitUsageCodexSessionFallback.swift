import Foundation

public struct CodexRateLimitSessionFallback: CodexRateLimitFallbackReading {
  private let sessionsRoot: URL
  private let maxFiles: Int
  public init(sessionsRoot: URL, maxFiles: Int = 10) { self.sessionsRoot = sessionsRoot; self.maxFiles = maxFiles }
  public func latestObservation() async -> RateLimitObservation? {
    await Task.detached(priority: .utility) { scan() }.value
  }
  private func scan() -> RateLimitObservation? {
    let files = UsageEventLogReader.jsonlFiles(roots: [sessionsRoot], modifiedSince: nil).sorted {
      ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast)
    }
    for file in files.prefix(max(0, maxFiles)) {
      var result: RateLimitObservation?
      do {
        try UsageEventLogReader.forEachLineFromEnd(in: file.url, matchingAny: [Data(#""type":"token_count""#.utf8)]) { line in
          guard let event = try? JSONDecoder().decode(Event.self, from: line), event.type == "event_msg",
                event.payload.type == "token_count", let limits = event.payload.rateLimits,
                let timestamp = Self.parseDate(event.timestamp) else { return true }
          result = RateLimitObservation(planType: limits.planType, observedAt: timestamp,
                                        windows: [limits.primary, limits.secondary].compactMap { $0?.window(now: timestamp) },
                                        credits: limits.credits?.credits)
          return false
        }
      } catch { continue }
      if let result { return result }
    }
    return nil
  }
  private static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let result = formatter.date(from: value) { return result }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
private struct Event: Decodable {
  let timestamp: String
  let type: String
  let payload: EventPayload
}
private struct EventPayload: Decodable {
  let type: String
  let rateLimits: EventLimits?
  enum CodingKeys: String, CodingKey { case type, rateLimits = "rate_limits" }
}
private struct EventLimits: Decodable {
  let primary: EventWindow?
  let secondary: EventWindow?
  let planType: String?
  let credits: CodexCreditsPayload?
  enum CodingKeys: String, CodingKey { case primary, secondary, planType = "plan_type", credits }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    primary = try container.decodeIfPresent(EventWindow.self, forKey: .primary)
    secondary = try container.decodeIfPresent(EventWindow.self, forKey: .secondary)
    planType = try container.decodeIfPresent(String.self, forKey: .planType)
    credits = try? container.decodeIfPresent(CodexCreditsPayload.self, forKey: .credits)
  }
}
private struct EventWindow: Decodable {
  let used: Double?
  let minutes: Int?
  let resetAt: Double?
  let resetAfter: Double?
  enum CodingKeys: String, CodingKey {
    case used = "used_percent", minutes = "window_minutes", resetAt = "resets_at", resetAfter = "resets_in_seconds"
  }
  func window(now: Date) -> RateLimitWindow? {
    guard let used, let minutes else { return nil }
    let (seconds, overflow) = minutes.multipliedReportingOverflow(by: 60)
    guard !overflow else { return nil }
    let reset = resetAt.map { Date(timeIntervalSince1970: $0) } ?? resetAfter.map { now.addingTimeInterval($0) }
    return try? RateLimitWindow(windowSeconds: seconds, usedPercent: used, resetsAt: reset)
  }
}
