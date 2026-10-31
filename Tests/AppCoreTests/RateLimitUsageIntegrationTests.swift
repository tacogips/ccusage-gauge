import Foundation
import Testing
@testable import AppCore

private struct IntegrationClaudeCredentials: ClaudeCredentialProviding {
  let expiry: Date
  func claudeCredential() async throws -> ClaudeOAuthCredential {
    ClaudeOAuthCredential(accessToken: RedactedSecret(testClaudeToken), expiresAt: expiry, subscriptionType: "pro")
  }
}

private struct IntegrationCodexCredentials: CodexCredentialProviding {
  func codexCredential() async throws -> CodexOAuthCredential {
    CodexOAuthCredential(accessToken: RedactedSecret(testCodexToken), accountID: RedactedSecret(testCodexAccountID))
  }
}

@Suite struct RateLimitUsageIntegrationTests {
  @Test func productionAndRoutes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = RateLimitUsageService.production(environment: ["HOME": root.path])
    let now = Date(timeIntervalSince1970: 1_793_448_000)
    let claudeBody = #"{"five_hour":{"utilization":0.0,"resets_at":"2026-10-31T13:00:00.013669+00:00"},"#
      + #""seven_day":{"utilization":53.0,"resets_at":"2026-11-01T17:00:00.013690+00:00"},"#
      + #""seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":{"x":1}}"#
    let codexBody = #"{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{ "#
      + #""used_percent":82,"limit_window_seconds":604800,"reset_after_seconds":339165,"reset_at":1793774131},"secondary_window":null},"credits":{"has_credits":false}}"#
    let claudeTransport = RecordingRateLimitTransport(.success(RateLimitHTTPResponse(status: 200, body: Data(claudeBody.utf8))))
    let codexTransport = RecordingRateLimitTransport(.success(RateLimitHTTPResponse(status: 200, body: Data(codexBody.utf8))))
    let service = RateLimitUsageService(
      claude: ClaudeRateLimitFetcher(credentials: IntegrationClaudeCredentials(expiry: now.addingTimeInterval(3600)), transport: claudeTransport),
      codex: CodexRateLimitFetcher(credentials: IntegrationCodexCredentials(), transport: codexTransport),
      codexFallback: nil, now: { now }
    )
    let plain = DashboardRouter(snapshotProvider: { throw CancellationError() }, assetResolver: StaticAssetResolver(explicitRoot: root), rateLimitService: service)
    let machine = try makeMachine(root: root, service: service)
    let first = await plain.route(target: "/api/rate-limits")
    let second = await machine.route(target: "/api/rate-limits", method: "GET", headers: [:], body: Data(), listenerPort: 18081)
    #expect(first.status == 200 && second.status == 200)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let firstResult = try decoder.decode(RateLimitsResponse.self, from: first.body)
    let secondResult = try decoder.decode(RateLimitsResponse.self, from: second.body)
    for body in [first.body, second.body] {
      let text = try #require(String(data: body, encoding: .utf8))
      for secret in [testClaudeToken, testCodexToken, testCodexAccountID] { #expect(!text.contains(secret)) }
    }
    #expect(firstResult == secondResult)
    #expect(firstResult.providers.map(\.provider) == [.claude, .codex])
    let claude = try #require(firstResult.providers.first { $0.provider == .claude })
    let codex = try #require(firstResult.providers.first { $0.provider == .codex })
    #expect(claude.fiveHour?.remainingPercent == 100 && claude.weekly?.remainingPercent == 47)
    #expect(codex.weekly?.usedPercent == 82 && codex.fiveHour == nil)
    let requests = await claudeTransport.requests + codexTransport.requests
    #expect(requests.count == 2)
    #expect(Set(requests.map { $0.0.path }) == Set(["/api/oauth/usage", "/backend-api/wham/usage"]))
    for request in requests {
      let url = request.0.absoluteString.lowercased()
      #expect(!url.contains("token") && !url.contains("refresh"))
    }
  }

  private func makeMachine(root: URL, service: RateLimitUsageService) throws -> MachineDashboardRouter {
    let paths = AppPaths(configFile: root.appendingPathComponent("config.json"), stateFile: root.appendingPathComponent("state.json"), aggregationCacheFile: root.appendingPathComponent("cache.sqlite3"))
    let registryStore = MachineRegistryStore(fileURL: paths.machinesFile)
    let registry = try registryStore.load()
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    let collector = try MachineCollector(registry: registry, store: store, connectionTester: { _ in }, serviceFactory: { _ in
      SnapshotService(stateStore: StateStore(fileURL: paths.stateFile), client: CCUsageClient(executable: URL(fileURLWithPath: "/usr/bin/false")), aggregationCache: nil)
    })
    let owner = MachineRegistryMutationOwner(store: registryStore, registry: registry, runtime: collector)
    return MachineDashboardRouter(store: store, collector: collector, mutationOwner: owner, paths: paths, rateLimitService: service)
  }
}
