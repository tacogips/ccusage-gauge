import Foundation
import Testing
@testable import AppCore

private func makeSessionRoot(agent: MachineSessionAgent) throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("scan-pruning-\(UUID().uuidString)", isDirectory: true)
  let scan = root.appendingPathComponent(agent == .codex ? "sessions" : "projects", isDirectory: true)
  try FileManager.default.createDirectory(
    at: scan.appendingPathComponent("2026/08/24", isDirectory: true),
    withIntermediateDirectories: true
  )
  return root
}

private func writeJSONL(
  under root: URL,
  agent: MachineSessionAgent,
  relativePath: String,
  content: String,
  modifiedAt: Date
) throws -> URL {
  let scan = root.appendingPathComponent(agent == .codex ? "sessions" : "projects", isDirectory: true)
  let url = scan.appendingPathComponent(relativePath)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data(content.utf8).write(to: url)
  try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
  return url
}

private actor EnvironmentRecorder {
  private(set) var environments: [[String: String]] = []
  private(set) var codexSessionListings: [[String]] = []

  func record(environment: [String: String]) {
    environments.append(environment)
    guard let codexHome = environment["CODEX_HOME"] else {
      codexSessionListings.append([])
      return
    }
    let sessions = URL(fileURLWithPath: codexHome).appendingPathComponent("sessions")
    let listed = (FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil)?
      .compactMap { ($0 as? URL).flatMap { $0.pathExtension == "jsonl" ? $0.lastPathComponent : nil } }
      ?? []).sorted()
    codexSessionListings.append(listed)
  }
}

private struct RecordingEnvironmentProcessRunner: CCUsageEnvironmentProcessRunning {
  let recorder: EnvironmentRecorder

  func run(executable: URL, arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    ProcessResult(stdout: Data("{}".utf8), stderr: Data(), exitStatus: 0)
  }

  func run(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    timeoutSeconds: TimeInterval
  ) async throws -> ProcessResult {
    await recorder.record(environment: environment)
    return ProcessResult(stdout: Data("{}".utf8), stderr: Data(), exitStatus: 0)
  }
}

@Suite("SessionScanPruningTests") struct SessionScanPruningTests {
  @Test func cutoffRequiresParsableSinceArgument() {
    #expect(SessionScanPruning.mtimeCutoff(arguments: ["daily", "--json"]) == nil)
    #expect(SessionScanPruning.mtimeCutoff(arguments: ["daily", "--since"]) == nil)
    #expect(SessionScanPruning.mtimeCutoff(arguments: ["daily", "--since", "not-a-date"]) == nil)
    let cutoff = SessionScanPruning.mtimeCutoff(arguments: ["daily", "--since", "2026-08-24", "--until", "2026-08-24"])
    // 2026-08-24T00:00:00Z minus the 48h timezone-safety buffer.
    #expect(cutoff == Date(timeIntervalSince1970: 1_787_529_600 - 48 * 3_600))
  }

  @Test func cutoffTokenUsesTouchTimestampFormat() {
    let token = SessionScanPruning.mtimeCutoffToken(arguments: ["blocks", "--since", "2026-08-24"])
    #expect(token == "202608220000")
    #expect(SessionScanPruning.mtimeCutoffToken(arguments: ["blocks", "--json"]) == nil)
  }

  @Test func prunedRootMirrorsOnlyRecentJSONLFiles() throws {
    let root = try makeSessionRoot(agent: .codex)
    defer { try? FileManager.default.removeItem(at: root) }
    let cutoff = Date(timeIntervalSince1970: 1_787_702_400)
    _ = try writeJSONL(
      under: root, agent: .codex,
      relativePath: "2026/05/01/rollout-old.jsonl",
      content: "old",
      modifiedAt: cutoff.addingTimeInterval(-60)
    )
    let recent = try writeJSONL(
      under: root, agent: .codex,
      relativePath: "2026/08/24/rollout-recent.jsonl",
      content: "recent",
      modifiedAt: cutoff.addingTimeInterval(60)
    )
    _ = try writeJSONL(
      under: root, agent: .codex,
      relativePath: "2026/08/24/notes.txt",
      content: "ignored",
      modifiedAt: cutoff.addingTimeInterval(60)
    )

    let mirror = try #require(SessionScanPruning.prunedRoot(original: root.path, agent: .codex, cutoff: cutoff))
    defer { try? FileManager.default.removeItem(at: mirror) }

    let mirroredRecent = mirror.appendingPathComponent("sessions/2026/08/24/rollout-recent.jsonl")
    #expect(try String(contentsOf: mirroredRecent, encoding: .utf8) == "recent")
    #expect(try String(contentsOf: recent, encoding: .utf8) == "recent")
    #expect(!FileManager.default.fileExists(
      atPath: mirror.appendingPathComponent("sessions/2026/05/01/rollout-old.jsonl").path
    ))
    #expect(!FileManager.default.fileExists(
      atPath: mirror.appendingPathComponent("sessions/2026/08/24/notes.txt").path
    ))
  }

  @Test func prunedRootRequiresScanDirectory() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("scan-pruning-missing-\(UUID().uuidString)")
    #expect(SessionScanPruning.prunedRoot(original: missing.path, agent: .codex, cutoff: Date()) == nil)
  }

  @Test func localRunnerPrunesCodexHomeForBoundedQueriesAndCleansUp() async throws {
    let root = try makeSessionRoot(agent: .codex)
    defer { try? FileManager.default.removeItem(at: root) }
    let cutoff = try #require(SessionScanPruning.mtimeCutoff(arguments: ["daily", "--since", "2026-08-24"]))
    _ = try writeJSONL(
      under: root, agent: .codex,
      relativePath: "2026/05/01/rollout-old.jsonl",
      content: "old",
      modifiedAt: cutoff.addingTimeInterval(-60)
    )
    _ = try writeJSONL(
      under: root, agent: .codex,
      relativePath: "2026/08/24/rollout-recent.jsonl",
      content: "recent",
      modifiedAt: cutoff.addingTimeInterval(60)
    )
    let source = MachineSessionSource(
      agent: .codex,
      execution: .value(root.path),
      resolvedRoot: root.path,
      scanScope: root.appendingPathComponent("sessions").path,
      exists: true,
      isDirectory: true,
      isDefault: false
    )
    let recorder = EnvironmentRecorder()
    let runner = LocalCCUsageCommandRunner(
      executable: URL(fileURLWithPath: "/usr/bin/true"),
      processRunner: RecordingEnvironmentProcessRunner(recorder: recorder)
    )

    _ = try await runner.run(
      arguments: ["daily", "--json", "--since", "2026-08-24", "--until", "2026-08-24"],
      source: source,
      timeoutSeconds: 5
    )

    let environment = try #require(await recorder.environments.first)
    let codexHome = try #require(environment["CODEX_HOME"])
    #expect(codexHome != root.path)
    #expect(await recorder.codexSessionListings.first == ["rollout-recent.jsonl"])
    // The pruned mirror is temporary and removed after the command finishes.
    #expect(!FileManager.default.fileExists(atPath: codexHome))
  }

  @Test func localRunnerKeepsRealRootForUnboundedQueries() async throws {
    let root = try makeSessionRoot(agent: .codex)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = MachineSessionSource(
      agent: .codex,
      execution: .value(root.path),
      resolvedRoot: root.path,
      scanScope: root.appendingPathComponent("sessions").path,
      exists: true,
      isDirectory: true,
      isDefault: false
    )
    let recorder = EnvironmentRecorder()
    let runner = LocalCCUsageCommandRunner(
      executable: URL(fileURLWithPath: "/usr/bin/true"),
      processRunner: RecordingEnvironmentProcessRunner(recorder: recorder)
    )

    _ = try await runner.run(arguments: ["daily", "--json"], source: source, timeoutSeconds: 5)

    let environment = try #require(await recorder.environments.first)
    #expect(environment["CODEX_HOME"] == root.path)
  }

  @Test func remoteAdapterReceivesCutoffTokenForBoundedQueries() throws {
    let connection = SSHConnection(host: "localhost", port: 22, user: "user")
    let source = MachineSessionSource(
      agent: .codex,
      execution: .value("/srv/codex"),
      resolvedRoot: "/srv/codex",
      scanScope: "/srv/codex/sessions",
      exists: true,
      isDirectory: true,
      isDefault: false
    )
    let runner = try SSHCCUsageCommandRunner(connection: connection)

    let bounded = try runner.sourceSSHArguments(
      ccusageArguments: ["daily", "--json", "--since", "2026-08-24", "--until", "2026-08-24"],
      source: source
    )
    #expect(bounded.contains("'202608220000'"))
    #expect(bounded.contains(where: { $0.contains("mtime_cutoff=$4") }))

    let unbounded = try runner.sourceSSHArguments(ccusageArguments: ["daily", "--json"], source: source)
    #expect(unbounded.contains("''"))
    #expect(!unbounded.contains("'202608220000'"))
  }
}
