import Foundation

public struct ClaudeRateLimitFetcher: RateLimitLiveFetching {
  private let credentials: any ClaudeCredentialProviding
  private let transport: any RateLimitHTTPTransport
  private let timeoutSeconds: TimeInterval

  public init(credentials: any ClaudeCredentialProviding, transport: any RateLimitHTTPTransport, timeoutSeconds: TimeInterval = 15) {
    self.credentials = credentials
    self.transport = transport
    self.timeoutSeconds = timeoutSeconds
  }

  public func fetchLive(now: Date) async throws -> RateLimitObservation {
    let credential = try await credentials.claudeCredential()
    if let expiry = credential.expiresAt, expiry <= now { throw RateLimitErrorCode.tokenExpired }
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { throw RateLimitErrorCode.invalidResponse }
    let response = try await transport.get(url: url, headers: [
      "Authorization": "Bearer \(credential.accessToken.rawValue)",
      "anthropic-beta": "oauth-2025-04-20",
      "Content-Type": "application/json"
    ], timeoutSeconds: timeoutSeconds)
    switch response.status {
    case 200: break
    case 401, 403: throw RateLimitErrorCode.unauthorized
    case 429: throw RateLimitErrorCode.rateLimited
    default: throw RateLimitErrorCode.httpError
    }
    do {
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let payload = try decoder.decode(Payload.self, from: response.body)
      var windows: [RateLimitWindow] = []
      if let window = try Self.window(payload.fiveHour, seconds: 18000) { windows.append(window) }
      if let window = try Self.window(payload.sevenDay, seconds: 604800) { windows.append(window) }
      return RateLimitObservation(planType: credential.subscriptionType, observedAt: now, windows: windows)
    } catch { throw RateLimitErrorCode.invalidResponse }
  }

  private static func window(_ input: Window?, seconds: Int) throws -> RateLimitWindow? {
    guard let input, let utilization = input.utilization else { return nil }
    return try RateLimitWindow(windowSeconds: seconds, usedPercent: utilization, resetsAt: input.resetsAt.flatMap(parseDate))
  }

  private static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    if let dot = value.firstIndex(of: ".") {
      let start = value.index(after: dot)
      let end = value[start...].firstIndex(where: { !$0.isNumber }) ?? value.endIndex
      let fraction = value[start..<end]
      let truncated = String(value[...dot]) + String(fraction.prefix(3)) + String(value[end...])
      if let date = formatter.date(from: truncated) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      return formatter.date(from: String(value[..<dot]) + String(value[end...]))
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private struct Payload: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?
  }
  private struct Window: Decodable {
    let utilization: Double?
    let resetsAt: String?
  }
}
