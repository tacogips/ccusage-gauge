import Foundation
import Testing
@testable import AppCore

@Suite struct RateLimitUsageServiceTests {
  private let start = Date(timeIntervalSince1970: 1_000_000)
  private func observation(_ date: Date, reset: Date? = nil, used: Double = 25) throws -> RateLimitObservation {
    try RateLimitObservation(planType: "pro", observedAt: date,
                             windows: [RateLimitWindow(windowSeconds: 18000, usedPercent: used, resetsAt: reset)])
  }
  @Test func successIsolationAndUnknownError() async throws {
    struct Unknown: Error {}
    let good = try observation(start)
    let claude = FakeRateLimitFetcher([.success(good), .failure(Unknown())])
    let codex = FakeRateLimitFetcher([.success(good), .success(good)])
    let clock = RateLimitTestClock(start)
    let service = RateLimitUsageService(claude: claude, codex: codex, codexFallback: nil, now: { clock.now() })
    let first = await service.current()
    #expect(first.providers.map(\.status) == [.ok, .ok])
    #expect(first.providers.allSatisfy { $0.fetchedAt == start })
    clock.set(start.addingTimeInterval(60))
    let second = await service.current()
    #expect(second.providers[0].status == .stale && second.providers[0].errorCode == .networkError)
    #expect(second.providers[1].status == .ok)
    let isolated = RateLimitUsageService(claude: FakeRateLimitFetcher([.failure(RateLimitErrorCode.networkError)]),
                                         codex: FakeRateLimitFetcher([.success(good)]), codexFallback: nil)
    let result = await isolated.current()
    #expect(result.providers[0].status == .unavailable && result.providers[1].status == .ok)
  }
  @Test func throttleSuccessAndFailure() async throws {
    let good = try observation(start)
    let clock = RateLimitTestClock(start)
    let claude = FakeRateLimitFetcher([.failure(RateLimitErrorCode.networkError), .success(good)])
    let codex = FakeRateLimitFetcher([.success(good), .success(good)])
    let service = RateLimitUsageService(claude: claude, codex: codex, codexFallback: nil, now: { clock.now() })
    _ = await service.current()
    clock.set(start.addingTimeInterval(59)); _ = await service.current()
    #expect(await claude.calls == 1)
    #expect(await codex.calls == 1)
    clock.set(start.addingTimeInterval(60)); _ = await service.current()
    #expect(await claude.calls == 2)
    #expect(await codex.calls == 2)
  }
  @Test func singleFlight() async throws {
    let good = try observation(start)
    let fetcher = FakeRateLimitFetcher([.success(good)], delay: .milliseconds(40))
    let service = RateLimitUsageService(claude: fetcher, codex: FakeRateLimitFetcher([.success(good)]), codexFallback: nil,
                                        now: { start })
    async let first = service.current()
    async let second = service.current()
    let results = await (first, second)
    #expect(results.0 == results.1)
    #expect(await fetcher.calls == 1)
  }
  @Test func claudeAuthOverridesLastGood() async throws {
    let good = try observation(start)
    let clock = RateLimitTestClock(start)
    let service = RateLimitUsageService(claude: FakeRateLimitFetcher([.success(good), .failure(RateLimitErrorCode.unauthorized)]),
      codex: FakeRateLimitFetcher([.success(good), .success(good)]), codexFallback: nil, now: { clock.now() })
    _ = await service.current(); clock.set(start.addingTimeInterval(60))
    let item = await service.current().providers[0]
    #expect(item.status == .unauthorized && item.fiveHour == nil && item.fetchedAt == nil)
    let expired = RateLimitUsageService(claude: FakeRateLimitFetcher([.failure(RateLimitErrorCode.tokenExpired)]),
                                       codex: FakeRateLimitFetcher([.success(good)]), codexFallback: nil)
    let result = await expired.current().providers[0]
    #expect(result.status == .unauthorized && result.errorCode == .tokenExpired)
  }
  @Test func codexFallbackAndNewestCandidate() async throws {
    let good = try observation(start)
    let old = try observation(start.addingTimeInterval(-600), used: 10)
    let clock = RateLimitTestClock(start)
    let service = RateLimitUsageService(claude: FakeRateLimitFetcher([.success(good), .success(good)]),
      codex: FakeRateLimitFetcher([.success(good), .failure(RateLimitErrorCode.unauthorized)]),
      codexFallback: FakeRateLimitFallback(observation: old), now: { clock.now() })
    _ = await service.current(); clock.set(start.addingTimeInterval(60))
    let result = await service.current().providers[1]
    #expect(result.status == .stale && result.fetchedAt == start && result.errorCode == .unauthorized)
    let fallback = RateLimitUsageService(claude: FakeRateLimitFetcher([.success(good)]),
      codex: FakeRateLimitFetcher([.failure(RateLimitErrorCode.unauthorized)]),
      codexFallback: FakeRateLimitFallback(observation: old), now: { start })
    #expect(await fallback.current().providers[1].fetchedAt == old.observedAt)
    let none = RateLimitUsageService(claude: FakeRateLimitFetcher([.success(good)]),
      codex: FakeRateLimitFetcher([.failure(RateLimitErrorCode.unauthorized)]), codexFallback: nil)
    #expect(await none.current().providers[1].status == .unauthorized)
    let newer = try observation(start.addingTimeInterval(30), used: 50)
    let clock2 = RateLimitTestClock(start)
    let newerService = RateLimitUsageService(claude: FakeRateLimitFetcher([.success(good), .success(good)]),
      codex: FakeRateLimitFetcher([.success(good), .failure(RateLimitErrorCode.networkError)]),
      codexFallback: FakeRateLimitFallback(observation: newer), now: { clock2.now() })
    _ = await newerService.current(); clock2.set(start.addingTimeInterval(60))
    #expect(await newerService.current().providers[1].fetchedAt == newer.observedAt)
  }
  @Test func staleWindowExpiry() async throws {
    let past = try RateLimitWindow(windowSeconds: 18000, usedPercent: 20, resetsAt: start)
    let future = try RateLimitWindow(windowSeconds: 604800, usedPercent: 30, resetsAt: start.addingTimeInterval(1))
    let credits = RateLimitCredits(unit: .credits, enabled: true, balance: 5)
    let mixed = RateLimitObservation(planType: nil, observedAt: start, windows: [past, future], credits: credits)
    let good = try observation(start)
    let service = RateLimitUsageService(claude: FakeRateLimitFetcher([.success(good)]),
      codex: FakeRateLimitFetcher([.failure(RateLimitErrorCode.networkError)]),
      codexFallback: FakeRateLimitFallback(observation: mixed), now: { start })
    let item = await service.current().providers[1]
    #expect(item.status == .stale && item.fiveHour == nil && item.weekly == future && item.credits == credits)
    let expired = RateLimitUsageService(claude: FakeRateLimitFetcher([.success(good)]),
      codex: FakeRateLimitFetcher([.failure(RateLimitErrorCode.networkError)]),
      codexFallback: FakeRateLimitFallback(observation: RateLimitObservation(planType: nil, observedAt: start, windows: [past])),
      now: { start })
    #expect(await expired.current().providers[1].status == .unavailable)
  }
  @Test func sequentialFlightsKeepNewerLastGood() async throws {
    let first = try observation(start, used: 10)
    let second = try observation(start.addingTimeInterval(60), used: 70)
    let clock = RateLimitTestClock(start)
    let fetcher = ControlledRateLimitFetcher()
    let service = RateLimitUsageService(claude: fetcher, codex: FakeRateLimitFetcher([.success(first), .success(first), .success(first)]),
                                        codexFallback: nil, now: { clock.now() })
    let gate = WaiterGate()
    await service.setWaiterHook { completed in await gate.hook(completed) }
    let owner = Task { await service.current() }
    await fetcher.waitForCall(1)
    let waiter = Task { await service.current() }
    await gate.waitJoined()
    await fetcher.resolve(.success(first))
    await gate.waitPaused()
    _ = await owner.value
    clock.set(start.addingTimeInterval(60))
    let next = Task { await service.current() }
    await fetcher.waitForCall(2)
    await gate.release()
    #expect(await waiter.value.providers[0].fiveHour?.usedPercent == 10)
    await fetcher.resolve(.success(second))
    #expect(await next.value.providers[0].fiveHour?.usedPercent == 70)
    #expect(await service.current().providers[0].fiveHour?.usedPercent == 70)
    clock.set(start.addingTimeInterval(120))
    let failure = Task { await service.current() }
    await fetcher.waitForCall(3)
    await fetcher.resolve(.failure(RateLimitErrorCode.networkError))
    let stale = await failure.value.providers[0]
    #expect(stale.status == .stale && stale.fiveHour?.usedPercent == 70)
  }

}
