import Foundation
import Testing
@testable import AppCore

private struct CodexTestCredentials: CodexCredentialProviding {
  func codexCredential() async throws -> CodexOAuthCredential {
    CodexOAuthCredential(accessToken: RedactedSecret(testCodexToken), accountID: RedactedSecret(testCodexAccountID))
  }
}
@Suite struct RateLimitUsageCodexTests {
  private func fetch(_ json: String, status: Int = 200, now: Date = Date(timeIntervalSince1970: 100)) async throws -> RateLimitObservation {
    let transport = RecordingRateLimitTransport(.success(RateLimitHTTPResponse(status: status, body: Data(json.utf8))))
    return try await CodexRateLimitFetcher(credentials: CodexTestCredentials(), transport: transport).fetchLive(now: now)
  }
  @Test func sampleAndHeaders() async throws {
    let json = #"{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{ "#
      + #""used_percent":82,"limit_window_seconds":604800,"reset_after_seconds":339165,"reset_at":1793774131},"secondary_window":null},"credits":{"has_credits":false}}"#
    let transport = RecordingRateLimitTransport(.success(RateLimitHTTPResponse(status: 200, body: Data(json.utf8))))
    let observation = try await CodexRateLimitFetcher(credentials: CodexTestCredentials(), transport: transport).fetchLive(now: Date())
    let slots = ProviderRateLimits.slots(observation.windows)
    #expect(observation.planType == "pro" && observation.windows.count == 1 && slots.fiveHour == nil)
    #expect(slots.weekly?.usedPercent == 82 && slots.weekly?.remainingPercent == 18)
    #expect(slots.weekly?.resetsAt == Date(timeIntervalSince1970: 1793774131))
    let requests = await transport.requests
    #expect(requests.count == 1 && requests[0].0.path == "/backend-api/wham/usage")
    #expect(requests[0].1 == ["Authorization": "Bearer \(testCodexToken)", "ChatGPT-Account-Id": testCodexAccountID])
  }
  @Test func credits() async throws {
    let balance = try await fetch(#"{"credits":{"has_credits":true,"unlimited":false,"balance":"62500.0000000000"}}"#).credits
    #expect(balance == RateLimitCredits(unit: .credits, enabled: true, balance: 62500))
    #expect(try await fetch(#"{"credits":{"has_credits":true,"balance":12.5}}"#).credits?.balance == 12.5)
    #expect(try await fetch(#"{"credits":{"has_credits":false}}"#).credits == RateLimitCredits(unit: .credits, enabled: false))
    #expect(try await fetch(#"{"credits":{"unlimited":true}}"#).credits == RateLimitCredits(unit: .credits, enabled: true, unlimited: true))
    #expect(try await fetch(#"{"credits":{}}"#).credits == nil)
    let malformed = try await fetch(#"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":18000}},"credits":"bad"}"#)
    #expect(malformed.credits == nil && malformed.windows.count == 1)
  }
  @Test func classificationsAndReset() async throws {
    for (first, second) in [(18000, 604800), (604800, 18000)] {
      let json = "{\"rate_limit\":{\"primary_window\":{\"used_percent\":1,\"limit_window_seconds\":\(first)},\"secondary_window\":{\"used_percent\":2,\"limit_window_seconds\":\(second)}}}"
      let slots = ProviderRateLimits.slots(try await fetch(json).windows)
      #expect(slots.fiveHour != nil && slots.weekly != nil)
    }
    let other = try await fetch(#"{"rate_limit":{"primary_window":{"used_percent":3,"limit_window_seconds":3600,"reset_after_seconds":60}}}"#)
    #expect(ProviderRateLimits.slots(other.windows).other.first?.resetsAt == Date(timeIntervalSince1970: 160))
    #expect(try await fetch("{}").windows.isEmpty)
    #expect(try await fetch(#"{"rate_limit":{"primary_window":{"used_percent":1}}}"#).windows.isEmpty)
  }
  @Test func failures() async throws {
    await #expect(throws: RateLimitErrorCode.invalidResponse) { try await fetch("[]") }
    for (status, error) in [(401, RateLimitErrorCode.unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .httpError)] {
      await #expect(throws: error) { try await fetch("{}", status: status) }
      #expect(!String(describing: error).contains(testCodexToken) && !String(describing: error).contains(testCodexAccountID))
    }
  }
  @Test func invalidWindows() async throws {
    let responses = [
      #"{"rate_limit":{"primary_window":{"used_percent":-5,"limit_window_seconds":18000}}}"#,
      #"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":0}}}"#,
      #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000},"secondary_window":{"used_percent":-1,"limit_window_seconds":604800}}}"#
    ]
    for response in responses {
      await #expect(throws: RateLimitErrorCode.invalidResponse) { try await fetch(response) }
    }
  }
  @Test func credentialFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = CodexCredentialProvider(environment: ["CODEX_HOME": root.path])
    #expect(CodexHome.url(environment: ["CODEX_HOME": root.path]).path == root.path)
    await #expect(throws: RateLimitErrorCode.credentialsMissing) { try await provider.codexCredential() }
    let file = root.appendingPathComponent("auth.json")
    try #"{"OPENAI_API_KEY":"x"}"#.write(to: file, atomically: true, encoding: .utf8)
    await #expect(throws: RateLimitErrorCode.credentialsMissing) { try await provider.codexCredential() }
    try "not json".write(to: file, atomically: true, encoding: .utf8)
    await #expect(throws: RateLimitErrorCode.credentialsUnreadable) { try await provider.codexCredential() }
    try "{\"tokens\":{\"access_token\":\"\(testCodexToken)\",\"account_id\":\"\(testCodexAccountID)\"}}".write(to: file, atomically: true, encoding: .utf8)
    let credential = try await provider.codexCredential()
    #expect(credential.accessToken.rawValue == testCodexToken && credential.accountID.rawValue == testCodexAccountID)
  }
}
