import Foundation

public enum RateLimitProvider: String, Codable, Sendable { case claude, codex }
public enum RateLimitStatus: String, Codable, Sendable { case ok, stale, unauthorized, unavailable }
public enum RateLimitErrorCode: String, Codable, Sendable, Error {
  case credentialsMissing = "credentials_missing", credentialsUnreadable = "credentials_unreadable"
  case tokenExpired = "token_expired", unauthorized, rateLimited = "rate_limited"
  case httpError = "http_error", networkError = "network_error", timeout, invalidResponse = "invalid_response"

  public var message: String {
    switch self {
    case .credentialsMissing: "CLI credentials were not found"
    case .credentialsUnreadable: "CLI credentials could not be read"
    case .tokenExpired, .unauthorized: "Sign in again with the CLI to refresh credentials"
    case .rateLimited: "Usage API is throttling requests; retrying later"
    case .httpError: "Rate limit request failed"
    case .networkError: "Rate limit network request failed"
    case .timeout: "Rate limit request timed out"
    case .invalidResponse: "Rate limit response was invalid"
    }
  }
}
public enum RateLimitWindowKind: String, Codable, Sendable {
  case fiveHour, weekly, other
  public static func classify(windowSeconds: Int) -> Self {
    switch windowSeconds {
    case 18000: .fiveHour
    case 604800: .weekly
    default: .other
    }
  }
}
public struct RateLimitWindow: Codable, Equatable, Sendable {
  public let kind: RateLimitWindowKind
  public let windowSeconds: Int
  public let usedPercent: Double
  public let remainingPercent: Double
  public let resetsAt: Date?
  public init(windowSeconds: Int, usedPercent: Double, resetsAt: Date?) throws {
    guard windowSeconds > 0, usedPercent.isFinite, usedPercent >= 0 else { throw RateLimitErrorCode.invalidResponse }
    self.kind = .classify(windowSeconds: windowSeconds)
    self.windowSeconds = windowSeconds
    self.usedPercent = usedPercent
    self.remainingPercent = min(max(100 - usedPercent, 0), 100)
    self.resetsAt = resetsAt
  }
  public var pieFraction: Double { min(usedPercent, 100) / 100 }
  private enum CodingKeys: String, CodingKey { case kind, windowSeconds, usedPercent, remainingPercent, resetsAt }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(windowSeconds, forKey: .windowSeconds)
    try container.encode(usedPercent, forKey: .usedPercent)
    try container.encode(remainingPercent, forKey: .remainingPercent)
    try container.encode(resetsAt, forKey: .resetsAt)
  }
}
public enum RateLimitCreditUnit: String, Codable, Sendable { case usd, credits }
/// Extended usage beyond the subscription windows: Claude extra usage (USD) or Codex credits.
public struct RateLimitCredits: Codable, Equatable, Sendable {
  public let unit: RateLimitCreditUnit
  public let enabled: Bool
  public let unlimited: Bool
  public let used: Double?
  public let limit: Double?
  public let balance: Double?
  public let usedPercent: Double?
  public init(unit: RateLimitCreditUnit, enabled: Bool, unlimited: Bool = false, used: Double? = nil, limit: Double? = nil,
              balance: Double? = nil, usedPercent: Double? = nil) {
    func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
    self.unit = unit; self.enabled = enabled; self.unlimited = unlimited
    self.used = finite(used); self.limit = finite(limit); self.balance = finite(balance)
    if let percent = finite(usedPercent) {
      self.usedPercent = max(percent, 0)
    } else if let used = finite(used), let limit = finite(limit), limit > 0 {
      self.usedPercent = max(used / limit * 100, 0)
    } else {
      self.usedPercent = nil
    }
  }
  public var pieFraction: Double? { usedPercent.map { min($0, 100) / 100 } }
  private enum CodingKeys: String, CodingKey { case unit, enabled, unlimited, used, limit, balance, usedPercent }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(unit, forKey: .unit); try container.encode(enabled, forKey: .enabled)
    try container.encode(unlimited, forKey: .unlimited); try container.encode(used, forKey: .used)
    try container.encode(limit, forKey: .limit); try container.encode(balance, forKey: .balance)
    try container.encode(usedPercent, forKey: .usedPercent)
  }
}
public struct RateLimitObservation: Codable, Equatable, Sendable {
  public let planType: String?
  public let observedAt: Date
  public let windows: [RateLimitWindow]
  public let credits: RateLimitCredits?
  public init(planType: String?, observedAt: Date, windows: [RateLimitWindow], credits: RateLimitCredits? = nil) {
    self.planType = planType; self.observedAt = observedAt; self.windows = windows; self.credits = credits
  }
}
public struct RateLimitWindowSlots: Equatable, Sendable {
  public let fiveHour: RateLimitWindow?
  public let weekly: RateLimitWindow?
  public let other: [RateLimitWindow]
}
public struct ProviderRateLimits: Codable, Equatable, Sendable {
  public let provider: RateLimitProvider
  public let status: RateLimitStatus
  public let errorCode: RateLimitErrorCode?
  public let message: String?
  public let planType: String?
  public let fetchedAt: Date?
  public let stale: Bool
  public let fiveHour: RateLimitWindow?
  public let weekly: RateLimitWindow?
  public let otherWindows: [RateLimitWindow]
  public let credits: RateLimitCredits?
  public init(provider: RateLimitProvider, status: RateLimitStatus, errorCode: RateLimitErrorCode?, message: String?,
              planType: String?, fetchedAt: Date?, stale: Bool, fiveHour: RateLimitWindow?, weekly: RateLimitWindow?,
              otherWindows: [RateLimitWindow], credits: RateLimitCredits? = nil) {
    self.provider = provider; self.status = status; self.errorCode = errorCode; self.message = message
    self.planType = planType; self.fetchedAt = fetchedAt; self.stale = stale
    self.fiveHour = fiveHour; self.weekly = weekly; self.otherWindows = otherWindows; self.credits = credits
  }
  public static func slots(_ windows: [RateLimitWindow]) -> RateLimitWindowSlots {
    var fiveHour: RateLimitWindow?; var weekly: RateLimitWindow?; var other: [RateLimitWindow] = []
    for window in windows {
      switch window.kind {
      case .fiveHour where fiveHour == nil: fiveHour = window
      case .weekly where weekly == nil: weekly = window
      default: other.append(window)
      }
    }
    return RateLimitWindowSlots(fiveHour: fiveHour, weekly: weekly, other: other)
  }
  private enum CodingKeys: String, CodingKey { case provider, status, errorCode, message, planType, fetchedAt, stale, fiveHour, weekly, otherWindows, credits }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(provider, forKey: .provider); try container.encode(status, forKey: .status)
    try container.encode(errorCode, forKey: .errorCode); try container.encode(message, forKey: .message)
    try container.encode(planType, forKey: .planType); try container.encode(fetchedAt, forKey: .fetchedAt)
    try container.encode(stale, forKey: .stale); try container.encode(fiveHour, forKey: .fiveHour)
    try container.encode(weekly, forKey: .weekly); try container.encode(otherWindows, forKey: .otherWindows)
    try container.encode(credits, forKey: .credits)
  }
}
public struct RateLimitsResponse: Codable, Equatable, Sendable {
  public let generatedAt: Date
  public let scope: String
  public let providers: [ProviderRateLimits]
  public init(generatedAt: Date, providers: [ProviderRateLimits]) {
    self.generatedAt = generatedAt; self.scope = "local"; self.providers = providers
  }
}
