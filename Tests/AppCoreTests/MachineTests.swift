import Foundation
import Testing
@testable import AppCore

private struct StubProcessRunner: CCUsageProcessRunning {
  let result: Result<ProcessResult, ProcessExecutionFailure>

  func run(executable: URL, arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    try result.get()
  }
}

private struct StubCCUsageRunner: CCUsageCommandRunner {
  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    let payload: String
    switch arguments.first {
    case "blocks": payload = #"{"blocks":[]}"#
    case "daily": payload = #"{"daily":[]}"#
    case "session": payload = #"{"session":[]}"#
    case "--version": payload = "ccusage 1.0"
    default: throw CCUsageCommandFailure(runnerKind: .local, phase: .commandExited, exitStatus: 2)
    }
    return ProcessResult(stdout: Data(payload.utf8), stderr: Data(), exitStatus: 0)
  }
}

private actor SequencedCCUsageRunner: CCUsageCommandRunner {
  private var remainingFailures: Int
  private var observedTimeouts: [TimeInterval] = []

  init(failures: Int) {
    remainingFailures = failures
  }

  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    observedTimeouts.append(timeoutSeconds)
    if remainingFailures > 0 {
      remainingFailures -= 1
      throw CCUsageCommandFailure(runnerKind: .ssh, phase: .timedOut)
    }
    return ProcessResult(stdout: Data("ok".utf8), stderr: Data(), exitStatus: 0)
  }

  func observations() -> [TimeInterval] { observedTimeouts }
}

@Suite("SSHCommandRunnerTests") struct SSHCommandRunnerTests {
  @Test func usesSystemSSHExecutable() throws {
    let runner = try SSHCCUsageCommandRunner(connection: SSHConnection(host: "localhost", port: 22, user: "user"))
    #expect(runner.sshExecutable.path == "/usr/bin/ssh")
  }

  @Test func emitsCanonicalArgumentsAndQuotesEveryRemoteToken() throws {
    let connection = SSHConnection(
      host: "2001:db8::1",
      port: 2222,
      user: "ccusage",
      identityFile: "/tmp/id_ed25519",
      extraOptions: ["-4", "-o ConnectTimeout=10", "-o LogLevel=ERROR"],
      remoteCcusagePath: "/usr/local/bin/ccusage"
    )
    let runner = try SSHCCUsageCommandRunner(connection: connection)
    #expect(try runner.sshArguments(ccusageArguments: ["blocks", "--json", "a'b"]) == [
      "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
      "-i", "/tmp/id_ed25519", "-p", "2222", "-4", "-o", "ConnectTimeout=10",
      "-o", "LogLevel=ERROR", "--", "ccusage@[2001:db8::1]",
      "'/usr/local/bin/ccusage'", "'blocks'", "'--json'", "'a'\\''b'"
    ])
  }

  @Test(arguments: [
    "-J bastion", "-o ProxyCommand=anything", "-o RemoteCommand=sh", "-p 22",
    "-o ConnectTimeout=0", "-o LogLevel=DEBUG", "-o UserKnownHostsFile=relative"
  ])
  func rejectsUnlistedOrAlternateOptions(option: String) {
    #expect(throws: MachineValidationError.self) {
      try SSHCCUsageCommandRunner(connection: SSHConnection(
        host: "localhost", port: 22, user: "user", extraOptions: [option]
      ))
    }
  }

  @Test(arguments: [
    (CCUsageRunnerKind.local, ProcessResult(stdout: Data(), stderr: Data(), exitStatus: 9), CCUsageCommandFailurePhase.commandExited),
    (CCUsageRunnerKind.local, ProcessResult(stdout: Data(), stderr: Data(), exitStatus: 9, terminationReason: .uncaughtSignal), .signalled),
    (CCUsageRunnerKind.ssh, ProcessResult(stdout: Data(), stderr: Data(), exitStatus: 255), .transportExited),
    (CCUsageRunnerKind.ssh, ProcessResult(stdout: Data(), stderr: Data(), exitStatus: 1), .commandExited),
    (CCUsageRunnerKind.ssh, ProcessResult(stdout: Data(), stderr: Data(), exitStatus: 254), .commandExited)
  ])
  func classifiesProcessOutcomes(kind: CCUsageRunnerKind, result: ProcessResult, phase: CCUsageCommandFailurePhase) async throws {
    let process = StubProcessRunner(result: .success(result))
    do {
      if kind == .local {
        _ = try await LocalCCUsageCommandRunner(executable: URL(fileURLWithPath: "/bin/false"), processRunner: process)
          .run(arguments: [], timeoutSeconds: 1)
      } else {
        _ = try await SSHCCUsageCommandRunner(
          connection: SSHConnection(host: "localhost", port: 22, user: "user"),
          processRunner: process
        ).run(arguments: ["daily", "--json"], timeoutSeconds: 1)
      }
      Issue.record("Expected command failure")
    } catch let failure as CCUsageCommandFailure {
      #expect(failure.phase == phase)
      #expect(failure.runnerKind == kind)
    }
  }

  @Test(arguments: [ProcessExecutionFailure.spawnFailed, .timedOut])
  func preservesLaunchAndTimeoutFailures(failure: ProcessExecutionFailure) async throws {
    let runner = LocalCCUsageCommandRunner(
      executable: URL(fileURLWithPath: "/bin/false"),
      processRunner: StubProcessRunner(result: .failure(failure))
    )
    do {
      _ = try await runner.run(arguments: [], timeoutSeconds: 1)
      Issue.record("Expected command failure")
    } catch let command as CCUsageCommandFailure {
      #expect(command.phase == (failure == .spawnFailed ? .spawnFailed : .timedOut))
    }
  }

  @Test func remoteRetryDefaultsUseThreeRetriesAndFifteenSecondAttempts() async throws {
    let underlying = SequencedCCUsageRunner(failures: 3)
    let runner = RetryingCCUsageCommandRunner(runner: underlying)

    _ = try await runner.run(arguments: ["daily"], timeoutSeconds: 30)

    #expect(runner.retryCount == 3)
    #expect(runner.timeoutSeconds == 15)
    #expect(await underlying.observations() == [15, 15, 15, 15])
  }

  @Test func remoteRetryStopsAfterConfiguredRetryCount() async {
    let underlying = SequencedCCUsageRunner(failures: 4)
    let runner = RetryingCCUsageCommandRunner(runner: underlying, retryCount: 3, timeoutSeconds: 15)

    await #expect(throws: CCUsageCommandFailure.self) {
      _ = try await runner.run(arguments: ["daily"], timeoutSeconds: 30)
    }
    #expect(await underlying.observations() == [15, 15, 15, 15])
  }
}

@Suite("MachineRegistryTests") struct MachineRegistryTests {
  @Test func missingRegistrySynthesizesLocalAndCanonicalSaveIsDeterministic() throws {
    let root = try machineTemporaryDirectory()
    let directory = root.appendingPathComponent("config/ccusage-gauge", isDirectory: true)
    let file = directory.appendingPathComponent("machines.json")
    let store = MachineRegistryStore(fileURL: file)
    let empty = try store.load()
    #expect(empty.machines == [.local])
    let b = descriptor(id: "machine-b")
    let a = descriptor(id: "machine-a")
    try store.save(try MachineRegistry(sshMachines: [b, a]))
    let data = try Data(contentsOf: file)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.firstIndex(of: "a") != nil)
    #expect(text.range(of: "machine-a")!.lowerBound < text.range(of: "machine-b")!.lowerBound)
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try store.load().machines.map(\.id) == ["local", "machine-a", "machine-b"])
  }

  @Test func rejectsUnknownVersionFieldsAndUnsafePermissions() throws {
    let root = try machineTemporaryDirectory()
    let directory = root.appendingPathComponent("config/ccusage-gauge", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let file = directory.appendingPathComponent("machines.json")
    try Data(#"{"schemaVersion":2,"machines":[],"extra":true}"#.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(throws: MachineRegistryStoreError.registryLoadFailed) { try MachineRegistryStore(fileURL: file).load() }
    try Data(#"{"schemaVersion":1,"machines":[]}"#.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: MachineRegistryStoreError.registryPermissionsInvalid) { try MachineRegistryStore(fileURL: file).load() }
  }

  @Test func rejectsUnsafeExistingConfigurationDirectoryPermissions() throws {
    let root = try machineTemporaryDirectory()
    let directory = root.appendingPathComponent("config/ccusage-gauge", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

    let store = MachineRegistryStore(fileURL: directory.appendingPathComponent("machines.json"))
    #expect(throws: MachineRegistryStoreError.registryPermissionsInvalid) { try store.load() }
    let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o755)
  }

  @Test func migratesVersionOneToCanonicalVersionTwoWithoutChangingMachines() throws {
    let root = try machineTemporaryDirectory()
    let directory = root.appendingPathComponent("config/ccusage-gauge", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let file = directory.appendingPathComponent("machines.json")
    let original = #"""
    {"schemaVersion":1,"machines":[{
      "id":"remote","displayName":"Remote","kind":"ssh","enabled":true,
      "ssh":{"host":"localhost","port":22,"user":"user","extraOptions":[],"remoteCcusagePath":"ccusage"}
    }]}
    """#
    try Data(original.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

    let registry = try MachineRegistryStore(fileURL: file).load()
    let migrated = String(decoding: try Data(contentsOf: file), as: UTF8.self)

    #expect(registry.machines.map(\.id) == ["local", "remote"])
    #expect(migrated.contains(#""schemaVersion" : 2"#))
    #expect(try MachineRegistryStore(fileURL: file).load() == registry)
  }

  @Test(arguments: ["", "A", "-machine", "machine-", "a_b", "a.b", "all", "local"])
  func rejectsInvalidOrReservedIDs(id: String) {
    #expect(throws: MachineValidationError.self) { try MachineValidation.validate(descriptor: descriptor(id: id)) }
  }

  @Test func normalizesDisplayNamesAndRejectsControlCharacters() throws {
    #expect(try MachineValidation.normalizedDisplayName("  Cafe\u{301}  ") == "Café")
    #expect(throws: MachineValidationError.self) { try MachineValidation.normalizedDisplayName("bad\u{7f}") }
  }

  private func descriptor(id: String) -> MachineDescriptor {
    MachineDescriptor(
      id: id,
      displayName: id,
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "127.0.0.1", port: 22, user: "ccusage")
    )
  }
}

@Suite("MachineStatusTests") struct MachineStatusTests {
  @Test func derivesNeverCollectedErrorStaleAndDisabledPrecedence() async throws {
    let disabled = MachineDescriptor(
      id: "disabled", displayName: "Disabled", kind: .ssh, enabled: false,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user")
    )
    let registry = try MachineRegistry(sshMachines: [disabled])
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    var status = try await store.status(machine: "all", now: Date(timeIntervalSince1970: 100))
    #expect(status.machines.map(\.collectionState) == [.neverCollected, .disabled])
    await store.publishFailure(
      machineID: "local",
      error: CCUsageError.invalidJSON,
      revision: 0,
      generation: 0,
      now: Date(timeIntervalSince1970: 101)
    )
    status = try await store.status(machine: "local", now: Date(timeIntervalSince1970: 102))
    #expect(status.machines[0].collectionState == .error)
    #expect(status.machines[0].lastError == SanitizedCollectionError(
      code: "invalid_response",
      message: "ccusage response was invalid",
      detail: "ccusage returned an incompatible response.",
      remediation: "Verify the installed ccusage version and retry."
    ))
  }

  @Test func aggregatePreservesProvenanceAndUsesOldestGeneratedAt() async throws {
    let remote = MachineDescriptor(
      id: "remote", displayName: "Remote", kind: .ssh, enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user")
    )
    let registry = try MachineRegistry(sshMachines: [remote])
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    let local = snapshot(machine: "local", generatedAt: Date(timeIntervalSince1970: 100), cost: 1)
    let other = snapshot(machine: "remote", generatedAt: Date(timeIntervalSince1970: 90), cost: 2)
    await store.publish(machineID: "local", snapshot: local, coverageStart: local.activeBoundaryAt, revision: 0, generation: 0, now: local.generatedAt)
    await store.publish(machineID: "remote", snapshot: other, coverageStart: other.activeBoundaryAt, revision: 0, generation: 0, now: other.generatedAt)
    let selection = try await store.selection(machine: "all", now: Date(timeIntervalSince1970: 105))
    #expect(selection.scope.includedMachineIds == ["local", "remote"])
    #expect(selection.scope.generatedAt == other.generatedAt)
    #expect(Set(selection.snapshot!.dashboardMetrics.map(\.machine)) == ["local", "remote"])
  }

  @Test func selectedMachineSubsetOnlyMergesRequestedSnapshots() async throws {
    let remote = MachineDescriptor(
      id: "remote", displayName: "Remote", kind: .ssh, enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user")
    )
    let store = MachineSnapshotStore(
      registry: try MachineRegistry(sshMachines: [remote]),
      refreshIntervalSeconds: 20
    )
    let local = snapshot(machine: "local", generatedAt: Date(timeIntervalSince1970: 100), cost: 1)
    let other = snapshot(machine: "remote", generatedAt: Date(timeIntervalSince1970: 100), cost: 2)
    await store.publish(
      machineID: "local", snapshot: local, coverageStart: local.activeBoundaryAt,
      revision: 0, generation: 0, now: local.generatedAt
    )
    await store.publish(
      machineID: "remote", snapshot: other, coverageStart: other.activeBoundaryAt,
      revision: 0, generation: 0, now: other.generatedAt
    )

    let selection = try await store.selection(
      machineIDs: ["remote"],
      now: Date(timeIntervalSince1970: 105)
    )

    #expect(selection.scope.includedMachineIds == ["remote"])
    #expect(Set(selection.snapshot!.dashboardMetrics.map(\.machine)) == ["remote"])
  }

  @Test func currentSelectionExcludesStaleHistoryButHistoricalSelectionRetainsIt() async throws {
    let remote = MachineDescriptor(
      id: "remote", displayName: "Remote", kind: .ssh, enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user")
    )
    let store = MachineSnapshotStore(
      registry: try MachineRegistry(sshMachines: [remote]),
      refreshIntervalSeconds: 20
    )
    let local = snapshot(machine: "local", generatedAt: Date(timeIntervalSince1970: 195), cost: 1)
    let stale = snapshot(machine: "remote", generatedAt: Date(timeIntervalSince1970: 100), cost: 99)
    await store.publish(
      machineID: "local",
      snapshot: local,
      coverageStart: local.activeBoundaryAt,
      revision: 0,
      generation: 0,
      now: local.generatedAt
    )
    await store.publish(
      machineID: "remote",
      snapshot: stale,
      coverageStart: stale.activeBoundaryAt,
      revision: 0,
      generation: 0,
      now: stale.generatedAt
    )

    let current = try await store.selection(
      machine: "all",
      now: Date(timeIntervalSince1970: 200),
      dataDisposition: .current
    )
    let historical = try await store.selection(
      machine: "all",
      now: Date(timeIntervalSince1970: 200),
      dataDisposition: .historical
    )

    #expect(current.scope.includedMachineIds == ["local"])
    #expect(current.scope.excludedFromCurrentTotalsMachineIds == ["remote"])
    #expect(current.scope.staleMachineIds == ["remote"])
    #expect(current.snapshot?.costSinceResetUSD == 1)
    #expect(current.scope.lastHourDataGaps.map(\.machine) == ["remote"])
    #expect(historical.scope.includedMachineIds == ["local", "remote"])
    #expect(historical.snapshot?.costSinceResetUSD == 100)
    #expect(current.machineLatestEvents.first { $0.machine == "remote" }?.markerState == "stale")
  }

  private func snapshot(machine: String, generatedAt: Date, cost: Decimal) -> CostSnapshot {
    let metric = CCUsageMetricRecord(
      date: "1970-01-01", agent: "codex", model: "model", costUSD: cost,
      inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0, machine: machine
    )
    return CostSnapshot(
      generatedAt: generatedAt,
      activeBoundaryAt: Date(timeIntervalSince1970: 0),
      costSinceResetUSD: cost,
      budget: BudgetSummary(spentUSD: cost, budgetUSD: 10),
      resetCycle: .daily,
      points: [],
      dashboardMetrics: [metric]
    )
  }
}

@Suite("MachineProvenanceTests") struct MachineProvenanceTests {
  @Test func legacyMetricDecodeDefaultsLocalAndEncodingAlwaysEmitsMachine() throws {
    let data = Data(#"{"date":"2026-07-17","agent":"codex","model":"gpt","costUSD":1,"inputTokens":1,"outputTokens":2,"cacheCreationTokens":3,"cacheReadTokens":4,"totalTokens":10}"#.utf8)
    let decoded = try JSONDecoder().decode(CCUsageMetricRecord.self, from: data)
    #expect(decoded.machine == "local")
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
    #expect(encoded?["machine"] as? String == "local")
  }

  @Test func aggregationKeepsEqualRowsFromDifferentMachinesSeparate() throws {
    let now = Date()
    let eventTime = now.addingTimeInterval(-1)
    let local = CCUsageSessionMetricRecord(timestamp: eventTime, agent: "codex", model: "gpt", costUSD: 1, machine: "local")
    let remote = CCUsageSessionMetricRecord(timestamp: eventTime, agent: "codex", model: "gpt", costUSD: 2, machine: "remote")
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now.addingTimeInterval(-100),
      costSinceResetUSD: 3,
      budget: BudgetSummary(spentUSD: 3, budgetUSD: nil),
      resetCycle: .hourly,
      points: [],
      dashboardSessions: [local, remote]
    )
    let response = try DashboardQueryService().metrics(snapshot: snapshot, range: "recent12h", now: now)
    #expect(response.rows.count == 2)
    #expect(Set(response.rows.map(\.machine)) == ["local", "remote"])
  }
}

private actor CollectCountingRunner: CCUsageCommandRunner {
  private(set) var blocksCalls = 0

  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    let payload: String
    switch arguments.first {
    case "blocks": blocksCalls += 1; payload = #"{"blocks":[]}"#
    case "daily": payload = #"{"daily":[]}"#
    case "session": payload = #"{"session":[]}"#
    default: throw CCUsageCommandFailure(runnerKind: .local, phase: .commandExited, exitStatus: 2)
    }
    return ProcessResult(stdout: Data(payload.utf8), stderr: Data(), exitStatus: 0)
  }

  func collectCount() -> Int { blocksCalls }
}

private func aggregateSnapshot(machine: String, generatedAt: Date, cost: Decimal) -> CostSnapshot {
  CostSnapshot(
    generatedAt: generatedAt,
    activeBoundaryAt: Date(timeIntervalSince1970: 0),
    costSinceResetUSD: cost,
    budget: BudgetSummary(spentUSD: cost, budgetUSD: 10),
    resetCycle: .daily,
    points: [],
    dashboardMetrics: [CCUsageMetricRecord(
      date: "1970-01-01", agent: "codex", model: "model", costUSD: cost,
      inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0, machine: machine
    )]
  )
}

@Suite("CoverageAwareExpansionTests") struct CoverageAwareExpansionTests {
  @Test func activeMachineFilterScopesInitialAndManualRefresh() async throws {
    let remote = MachineDescriptor(
      id: "remote", displayName: "Remote", kind: .ssh, enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user")
    )
    let registry = try MachineRegistry(sshMachines: [remote])
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    let localRunner = CollectCountingRunner()
    let remoteRunner = CollectCountingRunner()
    let collector = try MachineCollector(registry: registry, store: store) { descriptor in
      SnapshotService(
        stateStore: StateStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        client: CCUsageClient(
          commandRunner: descriptor.id == "local" ? localRunner : remoteRunner,
          machine: descriptor.id
        ),
        aggregationCache: nil
      )
    }
    defer { Task { await collector.stop() } }

    await collector.start(machineIDs: ["local"])
    let localRefresh = await collector.refresh(machine: "all")
    await collector.setActiveMachineIDs(["remote"])
    let remoteRefresh = await collector.refresh(machine: "all")

    #expect(localRefresh.succeeded == ["local"])
    #expect(remoteRefresh.succeeded == ["remote"])
    #expect(await localRunner.collectCount() > 0)
    #expect(await remoteRunner.collectCount() > 0)
  }

  @Test func skipsCollectionWhenPublishedCoverageAlreadySatisfiesRequest() async throws {
    let registry = try MachineRegistry(sshMachines: [])
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    let runner = CollectCountingRunner()
    let collector = try MachineCollector(registry: registry, store: store) { descriptor in
      SnapshotService(
        stateStore: StateStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        client: CCUsageClient(commandRunner: runner, machine: descriptor.id),
        aggregationCache: nil
      )
    }
    defer { Task { await collector.stop() } }
    let wideCoverage = Date(timeIntervalSince1970: 0)
    await store.publish(
      machineID: "local", snapshot: aggregateSnapshot(machine: "local", generatedAt: Date(), cost: 1),
      coverageStart: wideCoverage, revision: 0, generation: 0, now: Date()
    )
    await collector.expand(machine: "all", earliestDate: Date(timeIntervalSince1970: 1_000_000))
    #expect(await runner.collectCount() == 0)
  }

  @Test func collectsExactlyOnceWhenWiderCoverageIsNeeded() async throws {
    let registry = try MachineRegistry(sshMachines: [])
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    let runner = CollectCountingRunner()
    let collector = try MachineCollector(registry: registry, store: store) { descriptor in
      SnapshotService(
        stateStore: StateStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        client: CCUsageClient(commandRunner: runner, machine: descriptor.id),
        aggregationCache: nil
      )
    }
    defer { Task { await collector.stop() } }
    let calendar = Calendar.current
    let narrowCoverage = calendar.startOfDay(for: Date())
    let earliest = try #require(calendar.date(byAdding: .day, value: -3, to: narrowCoverage))
    await store.publish(
      machineID: "local", snapshot: aggregateSnapshot(machine: "local", generatedAt: Date(), cost: 1),
      coverageStart: narrowCoverage, revision: 0, generation: 0, now: Date()
    )
    await collector.expand(machine: "all", earliestDate: earliest)
    #expect(await runner.collectCount() == 1)
    let widened = try #require(await store.entry(machineID: "local")?.coverageStart)
    #expect(widened <= earliest)
  }
}

@Suite("MergeMemoizationTests") struct MergeMemoizationTests {
  private func seededStore() async throws -> MachineSnapshotStore {
    let remote = MachineDescriptor(
      id: "remote", displayName: "Remote", kind: .ssh, enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user")
    )
    let registry = try MachineRegistry(sshMachines: [remote])
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    await store.publish(
      machineID: "local", snapshot: aggregateSnapshot(machine: "local", generatedAt: Date(timeIntervalSince1970: 100), cost: 1),
      coverageStart: Date(timeIntervalSince1970: 0), revision: 0, generation: 0, now: Date(timeIntervalSince1970: 100)
    )
    await store.publish(
      machineID: "remote", snapshot: aggregateSnapshot(machine: "remote", generatedAt: Date(timeIntervalSince1970: 90), cost: 2),
      coverageStart: Date(timeIntervalSince1970: 0), revision: 0, generation: 0, now: Date(timeIntervalSince1970: 90)
    )
    return store
  }

  @Test func consecutiveSelectionsReuseTheMergedArrays() async throws {
    let store = try await seededStore()
    let first = try await store.selection(machine: "all", now: Date(timeIntervalSince1970: 200))
    let second = try await store.selection(machine: "all", now: Date(timeIntervalSince1970: 300))
    #expect(await store.mergeComputations == 1)
    // Interval-dependent scalars are recomputed while the cached arrays are reused unchanged.
    #expect(first.snapshot?.dashboardMetrics == second.snapshot?.dashboardMetrics)
  }

  @Test func publishClearAndReplaceRegistryInvalidateTheMemo() async throws {
    let store = try await seededStore()
    _ = try await store.selection(machine: "all", now: Date(timeIntervalSince1970: 200))
    #expect(await store.mergeComputations == 1)
    await store.publish(
      machineID: "remote", snapshot: aggregateSnapshot(machine: "remote", generatedAt: Date(timeIntervalSince1970: 400), cost: 5),
      coverageStart: Date(timeIntervalSince1970: 0), revision: 0, generation: 0, now: Date(timeIntervalSince1970: 400)
    )
    _ = try await store.selection(machine: "all", now: Date(timeIntervalSince1970: 500))
    #expect(await store.mergeComputations == 2)
    await store.clear(machineID: "remote")
    _ = try await store.selection(machine: "all", now: Date(timeIntervalSince1970: 600))
    #expect(await store.mergeComputations == 3)
    let registry = try MachineRegistry(sshMachines: [])
    await store.replaceRegistry(registry, generations: [:])
    _ = try await store.selection(machine: "all", now: Date(timeIntervalSince1970: 700))
    #expect(await store.mergeComputations == 4)
  }
}

@Suite("RouterScopeEncodingTests") struct RouterScopeEncodingTests {
  private func iso8601Decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  @Test func scopedEndpointsEmitScopeSiblingInSinglePass() async throws {
    let runtime = try await routerRuntime()
    defer { Task { await runtime.collector.stop() } }
    await runtime.collector.store.publish(
      machineID: "local",
      snapshot: aggregateSnapshot(machine: "local", generatedAt: Date(), cost: 3),
      coverageStart: .distantPast,
      revision: 0,
      generation: 0,
      now: Date()
    )
    let targets = [
      "/api/recent?machine=all",
      "/api/day?date=1970-01-01&machine=all",
      "/api/period?range=today&machine=all",
      "/api/metrics?range=today&machine=all",
      "/api/cost-series?range=today&granularity=hourly&machine=all",
      "/api/budget?machine=all"
    ]
    for target in targets {
      let response = await runtime.router.route(
        target: target, method: "GET", headers: [:], body: Data(), listenerPort: 18_081
      )
      #expect(response.status == 200)
      let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
      let scope = try #require(object?["scope"] as? [String: Any])
      #expect(scope["requested"] as? String == "all")
      #expect(scope["includedMachineIds"] as? [String] == ["local"])
      #expect(scope["staleMachineIds"] as? [String] == [])
      #expect(scope["unavailableMachineIds"] as? [String] == [])
    }
    let budget = await runtime.router.route(
      target: "/api/budget?machine=all", method: "GET", headers: [:], body: Data(), listenerPort: 18_081
    )
    let decoded = try iso8601Decoder().decode(ScopedResponse<BudgetResponse>.self, from: budget.body)
    #expect(decoded.scope.requested == "all")
    #expect(decoded.scope.includedMachineIds == ["local"])
    #expect(decoded.body.budgetUSD == 10)
  }
}

@Suite("MutationPolicyTests") struct MutationPolicyTests {
  @Test func machineDashboardRouterPersistsStateUsingItsApplicationPaths() async throws {
    let runtime = try await routerRuntime()
    defer { Task { await runtime.collector.stop() } }
    let body = Data(
      #"""
      {"range":"month","customStart":"2026-07-01","customEnd":"2026-07-21","selectedModels":["gpt-5"],
      "selectedAgents":["codex"],"selectedMachines":["local"],"granularity":"daily","chartMetric":"costUSD","stackBy":"machine"}
      """#.utf8
    )

    let saved = await runtime.router.route(
      target: "/api/dashboard-state",
      method: "PUT",
      headers: mutationHeaders,
      body: body,
      listenerPort: 18_081
    )
    let reloaded = await runtime.router.route(
      target: "/api/dashboard-state",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    let decoded = try JSONDecoder().decode(DashboardUIStateResponse.self, from: reloaded.body)

    #expect(saved.status == 200)
    #expect(reloaded.status == 200)
    #expect(decoded.state?.selectedMachines == ["local"])
    #expect(decoded.state?.stackBy == "machine")
    #expect(FileManager.default.fileExists(atPath: runtime.paths.dashboardStateFile.path))
  }

  @Test func rejectedMutationDoesNotChangeRegistryAndAllowedMutationPersistsBeforeResponse() async throws {
    let runtime = try await routerRuntime()
    defer { Task { await runtime.collector.stop() } }
    let body = Data(#"{"id":"remote","displayName":"Remote","kind":"ssh","enabled":false,"ssh":{"host":"localhost","port":22,"user":"ccusage"}}"#.utf8)
    let rejected = await runtime.router.route(
      target: "/api/machines",
      method: "POST",
      headers: ["host": "127.0.0.1:18081", "content-type": "application/json"],
      body: body,
      listenerPort: 18_081
    )
    #expect(rejected.status == 403)
    #expect((await runtime.owner.current()).machines.map(\.id) == ["local"])

    let accepted = await runtime.router.route(
      target: "/api/machines",
      method: "POST",
      headers: mutationHeaders,
      body: body,
      listenerPort: 18_081
    )
    #expect(accepted.status == 201)
    #expect(accepted.headers["Location"] == "/api/machines/remote")
    #expect((await runtime.owner.current()).machines.map(\.id) == ["local", "remote"])
    #expect(FileManager.default.fileExists(atPath: runtime.paths.machinesFile.path))
  }

  @Test func browserOriginMustMatchServedLoopbackOrigin() async throws {
    let runtime = try await routerRuntime()
    defer { Task { await runtime.collector.stop() } }
    let crossSite = await runtime.router.route(
      target: "/api/refresh?machine=local",
      method: "GET",
      headers: mutationHeaders.merging([
        "origin": "http://localhost:9999",
        "sec-fetch-site": "same-site"
      ]) { _, new in new },
      body: Data(),
      listenerPort: 18_081
    )
    #expect(crossSite.status == 403)
    let preflight = await runtime.router.route(
      target: "/api/refresh?machine=local",
      method: "OPTIONS",
      headers: mutationHeaders,
      body: Data(),
      listenerPort: 18_081
    )
    #expect(preflight.status == 403)
    #expect(preflight.headers["Access-Control-Allow-Origin"] == nil)
  }

  @Test func machineActionsReloadValidRegistryWithoutRestartAndRefreshTarget() async throws {
    let runtime = try await routerRuntime()
    defer { Task { await runtime.collector.stop() } }
    let body = Data(
      #"{"id":"remote","displayName":"Remote","kind":"ssh","enabled":true,"ssh":{"host":"localhost","port":22,"user":"ccusage"}}"#.utf8
    )
    let created = await runtime.router.route(
      target: "/api/machines",
      method: "POST",
      headers: mutationHeaders,
      body: body,
      listenerPort: 18_081
    )
    #expect(created.status == 201)

    var persisted = String(decoding: try Data(contentsOf: runtime.paths.machinesFile), as: UTF8.self)
    persisted = persisted.replacingOccurrences(of: #""displayName" : "Remote""#, with: #""displayName" : "Edited""#)
    try Data(persisted.utf8).write(to: runtime.paths.machinesFile, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: runtime.paths.machinesFile.path
    )

    let tested = await runtime.router.route(
      target: "/api/machines/remote/test-connection",
      method: "POST",
      headers: mutationHeaders,
      body: Data("{}".utf8),
      listenerPort: 18_081
    )
    let testPayload = try DashboardAPIClient.makeDecoder()
      .decode(MachineConnectionTestResponse.self, from: tested.body)
    #expect(tested.status == 200)
    #expect(testPayload.status == "reachable")
    #expect((await runtime.owner.current()).machine(id: "remote")?.displayName == "Edited")

    let refreshed = await runtime.router.route(
      target: "/api/machines/remote/refresh",
      method: "POST",
      headers: mutationHeaders,
      body: Data("{}".utf8),
      listenerPort: 18_081
    )
    let refreshPayload = try DashboardAPIClient.makeDecoder()
      .decode(RefreshResponse.self, from: refreshed.body)
    #expect(refreshed.status == 200)
    #expect(refreshPayload.status == "ok")
    #expect(refreshPayload.refreshedMachineIds == ["remote"])
  }

  @Test func machineCRUDSupportsCompleteReplacementPatchAndDelete() async throws {
    let runtime = try await routerRuntime()
    defer { Task { await runtime.collector.stop() } }
    let created = await runtime.router.route(
      target: "/api/machines",
      method: "POST",
      headers: mutationHeaders,
      body: Data(
        #"{"id":"remote","displayName":"Remote","kind":"ssh","enabled":true,"ssh":{"host":"target.example","port":22,"user":"ccusage","extraOptions":[],"proxy":{"kind":"direct"},"remoteCcusagePath":"ccusage"}}"#.utf8
      ),
      listenerPort: 18_081
    )
    #expect(created.status == 201)

    let replaced = await runtime.router.route(
      target: "/api/machines/remote",
      method: "PUT",
      headers: mutationHeaders,
      body: Data(
        #"{"displayName":"Via jump","kind":"ssh","enabled":true,"ssh":{"host":"target.example","port":2222,"user":"worker","extraOptions":[],"proxy":{"kind":"jump","host":"jump.example","port":2200,"user":"jump"},"remoteCcusagePath":"/usr/local/bin/ccusage"}}"#.utf8
      ),
      listenerPort: 18_081
    )
    try #require(replaced.status == 200)
    let replacement = try JSONDecoder().decode(MachineDescriptor.self, from: replaced.body)
    #expect(replacement.displayName == "Via jump")
    #expect(replacement.ssh?.proxy == .jump(SSHJumpProxy(
      host: "jump.example",
      port: 2200,
      user: "jump"
    )))

    let proxyExecutable = runtime.paths.machinesFile.deletingLastPathComponent()
      .appendingPathComponent("test-tunnel")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: proxyExecutable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: proxyExecutable.path)
    let patched = await runtime.router.route(
      target: "/api/machines/remote",
      method: "PATCH",
      headers: mutationHeaders,
      body: Data("""
        {"displayName":"Via command","ssh":{"host":"target.example","port":22,"user":"worker","extraOptions":[],
        "proxy":{"kind":"command","executable":"\(proxyExecutable.path)"},"remoteCcusagePath":"ccusage"}}
        """.utf8),
      listenerPort: 18_081
    )
    try #require(patched.status == 200)
    let patch = try JSONDecoder().decode(MachineDescriptor.self, from: patched.body)
    #expect(patch.displayName == "Via command")
    #expect(patch.ssh?.proxy == .command(executable: proxyExecutable.path))

    let listed = await runtime.router.route(
      target: "/api/machines", method: "GET", headers: [:], body: Data(), listenerPort: 18_081
    )
    let shown = await runtime.router.route(
      target: "/api/machines/remote", method: "GET", headers: [:], body: Data(), listenerPort: 18_081
    )
    #expect(listed.status == 200)
    #expect(shown.status == 200)

    let deleted = await runtime.router.route(
      target: "/api/machines/remote",
      method: "DELETE",
      headers: mutationHeaders,
      body: Data(),
      listenerPort: 18_081
    )
    #expect(deleted.status == 204)
    #expect((await runtime.owner.current()).machine(id: "remote") == nil)
    #expect(await runtime.router.route(
      target: "/api/machines/remote", method: "GET", headers: [:], body: Data(), listenerPort: 18_081
    ).status == 404)
  }

  @Test func mutationRoutesRejectMalformedRequestsAndUnsupportedMethods() async throws {
    let runtime = try await routerRuntime()
    defer { Task { await runtime.collector.stop() } }
    let validBody = Data(
      #"{"id":"remote","displayName":"Remote","kind":"ssh","enabled":false,"ssh":{"host":"localhost","port":22,"user":"ccusage"}}"#.utf8
    )
    #expect(await runtime.router.route(
      target: "/api/machines", method: "PUT", headers: mutationHeaders, body: validBody, listenerPort: 18_081
    ).status == 405)
    #expect(await runtime.router.route(
      target: "/api/machines", method: "POST",
      headers: mutationHeaders.merging(["content-type": "text/plain"]) { _, new in new },
      body: validBody, listenerPort: 18_081
    ).status == 415)
    #expect(await runtime.router.route(
      target: "/api/machines/%72emote", method: "GET", headers: [:], body: Data(), listenerPort: 18_081
    ).status == 400)
    #expect(await runtime.router.route(
      target: "/api/machines", method: "POST", headers: mutationHeaders,
      body: Data(#"{"id":"remote"}"#.utf8), listenerPort: 18_081
    ).status == 400)
    #expect(await runtime.router.route(
      target: "/api/dashboard-state", method: "PUT", headers: mutationHeaders,
      body: Data("{}".utf8), listenerPort: 18_081
    ).status == 400)
    #expect(await runtime.router.route(
      target: "/api/chart-colors", method: "POST", headers: [:], body: Data(), listenerPort: 18_081
    ).status == 405)
  }

  @Test func refreshCacheAndSelectionErrorsUseDocumentedResponses() async throws {
    let runtime = try await routerRuntime()
    defer { Task { await runtime.collector.stop() } }
    let refreshed = await runtime.router.route(
      target: "/api/refresh?machine=local",
      method: "GET",
      headers: mutationHeaders,
      body: Data(),
      listenerPort: 18_081
    )
    #expect(refreshed.status == 200)

    let cache = runtime.paths.aggregationCacheFile(forMachine: "local")
    try FileManager.default.createDirectory(
      at: cache.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("cache".utf8).write(to: cache)
    let cleared = await runtime.router.route(
      target: "/api/cache?machine=local",
      method: "DELETE",
      headers: mutationHeaders,
      body: Data(),
      listenerPort: 18_081
    )
    #expect(cleared.status == 200)
    #expect(!FileManager.default.fileExists(atPath: cache.path))

    #expect(await runtime.router.route(
      target: "/api/cache", method: "POST", headers: mutationHeaders, body: Data(), listenerPort: 18_081
    ).status == 405)
    #expect(await runtime.router.route(
      target: "/api/refresh?machine=missing", method: "GET", headers: mutationHeaders,
      body: Data(), listenerPort: 18_081
    ).status == 404)
    #expect(await runtime.router.route(
      target: "/api/machine-status?machine=missing", method: "GET", headers: [:],
      body: Data(), listenerPort: 18_081
    ).status == 404)
    #expect(await runtime.router.route(
      target: "/api/machine-status?machine=bad%20id", method: "GET", headers: [:],
      body: Data(), listenerPort: 18_081
    ).status == 400)
  }

  @Test func queryRoutesValidateDatesRangesGranularityAndUnknownPaths() async throws {
    let runtime = try await routerRuntime()
    defer { Task { await runtime.collector.stop() } }
    await runtime.collector.store.publish(
      machineID: "local",
      snapshot: aggregateSnapshot(machine: "local", generatedAt: Date(), cost: 3),
      coverageStart: .distantPast,
      revision: 0,
      generation: 0,
      now: Date()
    )
    let statuses: [(String, Int)] = [
      ("/api/health", 200),
      ("/api/day?machine=local", 400),
      ("/api/period?range=custom&start=2026-07-01&machine=local", 400),
      ("/api/period?range=custom&start=2026-07-01&end=2026-07-02&machine=local", 200),
      ("/api/metrics?range=custom&start=2026-07-01&end=2026-07-02&machine=local", 200),
      ("/api/cost-series?range=custom&start=2026-07-01&end=2026-07-02&granularity=daily&machine=local", 200),
      ("/api/period?range=invalid&machine=local", 400),
      ("/api/cost-series?range=today&granularity=invalid&machine=local", 400),
      ("/api/unknown?machine=local", 404)
    ]
    for (target, expected) in statuses {
      #expect(await runtime.router.route(
        target: target, method: "GET", headers: [:], body: Data(), listenerPort: 18_081
      ).status == expected)
    }
  }

  private var mutationHeaders: [String: String] {
    [
      "host": "127.0.0.1:18081",
      "content-type": "application/json",
      "x-ccusage-gauge-mutation": "1"
    ]
  }
}

private struct RouterRuntime {
  let router: MachineDashboardRouter
  let collector: MachineCollector
  let owner: MachineRegistryMutationOwner
  let paths: AppPaths
}

private func routerRuntime(chartColors: ChartColorConfiguration = ChartColorConfiguration()) async throws -> RouterRuntime {
  let root = try machineTemporaryDirectory()
  let paths = AppPaths(
    configFile: root.appendingPathComponent("config/ccusage-gauge/ccusage-config.json"),
    stateFile: root.appendingPathComponent("state/ccusage-gauge/state.json"),
    aggregationCacheFile: root.appendingPathComponent("cache/ccusage-gauge/aggregates.sqlite3")
  )
  let registryStore = MachineRegistryStore(fileURL: paths.machinesFile)
  let registry = try registryStore.load()
  let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
  let stateStore = StateStore(fileURL: paths.stateFile)
  let collector = try MachineCollector(
    registry: registry,
    store: store,
    connectionTester: { _ in }
  ) { descriptor in
    SnapshotService(
      stateStore: stateStore,
      client: CCUsageClient(commandRunner: StubCCUsageRunner(), machine: descriptor.id),
      aggregationCache: nil
    )
  }
  let owner = MachineRegistryMutationOwner(store: registryStore, registry: registry, runtime: collector)
  return RouterRuntime(
    router: MachineDashboardRouter(store: store, collector: collector, mutationOwner: owner, paths: paths, chartColors: chartColors),
    collector: collector,
    owner: owner,
    paths: paths
  )
}

@Suite("ChartColorRouteTests") struct ChartColorRouteTests {
  @Test func exposesConfiguredMachineAndModelOverrides() async throws {
    let colors = ChartColorConfiguration(
      light: ChartColorSchemeConfiguration(machines: ["local": "#123ABC"]),
      dark: ChartColorSchemeConfiguration(models: ["gpt-next": "#abcdef"])
    )
    let runtime = try await routerRuntime(chartColors: colors)
    defer { Task { await runtime.collector.stop() } }

    let response = await runtime.router.route(
      target: "/api/chart-colors", method: "GET", headers: [:], body: Data(), listenerPort: 18_081
    )

    #expect(response.status == 200)
    #expect(try JSONDecoder().decode(ChartColorConfiguration.self, from: response.body) == colors)
  }
}

private func machineTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
