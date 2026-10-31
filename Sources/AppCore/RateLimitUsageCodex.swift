import Foundation

public enum CodexHome {
  public static func url(environment: [String: String]) -> URL {
    if let home = environment["CODEX_HOME"] { return URL(fileURLWithPath: home, isDirectory: true) }
    return URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".codex", isDirectory: true)
  }
}

public struct CodexCredentialProvider: CodexCredentialProviding {
  private let environment: [String: String]
  public init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }
  public func codexCredential() async throws -> CodexOAuthCredential {
    let url = CodexHome.url(environment: environment).appendingPathComponent("auth.json")
    guard FileManager.default.fileExists(atPath: url.path) else { throw RateLimitErrorCode.credentialsMissing }
    let auth: CodexAuth
    do { auth = try JSONDecoder().decode(CodexAuth.self, from: Data(contentsOf: url)) } catch { throw RateLimitErrorCode.credentialsUnreadable }
    guard let access = auth.tokens?.accessToken, !access.isEmpty,
          let account = auth.tokens?.accountID, !account.isEmpty else { throw RateLimitErrorCode.credentialsMissing }
    return CodexOAuthCredential(accessToken: RedactedSecret(access), accountID: RedactedSecret(account))
  }
}
private struct CodexAuth: Decodable {
  let tokens: CodexTokens?
}
private struct CodexTokens: Decodable {
  let accessToken: String?
  let accountID: String?
  enum CodingKeys: String, CodingKey { case accessToken = "access_token", accountID = "account_id" }
}

public struct CodexRateLimitFetcher: RateLimitLiveFetching {
  private let credentials: any CodexCredentialProviding
  private let transport: any RateLimitHTTPTransport
  private let timeoutSeconds: TimeInterval
  public init(credentials: any CodexCredentialProviding, transport: any RateLimitHTTPTransport, timeoutSeconds: TimeInterval = 15) {
    self.credentials = credentials; self.transport = transport; self.timeoutSeconds = timeoutSeconds
  }
  public func fetchLive(now: Date) async throws -> RateLimitObservation {
    let credential = try await credentials.codexCredential()
    let response = try await transport.get(
      url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
      headers: ["Authorization": "Bearer \(credential.accessToken.rawValue)", "ChatGPT-Account-Id": credential.accountID.rawValue],
      timeoutSeconds: timeoutSeconds
    )
    switch response.status {
    case 200: break
    case 401, 403: throw RateLimitErrorCode.unauthorized
    case 429: throw RateLimitErrorCode.rateLimited
    default: throw RateLimitErrorCode.httpError
    }
    let payload: CodexPayload
    do { payload = try JSONDecoder().decode(CodexPayload.self, from: response.body) } catch { throw RateLimitErrorCode.invalidResponse }
    return RateLimitObservation(planType: payload.planType, observedAt: now,
                                windows: try [payload.rateLimit?.primary, payload.rateLimit?.secondary].compactMap { try $0?.window(now: now) },
                                credits: payload.credits?.credits)
  }
}
private struct CodexPayload: Decodable {
  let planType: String?
  let rateLimit: CodexLimits?
  let credits: CodexCreditsPayload?
  enum CodingKeys: String, CodingKey { case planType = "plan_type", rateLimit = "rate_limit", credits }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    planType = try container.decodeIfPresent(String.self, forKey: .planType)
    rateLimit = try container.decodeIfPresent(CodexLimits.self, forKey: .rateLimit)
    credits = try? container.decodeIfPresent(CodexCreditsPayload.self, forKey: .credits)
  }
}
/// Codex reports a remaining credit balance (as a decimal string) rather than a capped allowance.
struct CodexCreditsPayload: Decodable {
  let hasCredits: Bool?
  let unlimited: Bool?
  let balance: Double?
  enum CodingKeys: String, CodingKey { case hasCredits = "has_credits", unlimited, balance }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hasCredits = try container.decodeIfPresent(Bool.self, forKey: .hasCredits)
    unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited)
    if let text = try? container.decodeIfPresent(String.self, forKey: .balance) {
      balance = Double(text)
    } else {
      balance = try? container.decodeIfPresent(Double.self, forKey: .balance)
    }
  }
  var credits: RateLimitCredits? {
    guard hasCredits != nil || unlimited != nil else { return nil }
    let unlimited = unlimited ?? false
    return RateLimitCredits(unit: .credits, enabled: hasCredits ?? unlimited, unlimited: unlimited, balance: balance)
  }
}
private struct CodexLimits: Decodable {
  let primary: CodexWindow?
  let secondary: CodexWindow?
  enum CodingKeys: String, CodingKey { case primary = "primary_window", secondary = "secondary_window" }
}
private struct CodexWindow: Decodable {
    let used: Double?
    let seconds: Int?
    let resetAt: Double?
    let resetAfter: Double?
    enum CodingKeys: String, CodingKey {
      case used = "used_percent", seconds = "limit_window_seconds", resetAt = "reset_at", resetAfter = "reset_after_seconds"
    }
    func window(now: Date) throws -> RateLimitWindow? {
      guard let used, let seconds else { return nil }
      let reset = resetAt.map { Date(timeIntervalSince1970: $0) } ?? resetAfter.map { now.addingTimeInterval($0) }
      return try RateLimitWindow(windowSeconds: seconds, usedPercent: used, resetsAt: reset)
    }
  }
