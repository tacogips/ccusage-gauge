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
    default: throw CCUsageCommandFailure(runnerKind: .local, phase: .commandExited, exitStatus: 2)
    }
    return ProcessResult(stdout: Data(payload.utf8), stderr: Data(), exitStatus: 0)
  }
}

@Suite("SSHCommandRunnerTests") struct SSHCommandRunnerTests {
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
    #expect(status.machines[0].lastError == SanitizedCollectionError(code: "invalid_response", message: "ccusage response was invalid"))
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

@Suite("MutationPolicyTests") struct MutationPolicyTests {
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

private func routerRuntime() async throws -> RouterRuntime {
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
  let collector = try MachineCollector(registry: registry, store: store) { descriptor in
    SnapshotService(
      stateStore: stateStore,
      client: CCUsageClient(commandRunner: StubCCUsageRunner(), machine: descriptor.id),
      aggregationCache: nil
    )
  }
  let owner = MachineRegistryMutationOwner(store: registryStore, registry: registry)
  return RouterRuntime(
    router: MachineDashboardRouter(store: store, collector: collector, mutationOwner: owner, paths: paths),
    collector: collector,
    owner: owner,
    paths: paths
  )
}

private func machineTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
