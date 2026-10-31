import Foundation
import Testing
@testable import AppCore

private struct ClaudeFixtureCredential: ClaudeCredentialProviding {
  let expiresAt: Date?
  func claudeCredential() async throws -> ClaudeOAuthCredential {
    ClaudeOAuthCredential(accessToken: RedactedSecret(testClaudeToken), expiresAt: expiresAt, subscriptionType: "pro")
  }
}
private struct ClaudeProcessCall: Sendable {
  let executable: URL
  let arguments: [String]
  let timeout: TimeInterval
}
private actor ClaudeProcessFake: CCUsageProcessRunning {
  let result: ProcessResult
  var calls: [ClaudeProcessCall] = []
  init(status: Int32, body: String = "") {
    result = ProcessResult(stdout: Data(body.utf8), stderr: Data(), exitStatus: status)
  }
  func run(executable: URL, arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    calls.append(ClaudeProcessCall(executable: executable, arguments: arguments, timeout: timeoutSeconds))
    return result
  }
}
@Suite struct RateLimitUsageClaudeTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private func fetch(_ body: String, status: Int = 200, expiry: Date? = nil) -> (ClaudeRateLimitFetcher, RecordingRateLimitTransport) {
    let transport = RecordingRateLimitTransport(.success(RateLimitHTTPResponse(status: status, body: Data(body.utf8))))
    return (ClaudeRateLimitFetcher(credentials: ClaudeFixtureCredential(expiresAt: expiry), transport: transport), transport)
  }
  @Test func sampleAndHeaders() async throws {
    let body = #"{"five_hour":{"utilization":0.0,"resets_at":"2026-10-31T13:00:00.013669+00:00"},"#
      + #""seven_day":{"utilization":53.0,"resets_at":"2026-11-01T17:00:00.013690+00:00"},"#
      + #""seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":{"x":1}}"#
    let (fetcher, transport) = fetch(body)
    let observation = try await fetcher.fetchLive(now: now)
    #expect(observation.planType == "pro" && observation.observedAt == now)
    let slots = ProviderRateLimits.slots(observation.windows)
    #expect(slots.fiveHour?.usedPercent == 0 && slots.fiveHour?.remainingPercent == 100)
    #expect(slots.weekly?.usedPercent == 53 && slots.weekly?.remainingPercent == 47)
    let formatter = ISO8601DateFormatter()
    #expect(Int(try #require(slots.fiveHour?.resetsAt).timeIntervalSince1970) == Int(try #require(formatter.date(from: "2026-10-31T13:00:00Z")).timeIntervalSince1970))
    #expect(Int(try #require(slots.weekly?.resetsAt).timeIntervalSince1970) == Int(try #require(formatter.date(from: "2026-11-01T17:00:00Z")).timeIntervalSince1970))
    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(requests.count == 1 && request.0.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(request.1 == ["Authorization": "Bearer \(testClaudeToken)", "anthropic-beta": "oauth-2025-04-20", "Content-Type": "application/json"])
  }
  @Test func extraUsageCredits() async throws {
    let enabled = #"{"five_hour":{"utilization":1},"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1234.0,"utilization":24.68}}"#
    let credits = try #require(try await fetch(enabled).0.fetchLive(now: now).credits)
    #expect(credits == RateLimitCredits(unit: .usd, enabled: true, used: 12.34, limit: 50, usedPercent: 24.68))
    let disabled = #"{"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}"#
    #expect(try await fetch(disabled).0.fetchLive(now: now).credits == RateLimitCredits(unit: .usd, enabled: false))
    for body in [#"{"extra_usage":null}"#, #"{"extra_usage":{"x":1}}"#] {
      #expect(try await fetch(body).0.fetchLive(now: now).credits == nil)
    }
    let malformed = try await fetch(#"{"five_hour":{"utilization":2},"extra_usage":"bad"}"#).0.fetchLive(now: now)
    #expect(malformed.credits == nil && malformed.windows.first?.usedPercent == 2)
  }
  @Test func invalidAndOptionalWindows() async throws {
    for body in [#"{"five_hour":null}"#, #"{"five_hour":{"utilization":null}}"#] {
      let (fetcher, _) = fetch(body)
      #expect(try await fetcher.fetchLive(now: now).windows.isEmpty)
    }
    for body in ["[]", #"{"five_hour":{"utilization":-5}}"#] {
      let (fetcher, _) = fetch(body)
      await expectError(.invalidResponse) { try await fetcher.fetchLive(now: now) }
    }
    let (fetcher, _) = fetch(#"{"five_hour":{"utilization":1,"resets_at":"bad"}}"#)
    #expect(try await fetcher.fetchLive(now: now).windows.first?.resetsAt == nil)
  }
  @Test func statusesAndExpiry() async {
    for (status, code) in [(401, RateLimitErrorCode.unauthorized), (403, .unauthorized), (429, .rateLimited), (302, .httpError), (500, .httpError)] {
      let (fetcher, transport) = fetch("{}", status: status)
      await expectError(code) { try await fetcher.fetchLive(now: now) }
      let requests = await transport.requests
      #expect(requests.count == 1 && requests.allSatisfy { $0.0.path == "/api/oauth/usage" })
    }
    let (expired, transport) = fetch("{}", expiry: now)
    await expectError(.tokenExpired) { try await expired.fetchLive(now: now) }
    #expect(await transport.requests.isEmpty)
  }
  @Test func credentialsKeychainAndFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let json = #"{"claudeAiOauth":{"accessToken":"test-claude-access-token","expiresAt":1000,"subscriptionType":"pro"}}"#
    let runner = ClaudeProcessFake(status: 0, body: json)
    let environment = ["CLAUDE_CONFIG_DIR": directory.path]
    let keychain = ClaudeCredentialProvider(environment: environment, processRunner: runner, useKeychain: true)
    let credential = try await keychain.claudeCredential()
    #expect(credential.accessToken == RedactedSecret(testClaudeToken) && credential.subscriptionType == "pro")
    #expect(credential.expiresAt == Date(timeIntervalSince1970: 1))
    let calls = await runner.calls
    let call = try #require(calls.first)
    #expect(calls.count == 1 && call.executable.path == "/usr/bin/security" && call.arguments == ["find-generic-password", "-s", "Claude Code-credentials", "-w"] && call.timeout == 10)
    let missing = ClaudeProcessFake(status: 44)
    let fallback = ClaudeCredentialProvider(environment: environment, processRunner: missing, useKeychain: true)
    await expectError(.credentialsMissing) { try await fallback.claudeCredential() }
    let file = directory.appendingPathComponent(".credentials.json")
    try Data(json.utf8).write(to: file)
    #expect(try await fallback.claudeCredential().accessToken == RedactedSecret(testClaudeToken))
    try Data("{}".utf8).write(to: file)
    let fileOnly = ClaudeCredentialProvider(environment: environment, processRunner: missing, useKeychain: false)
    await expectError(.credentialsUnreadable) { try await fileOnly.claudeCredential() }
  }
  private func expectError<T>(_ code: RateLimitErrorCode, operation: () async throws -> T) async {
    do {
      _ = try await operation()
      Issue.record("Expected error \(code)")
    } catch {
      #expect(error as? RateLimitErrorCode == code)
      #expect(!String(describing: error).contains(testClaudeToken))
    }
  }
}
