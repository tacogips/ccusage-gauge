import Foundation
import Testing
@testable import AppCore

private let fixedNow = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
private let utcCalendar: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}()

@Suite("ClaudeIncrementalScanTests") struct ClaudeIncrementalScanTests {
  @Test func appendedLinesAreParsedWithoutRescanningTheFile() async throws {
    let root = try temporaryDirectory()
    let log = root.appendingPathComponent("session.jsonl")
    try write([claudeEvent(time: "01:00:00", request: "r1", input: 10), claudeEvent(time: "01:05:00", request: "r2", input: 20)], to: log)
    let loader = makeClaudeLoader(root)

    let first = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    let scanned = try #require(cachedScan(await loader.cachedScans(), for: log))
    try append([claudeEvent(time: "01:10:00", request: "r3", input: 30)], to: log)
    let second = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    let resumed = try #require(cachedScan(await loader.cachedScans(), for: log))
    let fresh = try await makeClaudeLoader(root).events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)

    #expect(first.map(\.inputTokens) == [10, 20])
    #expect(second.map(\.inputTokens) == [10, 20, 30])
    #expect(second == fresh)
    #expect(resumed.scannedThrough ?? 0 > scanned.scannedThrough ?? 0)
    #expect(resumed.events.count == 3)
  }

  @Test func unchangedFileIsServedFromCache() async throws {
    let root = try temporaryDirectory()
    let log = root.appendingPathComponent("session.jsonl")
    try write([claudeEvent(time: "01:00:00", request: "r1", input: 10)], to: log)
    let loader = makeClaudeLoader(root)

    let first = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    let before = try #require(cachedScan(await loader.cachedScans(), for: log))
    let second = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    let after = try #require(cachedScan(await loader.cachedScans(), for: log))

    #expect(first == second)
    #expect(before.scannedThrough == after.scannedThrough)
    #expect(before.boundary == after.boundary)
  }

  @Test func partialTrailingLineIsRecoveredOnResume() async throws {
    let root = try temporaryDirectory()
    let log = root.appendingPathComponent("session.jsonl")
    let complete = claudeEvent(time: "01:00:00", request: "r1", input: 10)
    let pending = claudeEvent(time: "01:05:00", request: "r2", input: 20)
    let split = pending.index(pending.startIndex, offsetBy: 40)
    try Data((complete + "\n" + pending[..<split]).utf8).write(to: log)
    let loader = makeClaudeLoader(root)

    let first = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    try append(String(pending[split...]) + "\n" + claudeEvent(time: "01:10:00", request: "r3", input: 30), to: log, newlineFirst: false)
    let second = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)

    #expect(first.map(\.inputTokens) == [10])
    #expect(second.map(\.inputTokens) == [10, 20, 30])
  }

  @Test func rewrittenFileIsRescannedInsteadOfResumed() async throws {
    let root = try temporaryDirectory()
    let log = root.appendingPathComponent("session.jsonl")
    try write([claudeEvent(time: "01:00:00", request: "r1", input: 10)], to: log)
    let loader = makeClaudeLoader(root)

    _ = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    try write([
      claudeEvent(time: "02:00:00", request: "r9", input: 90),
      claudeEvent(time: "02:05:00", request: "r8", input: 80)
    ], to: log)
    let events = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)

    #expect(events.map(\.inputTokens) == [90, 80])
  }

  @Test func widerSinceRescansAndNarrowerSinceFiltersCachedEvents() async throws {
    let root = try temporaryDirectory()
    let log = root.appendingPathComponent("session.jsonl")
    try write([
      claudeEvent(day: "2026-07-10", time: "01:00:00", request: "old", input: 1),
      claudeEvent(day: "2026-07-16", time: "01:00:00", request: "new", input: 2)
    ], to: log)
    let loader = makeClaudeLoader(root)

    let today = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    let week = try await loader.events(since: "2026-07-10", until: "2026-07-16", calendar: utcCalendar)
    let todayAgain = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    let cached = try #require(cachedScan(await loader.cachedScans(), for: log))

    #expect(today.map(\.inputTokens) == [2])
    #expect(week.map(\.inputTokens) == [1, 2])
    #expect(todayAgain.map(\.inputTokens) == [2])
    #expect(cached.since == "2026-07-10")
  }

  @Test func scansOutsideTheRecentWindowAreNotCached() async throws {
    let root = try temporaryDirectory()
    let log = root.appendingPathComponent("session.jsonl")
    try write([claudeEvent(time: "01:00:00", request: "r1", input: 10)], to: log)
    let loader = ClaudeUsageEventLoader(
      rootProvider: { [root] },
      cachePolicy: UsageEventScanCachePolicy(windowDays: 8),
      now: { ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")! }
    )

    let events = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)

    #expect(events.count == 1)
    #expect(await loader.cachedScans().isEmpty)
  }

  private func makeClaudeLoader(_ root: URL) -> ClaudeUsageEventLoader {
    ClaudeUsageEventLoader(rootProvider: { [root] }, cachePolicy: UsageEventScanCachePolicy(windowDays: 8), now: { fixedNow })
  }
}

@Suite("CodexIncrementalScanTests") struct CodexIncrementalScanTests {
  @Test func appendedTokenCountsInheritTheLastTurnModelAcrossMidnight() async throws {
    let root = try temporaryDirectory()
    let log = root.appendingPathComponent("rollout.jsonl")
    try write([
      #"{"timestamp":"2026-07-15T20:00:00.000Z","type":"session_meta","payload":{"id":"session-1","cwd":"/work/project"}}"#,
      #"{"timestamp":"2026-07-15T23:00:00.000Z","type":"turn_context","payload":{"model":"gpt-yesterday"}}"#,
      codexTokenEvent(timestamp: "2026-07-15T23:30:00.000Z", total: 100)
    ], to: log)
    let loader = makeCodexLoader(root)

    let before = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    try append([codexTokenEvent(timestamp: "2026-07-16T00:30:00.000Z", total: 200)], to: log)
    let after = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    let fresh = try await makeCodexLoader(root).events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)

    #expect(before.isEmpty)
    #expect(after.map(\.model) == ["gpt-yesterday"])
    #expect(after == fresh)
  }

  @Test func appendedTurnContextSwitchesModelAndKeepsSessionMetadata() async throws {
    let root = try temporaryDirectory()
    let log = root.appendingPathComponent("rollout.jsonl")
    try write([
      #"{"timestamp":"2026-07-16T00:00:00.000Z","type":"session_meta","payload":{"id":"session-1","cwd":"/work/project"}}"#,
      #"{"timestamp":"2026-07-16T00:00:01.000Z","type":"turn_context","payload":{"model":"gpt-first"}}"#,
      codexTokenEvent(timestamp: "2026-07-16T00:05:00.000Z", total: 100)
    ], to: log)
    let loader = makeCodexLoader(root)

    let first = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    try append([
      #"{"timestamp":"2026-07-16T00:10:00.000Z","type":"turn_context","payload":{"model":"gpt-second"}}"#,
      codexTokenEvent(timestamp: "2026-07-16T00:15:00.000Z", total: 300)
    ], to: log)
    let second = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    let fresh = try await makeCodexLoader(root).events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    let cached = try #require(cachedScan(await loader.cachedScans(), for: log))

    #expect(first.map(\.model) == ["gpt-first"])
    #expect(second.map(\.model) == ["gpt-first", "gpt-second"])
    #expect(second.allSatisfy { $0.sessionID == "session-1" && $0.directory == "/work/project" })
    #expect(second == fresh)
    #expect(cached.context.model == "gpt-second")
    #expect(cached.events.count == 2)
  }

  @Test func rewrittenRolloutIsRescanned() async throws {
    let root = try temporaryDirectory()
    let log = root.appendingPathComponent("rollout.jsonl")
    try write([
      #"{"timestamp":"2026-07-16T00:00:01.000Z","type":"turn_context","payload":{"model":"gpt-first"}}"#,
      codexTokenEvent(timestamp: "2026-07-16T00:05:00.000Z", total: 100)
    ], to: log)
    let loader = makeCodexLoader(root)

    _ = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)
    try write([
      #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"turn_context","payload":{"model":"gpt-replacement"}}"#,
      codexTokenEvent(timestamp: "2026-07-16T01:05:00.000Z", total: 500),
      codexTokenEvent(timestamp: "2026-07-16T01:06:00.000Z", total: 600)
    ], to: log)
    let events = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: utcCalendar)

    #expect(events.map(\.model) == ["gpt-replacement", "gpt-replacement"])
    #expect(events.count == 2)
  }

  private func makeCodexLoader(_ root: URL) -> CodexUsageEventLoader {
    CodexUsageEventLoader(rootProvider: { [root] }, cachePolicy: UsageEventScanCachePolicy(windowDays: 8), now: { fixedNow })
  }
}

private func claudeEvent(day: String = "2026-07-16", time: String, request: String, input: Int) -> String {
  [
    #"{"type":"assistant","timestamp":"\#(day)T\#(time).000Z","sessionId":"session-1","requestId":"\#(request)","#,
    #""message":{"id":"message-\#(request)","role":"assistant","model":"claude-fable-5","usage":{"#,
    #""input_tokens":\#(input),"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
  ].joined()
}

private func codexTokenEvent(timestamp: String, total: Int) -> String {
  [
    #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"#,
    #""total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0,"#,
    #""reasoning_output_tokens":0,"total_tokens":\#(total)},"#,
    #""last_token_usage":{"input_tokens":10,"cached_input_tokens":3,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":12}}}}"#
  ].joined()
}

private func write(_ rows: [String], to url: URL) throws {
  try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: url)
}

private func append(_ rows: [String], to url: URL) throws {
  try append(rows.joined(separator: "\n") + "\n", to: url, newlineFirst: false)
}

private func append(_ text: String, to url: URL, newlineFirst: Bool) throws {
  let handle = try FileHandle(forWritingTo: url)
  defer { try? handle.close() }
  try handle.seekToEnd()
  try handle.write(contentsOf: Data(((newlineFirst ? "\n" : "") + text).utf8))
  // Make the modification visible to the next listing even on filesystems with coarse mtimes.
  try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
}

/// The directory enumerator reports canonical paths (`/private/var/...`) while the fixture URL
/// is the unresolved temporary path, so cache entries are matched by resolved path.
private func cachedScan<Context>(_ scans: [URL: UsageEventFileScan<Context>], for log: URL) -> UsageEventFileScan<Context>? {
  let target = (log.path as NSString).resolvingSymlinksInPath
  return scans.first { ($0.key.path as NSString).resolvingSymlinksInPath == target }?.value
}
