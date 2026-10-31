import Foundation
import Testing
@testable import AppCore

private final class MemoryObservationStore: RateLimitObservationStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [RateLimitProvider: RateLimitObservation]
  init(_ values: [RateLimitProvider: RateLimitObservation] = [:]) { self.values = values }
  func load(_ provider: RateLimitProvider) -> RateLimitObservation? { lock.withLock { values[provider] } }
  func save(_ observation: RateLimitObservation, for provider: RateLimitProvider) { lock.withLock { values[provider] = observation } }
}

@Suite struct RateLimitUsageBackoffTests {
  private let start = Date(timeIntervalSince1970: 1_000_000)
  private func observation(_ date: Date, used: Double = 25) throws -> RateLimitObservation {
    try RateLimitObservation(planType: "pro", observedAt: date,
                             windows: [RateLimitWindow(windowSeconds: 604800, usedPercent: used, resetsAt: nil)],
                             credits: RateLimitCredits(unit: .usd, enabled: true, used: 1, limit: 10))
  }

  @Test func throttlingBacksOffExponentiallyAndResetsOnSuccess() async throws {
    let good = try observation(start)
    let throttled: Result<RateLimitObservation, any Error> = .failure(RateLimitErrorCode.rateLimited)
    let claude = FakeRateLimitFetcher([.success(good), throttled, throttled, .success(good), .success(good)])
    let codex = FakeRateLimitFetcher(Array(repeating: .success(good), count: 10))
    let clock = RateLimitTestClock(start)
    let service = RateLimitUsageService(claude: claude, codex: codex, codexFallback: nil, maximumBackoff: 150, now: { clock.now() })
    _ = await service.current()
    clock.set(start.addingTimeInterval(60))
    let first = await service.current().providers[0]
    #expect(first.status == .stale && first.errorCode == .rateLimited && first.credits?.used == 1)
    // First throttle waits one interval; the second doubles it.
    clock.set(start.addingTimeInterval(120)); _ = await service.current()
    #expect(await claude.calls == 3)
    clock.set(start.addingTimeInterval(239)); _ = await service.current()
    #expect(await claude.calls == 3)
    #expect(await codex.calls == 4)
    clock.set(start.addingTimeInterval(240))
    #expect(await service.current().providers[0].status == .ok)
    #expect(await claude.calls == 4)
    clock.set(start.addingTimeInterval(300)); _ = await service.current()
    #expect(await claude.calls == 5)
  }

  @Test func backoffIsCappedAndClaudeUsesItsOwnInterval() async throws {
    let good = try observation(start)
    let throttled: Result<RateLimitObservation, any Error> = .failure(RateLimitErrorCode.rateLimited)
    let claude = FakeRateLimitFetcher([throttled, throttled, throttled, throttled])
    let codex = FakeRateLimitFetcher(Array(repeating: .success(good), count: 10))
    let clock = RateLimitTestClock(start)
    let service = RateLimitUsageService(claude: claude, codex: codex, codexFallback: nil, claudeMinimumInterval: 300,
                                        maximumBackoff: 400, now: { clock.now() })
    let first = await service.current().providers[0]
    #expect(first.status == .unavailable && first.message == RateLimitErrorCode.rateLimited.message)
    clock.set(start.addingTimeInterval(299)); _ = await service.current()
    #expect(await claude.calls == 1)
    #expect(await codex.calls == 2)
    clock.set(start.addingTimeInterval(300)); _ = await service.current()
    clock.set(start.addingTimeInterval(300 + 399)); _ = await service.current()
    #expect(await claude.calls == 2)
    clock.set(start.addingTimeInterval(300 + 400)); _ = await service.current()
    #expect(await claude.calls == 3)
    clock.set(start.addingTimeInterval(700 + 400)); _ = await service.current()
    #expect(await claude.calls == 4)
  }

  @Test func restoresPersistedObservationAfterRestart() async throws {
    let saved = try observation(start.addingTimeInterval(-600), used: 40)
    let store = MemoryObservationStore([.claude: saved])
    let service = RateLimitUsageService(claude: FakeRateLimitFetcher([.failure(RateLimitErrorCode.rateLimited)]),
                                        codex: FakeRateLimitFetcher([.success(try observation(start))]),
                                        codexFallback: nil, store: store, now: { start })
    let result = await service.current()
    #expect(result.providers[0].status == .stale && result.providers[0].fetchedAt == saved.observedAt)
    #expect(result.providers[0].weekly?.usedPercent == 40 && result.providers[0].credits == saved.credits)
    #expect(store.load(.codex)?.observedAt == start)
  }

  @Test func fileStoreRoundTripsWithPrivatePermissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("state/rate-limits.json")
    let store = RateLimitObservationFileStore(url: url)
    #expect(store.load(.claude) == nil)
    let claude = try observation(start), codex = try observation(start, used: 90)
    store.save(claude, for: .claude)
    store.save(codex, for: .codex)
    #expect(RateLimitObservationFileStore(url: url).load(.claude) == claude)
    #expect(RateLimitObservationFileStore(url: url).load(.codex) == codex)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    try Data("not json".utf8).write(to: url)
    #expect(store.load(.claude) == nil)
  }
}
