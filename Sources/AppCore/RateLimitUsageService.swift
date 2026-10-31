import Foundation

public actor RateLimitUsageService {
  private struct State {
    var lastAttempt: Date?
    var cached: ProviderRateLimits?
    var lastGood: RateLimitObservation?
    var flight: Task<ProviderRateLimits, Never>?
    var generation: UInt64 = 0
  }
  private enum Outcome: Sendable {
    case success(RateLimitObservation)
    case failure(RateLimitErrorCode, RateLimitObservation?)
  }
  private let claude: any RateLimitLiveFetching
  private let codex: any RateLimitLiveFetching
  private let fallback: (any CodexRateLimitFallbackReading)?
  private let minimumInterval: TimeInterval
  private let now: @Sendable () -> Date
  private var states: [RateLimitProvider: State] = [:]
  private var waiterHook: (@Sendable (Bool) async -> Void)?

  func setWaiterHook(_ hook: @escaping @Sendable (Bool) async -> Void) { waiterHook = hook }

  public init(claude: any RateLimitLiveFetching, codex: any RateLimitLiveFetching,
              codexFallback: (any CodexRateLimitFallbackReading)?, minimumInterval: TimeInterval = 60,
              now: @escaping @Sendable () -> Date = { Date() }) {
    self.claude = claude; self.codex = codex; self.fallback = codexFallback
    self.minimumInterval = minimumInterval; self.now = now
  }
  public func current() async -> RateLimitsResponse {
    async let claudeResult = entry(for: .claude)
    async let codexResult = entry(for: .codex)
    let providers = await [claudeResult, codexResult]
    return RateLimitsResponse(generatedAt: now(), providers: providers)
  }
  private func entry(for provider: RateLimitProvider) async -> ProviderRateLimits {
    var state = states[provider] ?? State()
    let attemptTime = now()
    if let flight = state.flight {
      let hook = waiterHook
      await hook?(false)
      let result = await flight.value
      await hook?(true)
      return result
    }
    if let cached = state.cached, let last = state.lastAttempt, attemptTime.timeIntervalSince(last) < minimumInterval {
      return cached
    }
    let fetcher = provider == .claude ? claude : codex
    let fallback = provider == .codex ? self.fallback : nil
    state.generation &+= 1
    let generation = state.generation
    let flight = Task<ProviderRateLimits, Never> {
      let outcome: Outcome
      do { outcome = .success(try await fetcher.fetchLive(now: attemptTime)) } catch {
        let code = error as? RateLimitErrorCode ?? .networkError
        outcome = .failure(code, await fallback?.latestObservation())
      }
      return self.finish(provider: provider, generation: generation, outcome: outcome)
    }
    state.lastAttempt = attemptTime; state.flight = flight; states[provider] = state
    return await flight.value
  }
  private func finish(provider: RateLimitProvider, generation: UInt64, outcome: Outcome) -> ProviderRateLimits {
    var state = states[provider] ?? State()
    let result: ProviderRateLimits
    switch outcome {
    case .success(let observation):
      state.lastGood = observation
      result = makeEntry(provider: provider, status: .ok, code: nil, observation: observation)
    case .failure(let code, let fallback):
      if provider == .claude && (code == .unauthorized || code == .tokenExpired) {
        result = makeEntry(provider: provider, status: .unauthorized, code: code, observation: nil)
      } else {
        let candidate = [state.lastGood, fallback].compactMap { $0 }.max { $0.observedAt < $1.observedAt }
        let instant = now()
        let windows = candidate?.windows.filter { $0.resetsAt.map { $0 > instant } ?? true } ?? []
        if let candidate, !windows.isEmpty {
          let usable = RateLimitObservation(planType: candidate.planType, observedAt: candidate.observedAt, windows: windows)
          result = makeEntry(provider: provider, status: .stale, code: code, observation: usable)
        } else {
          let status: RateLimitStatus = code == .unauthorized || code == .tokenExpired ? .unauthorized : .unavailable
          result = makeEntry(provider: provider, status: status, code: code, observation: nil)
        }
      }
    }
    if state.generation == generation, state.flight != nil {
      state.cached = result; state.flight = nil; states[provider] = state
    }
    return result
  }
  private func makeEntry(provider: RateLimitProvider, status: RateLimitStatus, code: RateLimitErrorCode?,
                         observation: RateLimitObservation?) -> ProviderRateLimits {
    let slots = ProviderRateLimits.slots(observation?.windows ?? [])
    return ProviderRateLimits(provider: provider, status: status, errorCode: code, message: code?.message,
                              planType: observation?.planType, fetchedAt: observation?.observedAt, stale: status == .stale,
                              fiveHour: slots.fiveHour, weekly: slots.weekly, otherWindows: slots.other)
  }
}
