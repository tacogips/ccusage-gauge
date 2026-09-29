import Foundation
import Testing
@testable import AppCore

@Suite("CodexEffortParsingTests") struct CodexEffortParsingTests {
  private let day = "2026-07-16"
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }

  @Test func tokenCountsInheritEffortAndTurnChangesMatchForwardAndReverseScans() async throws {
    let root = try temporaryRoot()
    try write([
      turnContext("gpt-x", effort: #""high""#),
      tokenEvent(time: "00:00:01", total: 10),
      tokenEvent(time: "00:00:02", total: 20),
      turnContext("gpt-x", effort: #""low""#),
      tokenEvent(time: "00:05:01", total: 30)
    ], to: root)

    let forward = try await CodexUsageEventLoader(roots: [root]).events(since: nil, until: day, calendar: calendar)
    let reverse = try await CodexUsageEventLoader(roots: [root]).events(since: day, until: day, calendar: calendar)

    #expect(forward.map(\.effort) == ["high", "high", "low"])
    #expect(forward.map(\.model) == ["gpt-x", "gpt-x", "gpt-x"])
    #expect(signatures(forward) == signatures(reverse))
  }

  @Test func turnWithoutEffortResetsPreviousEffortInBothScanDirections() async throws {
    let root = try temporaryRoot()
    try write([
      turnContext("gpt-x", effort: #""high""#),
      tokenEvent(time: "00:00:01", total: 10),
      turnContext("gpt-x", effort: nil),
      tokenEvent(time: "00:05:01", total: 20)
    ], to: root)

    let forward = try await CodexUsageEventLoader(roots: [root]).events(since: nil, until: day, calendar: calendar)
    let reverse = try await CodexUsageEventLoader(roots: [root]).events(since: day, until: day, calendar: calendar)

    #expect(forward.map(\.effort) == ["high", nil])
    #expect(reverse.map(\.effort) == ["high", nil])
    #expect(forward.map(\.model) == ["gpt-x", "gpt-x"])
    #expect(signatures(forward) == signatures(reverse))
  }

  @Test func effortIsNormalizedAndMalformedEffortDoesNotDropTurnContext() async throws {
    let root = try temporaryRoot()
    try write([
      turnContext("gpt-trimmed", effort: #"" Medium ""#),
      tokenEvent(time: "00:00:01", total: 10),
      turnContext("gpt-number", effort: "7"),
      tokenEvent(time: "00:01:01", total: 20),
      turnContext("gpt-object", effort: "{}"),
      tokenEvent(time: "00:02:01", total: 30)
    ], to: root)

    let events = try await CodexUsageEventLoader(roots: [root]).events(since: nil, until: day, calendar: calendar)

    #expect(events.map(\.model) == ["gpt-trimmed", "gpt-number", "gpt-object"])
    #expect(events.map(\.effort) == ["medium", nil, nil])
  }

  @Test func resumeCarriesLastTurnEffortAndMatchesFreshScan() async throws {
    let root = try temporaryRoot()
    let log = root.appendingPathComponent("rollout.jsonl")
    try write([
      turnContext("gpt-x", effort: #""high""#),
      tokenEvent(time: "00:00:01", total: 10)
    ], to: root)
    let loader = makeLoader(root)
    _ = try await loader.events(since: day, until: day, calendar: calendar)

    try append([
      tokenEvent(time: "00:05:01", total: 20),
      turnContext("gpt-x", effort: #""xhigh""#),
      tokenEvent(time: "00:10:01", total: 30)
    ], to: log)
    let resumed = try await loader.events(since: day, until: day, calendar: calendar)
    let fresh = try await makeLoader(root).events(since: day, until: day, calendar: calendar)

    #expect(resumed.map(\.effort) == ["high", "high", "xhigh"])
    #expect(signatures(resumed) == signatures(fresh))
  }

  @Test func claudeUsageEventsKeepEffortNil() async throws {
    let root = try temporaryRoot()
    let claudeEvent = [
      #"{"type":"assistant","timestamp":"2026-07-16T01:00:00.000Z","sessionId":"session-1","requestId":"request-1","message":{"id":"message-1","role":"assistant","model":"claude-test","usage":{"#,
      #""input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    ].joined()
    try write([claudeEvent], to: root)

    let events = try await ClaudeUsageEventLoader(roots: [root]).events(since: nil, until: day, calendar: calendar)

    #expect(events.count == 1)
    #expect(events.first?.effort == nil)
  }

  private func makeLoader(_ root: URL) -> CodexUsageEventLoader {
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    return CodexUsageEventLoader(
      rootProvider: { [root] },
      cachePolicy: UsageEventScanCachePolicy(windowDays: 8),
      now: { now }
    )
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func write(_ rows: [String], to root: URL) throws {
    try Data((rows.joined(separator: "\n") + "\n").utf8)
      .write(to: root.appendingPathComponent("rollout.jsonl"))
  }

  private func append(_ rows: [String], to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((rows.joined(separator: "\n") + "\n").utf8))
  }

  private func turnContext(_ model: String, effort: String?) -> String {
    let effortField = effort.map { #", "effort":\#($0)"# } ?? ""
    return #"{"timestamp":"2026-07-16T00:00:00.000Z","type":"turn_context","payload":{"model":"\#(model)"\#(effortField)}}"#
  }

  private func tokenEvent(time: String, total: Int) -> String {
    [
      #"{"timestamp":"2026-07-16T\#(time).000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"#,
      #""cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(total),"#,
      #""cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total)}}}}"#
    ].joined()
  }

  private func signatures(_ events: [TimestampedUsageEvent]) -> [String] {
    events.map { "\($0.identity)|\($0.model)|\($0.effort ?? "<nil>")" }.sorted()
  }
}
