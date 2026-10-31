import Foundation

public struct RedactedSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  let rawValue: String
  public init(_ value: String) { rawValue = value }
  public var description: String { "<redacted>" }
  public var debugDescription: String { "<redacted>" }
  public var customMirror: Mirror { Mirror(self, children: ["value": "<redacted>"]) }
}
public struct ClaudeOAuthCredential: Sendable {
  public let accessToken: RedactedSecret
  public let expiresAt: Date?
  public let subscriptionType: String?
  public init(accessToken: RedactedSecret, expiresAt: Date?, subscriptionType: String?) {
    self.accessToken = accessToken; self.expiresAt = expiresAt; self.subscriptionType = subscriptionType
  }
}
public struct CodexOAuthCredential: Sendable {
  public let accessToken: RedactedSecret
  public let accountID: RedactedSecret
  public init(accessToken: RedactedSecret, accountID: RedactedSecret) { self.accessToken = accessToken; self.accountID = accountID }
}
public protocol ClaudeCredentialProviding: Sendable { func claudeCredential() async throws -> ClaudeOAuthCredential }
public protocol CodexCredentialProviding: Sendable { func codexCredential() async throws -> CodexOAuthCredential }
public struct RateLimitHTTPResponse: Sendable {
  public let status: Int
  public let body: Data
  public init(status: Int, body: Data) { self.status = status; self.body = body }
}
public protocol RateLimitHTTPTransport: Sendable {
  func get(url: URL, headers: [String: String], timeoutSeconds: TimeInterval) async throws -> RateLimitHTTPResponse
}
public protocol RateLimitLiveFetching: Sendable { func fetchLive(now: Date) async throws -> RateLimitObservation }
public protocol CodexRateLimitFallbackReading: Sendable { func latestObservation() async -> RateLimitObservation? }
