import Foundation
import Testing
@testable import AppCore

private actor SourceFixtureRunner: CCUsageSourceCommandRunner {
  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    ProcessResult(stdout: Data(#"{"daily":[],"session":[]}"#.utf8), stderr: Data(), exitStatus: 0)
  }

  func run(
    arguments: [String],
    source: MachineSessionSource,
    timeoutSeconds: TimeInterval
  ) async throws -> ProcessResult {
    let cost = source.agent == .codex ? 1 : 2
    let json = """
      {"daily":[{"period":"2026-07-27","agents":[{"agent":"\(source.agent.rawValue)","modelBreakdowns":[{
        "modelName":"model-\(source.agent.rawValue)","cost":\(cost),"inputTokens":\(cost),
        "outputTokens":0,"cacheCreationTokens":0,"cacheReadTokens":0
      }]}]}],"session":[]}
      """
    return ProcessResult(stdout: Data(json.utf8), stderr: Data(), exitStatus: 0)
  }
}

private actor ProbeFixtureProcessRunner: CCUsageProcessRunning {
  private var outputs: [Data]
  private(set) var invocations: [[String]] = []

  init(outputs: [Data]) {
    self.outputs = outputs
  }

  func run(
    executable _: URL,
    arguments: [String],
    timeoutSeconds _: TimeInterval
  ) async throws -> ProcessResult {
    invocations.append(arguments)
    return ProcessResult(stdout: outputs.removeFirst(), stderr: Data(), exitStatus: 0)
  }
}

private actor SourcePlanSequence {
  private var plans: [MachineSessionSourcePlan]

  init(plans: [MachineSessionSourcePlan]) {
    self.plans = plans
  }

  func next() -> MachineSessionSourcePlan {
    plans.removeFirst()
  }
}

private struct EmptySnapshotRunner: CCUsageCommandRunner {
  func run(arguments: [String], timeoutSeconds _: TimeInterval) async throws -> ProcessResult {
    let output = arguments.first == "blocks"
      ? #"{"blocks":[]}"#
      : #"{"daily":[],"session":[]}"#
    return ProcessResult(stdout: Data(output.utf8), stderr: Data(), exitStatus: 0)
  }
}

@Suite("MultiSourceCommandTests")
struct MultiSourceCommandTests {
  @Test func mergesCodexAndClaudeSourcesUnderOneMachine() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let codexRoots = ["codex-a", "codex-b"].map { root.appendingPathComponent($0) }
    let claudeRoots = ["claude-a", "claude-b"].map { root.appendingPathComponent($0) }
    for codex in codexRoots {
      try FileManager.default.createDirectory(at: codex.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    }
    for claude in claudeRoots {
      try FileManager.default.createDirectory(at: claude.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }
    let descriptor = MachineDescriptor(
      id: "logical",
      displayName: "Logical",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user"),
      codexSessionDirs: codexRoots.map(\.path),
      claudeConfigDirs: claudeRoots.map(\.path),
      includeDefaultCodexDir: false,
      includeDefaultClaudeDir: false
    )
    let runner = MultiSourceCCUsageCommandRunner(runner: SourceFixtureRunner()) {
      MachineSessionSourcePlan(descriptor: descriptor)
    }
    let usage = try await CCUsageClient(commandRunner: runner, machine: descriptor.id).detailedUsage()
    #expect(usage.metrics.count == 4)
    #expect(usage.metrics.reduce(Decimal.zero) { $0 + $1.costUSD } == 6)
    #expect(Set(usage.metrics.map(\.machine)) == ["logical"])
  }

  @Test func remoteAdapterQuotesConfiguredPathsAsData() throws {
    let connection = SSHConnection(host: "localhost", port: 22, user: "user")
    let source = MachineSessionSource(
      agent: .codex,
      execution: .value(#"/srv/codex $(touch /tmp/unsafe)"#),
      resolvedRoot: "/srv/codex",
      scanScope: "/srv/codex/sessions",
      exists: true,
      isDirectory: true,
      isDefault: false
    )
    let arguments = try SSHCCUsageCommandRunner(connection: connection).sourceSSHArguments(
      ccusageArguments: ["daily", "--json"],
      source: source
    )
    #expect(!arguments.contains(#"/srv/codex $(touch /tmp/unsafe)"#))
    #expect(arguments.contains(#"'/srv/codex $(touch /tmp/unsafe)'"#))
    #expect(arguments.contains(where: { $0.contains("agent=$1") }))
  }

  @Test func cacheFingerprintMismatchPurgesPriorTotals() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = UsageAggregationCache(fileURL: root.appendingPathComponent("aggregate.sqlite3"))
    #expect(await cache.load(sourceConfigurationFingerprint: "source-a") == nil)
    try await cache.save(
      metrics: [],
      sessions: [],
      cachedFrom: "2026-07-01",
      cachedThrough: "2026-07-01"
    )
    #expect(await cache.load(sourceConfigurationFingerprint: "source-a") != nil)
    #expect(await cache.load(sourceConfigurationFingerprint: "source-b") == nil)
  }

  @Test func remoteProbeRebuildsMissingDefaultAndSymlinkStateForEveryAttempt() async throws {
    let descriptor = MachineDescriptor(
      id: "remote",
      displayName: "Remote",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user"),
      codexSessionDirs: ["~/codex//./"],
      includeDefaultCodexDir: true,
      includeDefaultClaudeDir: false
    )
    let firstOutput = probeData([
      ["codex", "1", "", "/home/user", "/home/user/sessions", "0", "0"],
      [
        "codex", "0", "/home/user/codex//./",
        "/home/user/volumes/../codex//.", "/home/user/volumes/../codex//./sessions", "0", "0"
      ]
    ])
    let secondOutput = probeData([
      ["codex", "1", "relative-codex", "/home/user/relative-codex", "/mnt/default/sessions", "1", "1"],
      ["codex", "0", "/home/user/codex//./", "/home/user/codex", "/mnt/container/sessions", "1", "1"]
    ])
    let process = ProbeFixtureProcessRunner(outputs: [firstOutput, secondOutput])
    let runner = try SSHCCUsageCommandRunner(
      connection: try #require(descriptor.ssh),
      processRunner: process
    )

    let first = try await runner.resolveSessionSourcePlan(descriptor: descriptor)
    let second = try await runner.resolveSessionSourcePlan(descriptor: descriptor)

    #expect(first.commandSources(for: .codex).isEmpty)
    #expect(first.codex.last?.scanScope == "/home/user/codex/sessions")
    #expect(second.commandSources(for: .codex).count == 2)
    #expect(second.codex.first?.execution == .value("relative-codex"))
    #expect(first.fingerprint != second.fingerprint)
    let invocations = await process.invocations
    #expect(invocations.count == 2)
    #expect(invocations[0].contains("'~/codex//./'"))
    #expect(invocations[0].contains(where: { $0.contains("emit_source") }))
  }

  @Test func cacheGenerationRejectsAnOlderAttemptAfterABAPlanChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = UsageAggregationCache(fileURL: root.appendingPathComponent("aggregate.sqlite3"))
    let firstA = await cache.beginSourceAttempt(sourceConfigurationFingerprint: "source-a")
    _ = await cache.beginSourceAttempt(sourceConfigurationFingerprint: "source-b")
    _ = await cache.beginSourceAttempt(sourceConfigurationFingerprint: "source-a")

    await #expect(throws: AggregationCacheSourcePlanError.staleGeneration) {
      try await cache.merge(
        metrics: [],
        sessions: [],
        coveredRange: AggregationCacheRange(since: "2026-07-01", through: "2026-07-01"),
        sourceConfigurationFingerprint: "source-a",
        sourceGeneration: firstA
      )
    }
  }

  @Test func remoteWithNoEffectiveSourcesSkipsSSHProbe() async throws {
    let descriptor = MachineDescriptor(
      id: "remote",
      displayName: "Remote",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user"),
      includeDefaultCodexDir: false,
      includeDefaultClaudeDir: false
    )
    let process = ProbeFixtureProcessRunner(outputs: [])
    let runner = try SSHCCUsageCommandRunner(
      connection: try #require(descriptor.ssh),
      processRunner: process
    )

    let plan = try await runner.resolveSessionSourcePlan(descriptor: descriptor)

    #expect(plan.codex.isEmpty)
    #expect(plan.claude.isEmpty)
    #expect(await process.invocations.isEmpty)
  }

  @Test func newerSourcePlanFencesOlderCollectionResult() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let descriptorA = MachineDescriptor(
      id: "local",
      displayName: "Local",
      kind: .local,
      enabled: true,
      codexSessionDirs: [root.appendingPathComponent("source-a").path],
      includeDefaultCodexDir: false,
      includeDefaultClaudeDir: false
    )
    let descriptorB = MachineDescriptor(
      id: "local",
      displayName: "Local",
      kind: .local,
      enabled: true,
      codexSessionDirs: [root.appendingPathComponent("source-b").path],
      includeDefaultCodexDir: false,
      includeDefaultClaudeDir: false
    )
    let sequence = SourcePlanSequence(plans: [
      MachineSessionSourcePlan(descriptor: descriptorA),
      MachineSessionSourcePlan(descriptor: descriptorB)
    ])
    let service = SnapshotService(
      stateStore: StateStore(fileURL: root.appendingPathComponent("state.json")),
      client: CCUsageClient(commandRunner: EmptySnapshotRunner(), machine: "local"),
      sourcePlanProvider: { await sequence.next() }
    )
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-27T12:00:00Z"))

    let first = try await service.collectionSnapshot(
      now: now,
      earliestDate: nil,
      latestDate: nil,
      progress: nil
    )
    let second = try await service.collectionSnapshot(
      now: now,
      earliestDate: nil,
      latestDate: nil,
      progress: nil
    )

    #expect(await service.isCurrentSourcePlan(first) == false)
    #expect(await service.isCurrentSourcePlan(second))

    let store = try MachineSnapshotStore(
      registry: MachineRegistry(),
      refreshIntervalSeconds: 60
    )
    let firstIdentity = try #require(first.sourceIdentity)
    let secondIdentity = try #require(second.sourceIdentity)
    await store.beginSourceAttempt(machineID: "local", identity: firstIdentity, revision: 0, generation: 0)
    await store.beginSourceAttempt(machineID: "local", identity: secondIdentity, revision: 0, generation: 0)
    await store.publish(
      machineID: "local",
      snapshot: first.snapshot,
      coverageStart: now,
      revision: 0,
      generation: 0,
      now: now,
      sourceIdentity: firstIdentity
    )
    #expect(await store.entry(machineID: "local")?.snapshot == nil)
    await store.publish(
      machineID: "local",
      snapshot: second.snapshot,
      coverageStart: now,
      revision: 0,
      generation: 0,
      now: now,
      sourceIdentity: secondIdentity
    )
    #expect(await store.entry(machineID: "local")?.snapshot != nil)
  }

  private func probeData(_ records: [[String]]) -> Data {
    Data((records.flatMap { $0 }.joined(separator: "\0") + "\0").utf8)
  }
}
