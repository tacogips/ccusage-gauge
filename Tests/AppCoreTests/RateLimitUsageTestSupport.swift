import Foundation
@testable import AppCore

let testClaudeToken = "test-claude-access-token"
let testCodexToken = "test-codex-access-token"
let testCodexAccountID = "test-codex-account-id"

final class RateLimitTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  func set(_ value: Date) { lock.withLock { self.value = value } }
  func now() -> Date { lock.withLock { value } }
}
actor FakeRateLimitFetcher: RateLimitLiveFetching {
  var results: [Result<RateLimitObservation, any Error>]
  var calls = 0
  let delay: Duration?
  init(_ results: [Result<RateLimitObservation, any Error>], delay: Duration? = nil) { self.results = results; self.delay = delay }
  func fetchLive(now: Date) async throws -> RateLimitObservation {
    calls += 1
    if let delay { try await Task.sleep(for: delay) }
    return try results.removeFirst().get()
  }
}
struct FakeRateLimitFallback: CodexRateLimitFallbackReading {
  let observation: RateLimitObservation?
  func latestObservation() async -> RateLimitObservation? { observation }
}
actor RecordingRateLimitTransport: RateLimitHTTPTransport {
  var requests: [(URL, [String: String])] = []
  let result: Result<RateLimitHTTPResponse, RateLimitErrorCode>
  init(_ result: Result<RateLimitHTTPResponse, RateLimitErrorCode>) { self.result = result }
  func get(url: URL, headers: [String: String], timeoutSeconds: TimeInterval) async throws -> RateLimitHTTPResponse {
    requests.append((url, headers)); return try result.get()
  }
}

actor ControlledRateLimitFetcher: RateLimitLiveFetching {
  private var pending: [CheckedContinuation<RateLimitObservation, any Error>] = []
  private var listeners: [CheckedContinuation<Void, Never>] = []
  private(set) var calls = 0
  func fetchLive(now: Date) async throws -> RateLimitObservation {
    calls += 1
    return try await withCheckedThrowingContinuation { continuation in
      pending.append(continuation)
      let waiting = listeners; listeners.removeAll()
      waiting.forEach { $0.resume() }
    }
  }
  func waitForCall(_ count: Int) async {
    while calls < count { await withCheckedContinuation { listeners.append($0) } }
  }
  func resolve(_ result: Result<RateLimitObservation, any Error>) {
    pending.removeFirst().resume(with: result)
  }
}

actor WaiterGate {
  private var joined = false
  private var paused = false
  private var listeners: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  func hook(_ completed: Bool) async {
    if completed {
      paused = true; notify()
      await withCheckedContinuation { releaseContinuation = $0 }
    } else {
      joined = true; notify()
    }
  }
  func waitJoined() async { while !joined { await withCheckedContinuation { listeners.append($0) } } }
  func waitPaused() async { while !paused { await withCheckedContinuation { listeners.append($0) } } }
  func release() { releaseContinuation?.resume(); releaseContinuation = nil }
  private func notify() { let waiting = listeners; listeners.removeAll(); waiting.forEach { $0.resume() } }
}
