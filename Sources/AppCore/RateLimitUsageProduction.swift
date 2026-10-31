import Foundation

extension RateLimitUsageService {
  public static func production(environment: [String: String] = ProcessInfo.processInfo.environment) -> RateLimitUsageService {
    let transport = URLSessionRateLimitTransport()
    return RateLimitUsageService(
      claude: ClaudeRateLimitFetcher(credentials: ClaudeCredentialProvider(environment: environment), transport: transport),
      codex: CodexRateLimitFetcher(credentials: CodexCredentialProvider(environment: environment), transport: transport),
      codexFallback: CodexRateLimitSessionFallback(
        sessionsRoot: CodexHome.url(environment: environment).appendingPathComponent("sessions", isDirectory: true)
      )
    )
  }
}
