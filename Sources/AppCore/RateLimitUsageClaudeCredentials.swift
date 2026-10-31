import Foundation

public struct ClaudeCredentialProvider: ClaudeCredentialProviding {
  private let environment: [String: String]
  private let processRunner: any CCUsageProcessRunning
  private let useKeychain: Bool

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    processRunner: any CCUsageProcessRunning = CCUsageProcessRunner(),
    useKeychain: Bool = {
      #if os(macOS)
      true
      #else
      false
      #endif
    }()
  ) {
    self.environment = environment
    self.processRunner = processRunner
    self.useKeychain = useKeychain
  }

  public func claudeCredential() async throws -> ClaudeOAuthCredential {
    if useKeychain,
       let result = try? await processRunner.run(
         executable: URL(fileURLWithPath: "/usr/bin/security"),
         arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
         timeoutSeconds: 10
       ), result.exitStatus == 0, result.terminationReason == .exit,
       let credential = try? Self.decode(result.stdout) {
      return credential
    }
    let home = environment["CLAUDE_CONFIG_DIR"] ?? ((environment["HOME"] ?? NSHomeDirectory()) + "/.claude")
    let path = URL(fileURLWithPath: home).appendingPathComponent(".credentials.json")
    guard FileManager.default.fileExists(atPath: path.path) else { throw RateLimitErrorCode.credentialsMissing }
    do { return try Self.decode(Data(contentsOf: path)) } catch { throw RateLimitErrorCode.credentialsUnreadable }
  }

  private static func decode(_ data: Data) throws -> ClaudeOAuthCredential {
    let oauth = try JSONDecoder().decode(CredentialFile.self, from: data).claudeAiOauth
    guard let token = oauth.accessToken, !token.isEmpty else { throw RateLimitErrorCode.credentialsUnreadable }
    return ClaudeOAuthCredential(accessToken: RedactedSecret(token),
                                 expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                                 subscriptionType: oauth.subscriptionType)
  }

  private struct CredentialFile: Decodable {
    let claudeAiOauth: OAuth
  }
  private struct OAuth: Decodable {
    let accessToken: String?
    let expiresAt: Double?
    let subscriptionType: String?
  }
}
