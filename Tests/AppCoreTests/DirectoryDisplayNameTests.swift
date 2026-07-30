import CSQLite
import Foundation
import Testing
@testable import AppCore

@Suite("Dashboard directory display-name persistence")
struct DirectoryDisplayNameStoreTests {
  @Test func setOverwriteClearAndReopenRoundTrip() async throws {
    let file = try displayNameTemporaryDirectory()
      .appendingPathComponent("dashboard-state.sqlite3")
    let store = DashboardDirectoryNameStore(fileURL: file)

    #expect(try await store.setName(
      machine: "local",
      directory: "/work/project",
      name: "  Billing  "
    ) == "Billing")
    #expect(try await store.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Remote"
    ) == "Remote")
    #expect(try await store.setName(
      machine: "local",
      directory: "/work/project",
      name: "Accounts"
    ) == "Accounts")

    let reopened = DashboardDirectoryNameStore(fileURL: file)
    #expect(try await reopened.names(machineIDs: ["local", "remote"]) == [
      "local": ["/work/project": "Accounts"],
      "remote": ["/srv/project": "Remote"]
    ])

    #expect(try await reopened.setName(
      machine: "local",
      directory: "/work/project",
      name: " \n "
    ) == nil)
    #expect(try await reopened.names(machineIDs: ["local"]) == [:])
  }

  @Test func rejectsInvalidKeysAndNamesBeforeMutation() async throws {
    let store = DashboardDirectoryNameStore(
      fileURL: try displayNameTemporaryDirectory().appendingPathComponent("state.sqlite3")
    )

    await #expect(throws: DashboardDirectoryNameError.invalidInput) {
      try await store.setName(machine: "Invalid ID", directory: "/work/a", name: "Name")
    }
    await #expect(throws: DashboardDirectoryNameError.invalidInput) {
      try await store.setName(machine: "local", directory: "", name: "Name")
    }
    await #expect(throws: DashboardDirectoryNameError.invalidInput) {
      try await store.setName(machine: "local", directory: "/work/a", name: "Line\nBreak")
    }
    await #expect(throws: DashboardDirectoryNameError.invalidInput) {
      try await store.setName(
        machine: "local",
        directory: "/work/a",
        name: String(repeating: "a", count: 201)
      )
    }
    #expect(try await store.names(machineIDs: ["local"]) == [:])
  }

  @Test func embeddedNullDirectoryKeysRemainDistinct() async throws {
    let store = DashboardDirectoryNameStore(
      fileURL: try displayNameTemporaryDirectory().appendingPathComponent("state.sqlite3")
    )
    let plainDirectory = "/work/project"
    let nullSuffixedDirectory = "/work/project\u{0}other"

    _ = try await store.setName(
      machine: "local",
      directory: plainDirectory,
      name: "Plain"
    )
    _ = try await store.setName(
      machine: "local",
      directory: nullSuffixedDirectory,
      name: "Opaque"
    )
    #expect(try await store.names(machineIDs: ["local"]) == [
      "local": [
        plainDirectory: "Plain",
        nullSuffixedDirectory: "Opaque"
      ]
    ])

    _ = try await store.setName(
      machine: "local",
      directory: nullSuffixedDirectory,
      name: nil
    )
    #expect(try await store.names(machineIDs: ["local"]) == [
      "local": [plainDirectory: "Plain"]
    ])
  }

  @Test func dashboardStateLoadWaitsForSharedDatabaseWriter() async throws {
    let file = try displayNameTemporaryDirectory().appendingPathComponent("state.sqlite3")
    let store = DashboardStateStore(fileURL: file)
    let expected = displayNameDashboardState()
    try await store.save(expected)

    var database: OpaquePointer?
    #expect(sqlite3_open_v2(
      file.path,
      &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    ) == SQLITE_OK)
    let lockedDatabase = try #require(database)
    defer { sqlite3_close(lockedDatabase) }
    #expect(sqlite3_exec(
      lockedDatabase,
      "BEGIN EXCLUSIVE",
      nil,
      nil,
      nil
    ) == SQLITE_OK)

    let startHandshake = DirectoryNameTaskStartHandshake()
    let loadTask = Task {
      await startHandshake.markStarted()
      return try await store.load()
    }
    await startHandshake.waitUntilStarted()
    await Task.yield()
    #expect(sqlite3_exec(lockedDatabase, "COMMIT", nil, nil, nil) == SQLITE_OK)
    #expect(try await loadTask.value == expected)
  }

  @Test func machineDeletionMarkersHideRestoreAndPurgeNames() async throws {
    let store = DashboardDirectoryNameStore(
      fileURL: try displayNameTemporaryDirectory().appendingPathComponent("state.sqlite3")
    )
    _ = try await store.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Original"
    )

    try await store.prepareMachineDeletion(machineID: "remote")
    #expect(try await store.names(machineIDs: ["remote"]) == [:])

    try await store.cancelMachineDeletion(machineID: "remote")
    #expect(try await store.names(machineIDs: ["remote"]) == [
      "remote": ["/srv/project": "Original"]
    ])

    try await store.prepareMachineDeletion(machineID: "remote")
    try await store.commitMachineDeletion(machineID: "remote")
    #expect(await store.finalizeMachineDeletion(machineID: "remote"))
    #expect(try await store.names(machineIDs: ["remote"]) == [:])

    try await store.prepareMachineCreation(machineID: "remote")
    _ = try await store.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Replacement"
    )
    #expect(try await store.names(machineIDs: ["remote"]) == [
      "remote": ["/srv/project": "Replacement"]
    ])
  }

  @Test func deletionMarkerRejectsStaleNameMutationsUntilRollback() async throws {
    let store = DashboardDirectoryNameStore(
      fileURL: try displayNameTemporaryDirectory().appendingPathComponent("state.sqlite3")
    )
    _ = try await store.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Original"
    )
    try await store.prepareMachineDeletion(machineID: "remote")

    await #expect(throws: DashboardDirectoryNameError.machineDeletionPending) {
      try await store.setName(
        machine: "remote",
        directory: "/srv/project",
        name: "Stale"
      )
    }
    #expect(try await store.names(machineIDs: ["remote"]) == [:])

    try await store.cancelMachineDeletion(machineID: "remote")
    #expect(try await store.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Recovered"
    ) == "Recovered")
  }

  @Test func startupReconciliationRepairsInterruptedDeletionMarkers() async throws {
    let fileURL = try displayNameTemporaryDirectory().appendingPathComponent("state.sqlite3")
    let interruptedStore = DashboardDirectoryNameStore(fileURL: fileURL)
    _ = try await interruptedStore.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Original"
    )
    try await interruptedStore.prepareMachineDeletion(machineID: "remote")
    #expect(try await interruptedStore.names(machineIDs: ["remote"]) == [:])

    let restartedStore = DashboardDirectoryNameStore(fileURL: fileURL)
    try await restartedStore.reconcileMachineRegistry(machineIDs: ["local", "remote"])
    #expect(try await restartedStore.names(machineIDs: ["remote"]) == [
      "remote": ["/srv/project": "Original"]
    ])
    _ = try await restartedStore.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Recovered"
    )
    #expect(try await restartedStore.names(machineIDs: ["remote"]) == [
      "remote": ["/srv/project": "Recovered"]
    ])
  }

  @Test func startupReconciliationFinalizesCommittedDeletionBeforeIDReuse() async throws {
    let fileURL = try displayNameTemporaryDirectory().appendingPathComponent("state.sqlite3")
    let interruptedStore = DashboardDirectoryNameStore(fileURL: fileURL)
    _ = try await interruptedStore.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Deleted"
    )
    try await interruptedStore.prepareMachineDeletion(machineID: "remote")

    let restartedStore = DashboardDirectoryNameStore(fileURL: fileURL)
    try await restartedStore.reconcileMachineRegistry(machineIDs: ["local"])
    try await restartedStore.reconcileMachineRegistry(machineIDs: ["local", "remote"])
    #expect(try await restartedStore.names(machineIDs: ["remote"]) == [:])
  }

  @Test func startupReconciliationPurgesCommittedDeletionBeforeExternalIDReuse() async throws {
    let fileURL = try displayNameTemporaryDirectory().appendingPathComponent("state.sqlite3")
    let interruptedStore = DashboardDirectoryNameStore(fileURL: fileURL)
    _ = try await interruptedStore.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Deleted"
    )
    try await interruptedStore.prepareMachineDeletion(machineID: "remote")
    try await interruptedStore.commitMachineDeletion(machineID: "remote")

    let restartedStore = DashboardDirectoryNameStore(fileURL: fileURL)
    try await restartedStore.reconcileMachineRegistry(machineIDs: ["local", "remote"])

    #expect(try await restartedStore.names(machineIDs: ["remote"]) == [:])
    #expect(try await restartedStore.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Replacement"
    ) == "Replacement")
  }

  @Test func startupReconciliationPreservesNamesForInterruptedRollback() async throws {
    let fileURL = try displayNameTemporaryDirectory().appendingPathComponent("state.sqlite3")
    let interruptedStore = DashboardDirectoryNameStore(fileURL: fileURL)
    _ = try await interruptedStore.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Original"
    )
    try await interruptedStore.prepareMachineDeletion(machineID: "remote")
    try await interruptedStore.commitMachineDeletion(machineID: "remote")
    try await interruptedStore.prepareMachineDeletionRollback(machineID: "remote")

    let restartedStore = DashboardDirectoryNameStore(fileURL: fileURL)
    try await restartedStore.reconcileMachineRegistry(machineIDs: ["local", "remote"])

    #expect(try await restartedStore.names(machineIDs: ["remote"]) == [
      "remote": ["/srv/project": "Original"]
    ])
  }

  @Test func legacyDeletionMarkersMigrateAsPreparedRecoveryState() async throws {
    let fileURL = try displayNameTemporaryDirectory().appendingPathComponent("state.sqlite3")
    var database: OpaquePointer?
    #expect(sqlite3_open(fileURL.path, &database) == SQLITE_OK)
    guard let database else {
      Issue.record("Could not create legacy directory-name database")
      return
    }
    defer { sqlite3_close(database) }
    let legacySchema = """
      CREATE TABLE dashboard_directory_names (
        machine_id TEXT NOT NULL,
        directory TEXT NOT NULL,
        display_name TEXT NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY(machine_id, directory)
      );
      CREATE TABLE dashboard_directory_name_machine_deletions (
        machine_id TEXT PRIMARY KEY,
        deleted_at REAL NOT NULL
      );
      INSERT INTO dashboard_directory_names
        (machine_id, directory, display_name, updated_at)
      VALUES ('remote', '/srv/project', 'Original', 0);
      INSERT INTO dashboard_directory_name_machine_deletions
        (machine_id, deleted_at)
      VALUES ('remote', 0);
      """
    #expect(sqlite3_exec(database, legacySchema, nil, nil, nil) == SQLITE_OK)

    let store = DashboardDirectoryNameStore(fileURL: fileURL)
    try await store.reconcileMachineRegistry(machineIDs: ["local", "remote"])

    #expect(try await store.names(machineIDs: ["remote"]) == [
      "remote": ["/srv/project": "Original"]
    ])
  }

  @Test func payloadFiltersUndiscoveredNamesAndOldPayloadDecodes() throws {
    let snapshot = displayNameSnapshot(
      machineDirectories: [
        ("local", "/work/discovered"),
        ("remote", "/srv/discovered")
      ]
    )
    let response = subdirectoriesResponse(
      snapshot: snapshot,
      machineIDs: ["local", "remote"],
      namesByMachine: [
        "local": [
          "/work/discovered": "Visible",
          "/work/undiscovered": "Retained"
        ]
      ]
    )

    #expect(response.machines == [
      MachineSubdirectories(
        machine: "local",
        directories: ["/work/discovered"],
        names: ["/work/discovered": "Visible"]
      ),
      MachineSubdirectories(machine: "remote", directories: ["/srv/discovered"])
    ])

    let oldPayload = Data(
      #"{"machines":[{"machine":"local","directories":["/work/discovered"]}]}"#.utf8
    )
    let decoded = try JSONDecoder().decode(SubdirectoriesResponse.self, from: oldPayload)
    #expect(decoded.machines.first?.names == nil)
  }
}

@Suite("Dashboard directory display-name routes")
struct DirectoryDisplayNameRouteTests {
  @Test func localRouteSetsClearsAndReflectsNames() async throws {
    let root = try displayNameTemporaryDirectory()
    let nameStore = DashboardDirectoryNameStore(
      fileURL: root.appendingPathComponent("dashboard-state.sqlite3")
    )
    let router = DashboardRouter(
      snapshotProvider: {
        displayNameSnapshot(machineDirectories: [("local", "/work/project")])
      },
      assetResolver: StaticAssetResolver(explicitRoot: root),
      directoryNameStore: nameStore
    )

    let setResponse = await router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: mutationHeaders(),
      body: requestBody(machine: "local", directory: "/work/project", name: " Billing ")
    )
    #expect(setResponse.status == 200)
    #expect(try responseObject(setResponse)["name"] as? String == "Billing")

    let inventory = await router.route(target: "/api/subdirectories")
    let payload = try JSONDecoder().decode(SubdirectoriesResponse.self, from: inventory.body)
    #expect(payload.machines.first?.names == ["/work/project": "Billing"])

    let undiscovered = await router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: mutationHeaders(),
      body: requestBody(machine: "local", directory: "/work/hidden", name: "Hidden")
    )
    #expect(undiscovered.status == 200)
    let filteredInventory = await router.route(target: "/api/subdirectories")
    let filteredPayload = try JSONDecoder().decode(
      SubdirectoriesResponse.self,
      from: filteredInventory.body
    )
    #expect(filteredPayload.machines.first?.names == ["/work/project": "Billing"])

    let clearResponse = await router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: mutationHeaders(),
      body: requestBody(machine: "local", directory: "/work/project", name: nil)
    )
    #expect(clearResponse.status == 200)
    #expect(try responseObject(clearResponse)["name"] is NSNull)
    #expect(try await nameStore.names(machineIDs: ["local"]) == [
      "local": ["/work/hidden": "Hidden"]
    ])
  }

  @Test func localRouteValidatesAndGuardsBeforeDecodeOrStoreAccess() async throws {
    let root = try displayNameTemporaryDirectory()
    let unavailableStore = DashboardDirectoryNameStore(fileURL: root)
    let router = DashboardRouter(
      snapshotProvider: {
        displayNameSnapshot(machineDirectories: [("local", "/work/project")])
      },
      assetResolver: StaticAssetResolver(explicitRoot: root),
      directoryNameStore: unavailableStore
    )

    let rejected = await router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: [:],
      body: Data("not-json".utf8)
    )
    #expect(rejected.status == 403)

    let invalid = await router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: mutationHeaders(),
      body: Data(#"{"machine":"local","directory":"/work/project"}"#.utf8)
    )
    #expect(invalid.status == 400)

    let invalidMachine = await router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: mutationHeaders(),
      body: requestBody(machine: "Invalid ID", directory: "/work/project", name: "Name")
    )
    #expect(invalidMachine.status == 400)

    let unknownMachine = await router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: mutationHeaders(),
      body: requestBody(machine: "remote", directory: "/work/project", name: "Name")
    )
    #expect(unknownMachine.status == 404)

    let options = await router.route(
      target: "/api/subdirectories/name",
      method: "OPTIONS",
      headers: mutationHeaders()
    )
    #expect(options.status == 403)

    let unsupported = await router.route(
      target: "/api/subdirectories/name",
      method: "POST",
      headers: mutationHeaders()
    )
    #expect(unsupported.status == 405)

    let unavailable = await router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: mutationHeaders(),
      body: requestBody(machine: "local", directory: "/work/project", name: "Name")
    )
    #expect(unavailable.status == 503)

    let unavailableRead = await router.route(target: "/api/subdirectories")
    #expect(unavailableRead.status == 503)
  }

  @Test func localInventoryRejectsAnUnconfiguredNameStore() async throws {
    let root = try displayNameTemporaryDirectory()
    let router = DashboardRouter(
      snapshotProvider: {
        displayNameSnapshot(machineDirectories: [("local", "/work/project")])
      },
      assetResolver: StaticAssetResolver(explicitRoot: root)
    )

    let response = await router.route(target: "/api/subdirectories")
    #expect(response.status == 503)
    let error = try #require(responseObject(response)["error"] as? [String: Any])
    #expect(error["code"] as? String == "directory_name_unavailable")
  }

  @Test func machineRouterUsesTheSameGuardAndPersistsNames() async throws {
    let fixture = try await machineRouteFixture()
    defer { Task { await fixture.collector.stop() } }

    let rejected = await fixture.router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: [:],
      body: Data("not-json".utf8),
      listenerPort: 18_081
    )
    #expect(rejected.status == 403)

    let setResponse = await fixture.router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: mutationHeaders(),
      body: requestBody(machine: "local", directory: "/work/project", name: "Machine"),
      listenerPort: 18_081
    )
    #expect(setResponse.status == 200)

    let inventory = await fixture.router.route(
      target: "/api/subdirectories?machine=all",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    let payload = try JSONDecoder().decode(SubdirectoriesResponse.self, from: inventory.body)
    #expect(payload.machines.first?.names == ["/work/project": "Machine"])

    let reopened = DashboardDirectoryNameStore(fileURL: fixture.paths.dashboardStateFile)
    #expect(try await reopened.names(machineIDs: ["local"]) == [
      "local": ["/work/project": "Machine"]
    ])
  }

  @Test func machineInventoryRetainsStaleEnabledSnapshotsForGlobalLabels() async throws {
    let alpha = MachineDescriptor(
      id: "alpha",
      displayName: "Alpha",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user")
    )
    let fixture = try await machineRouteFixture(
      sshMachines: [alpha],
      localDirectory: "/work/shared-project"
    )
    defer { Task { await fixture.collector.stop() } }
    let staleAt = Date().addingTimeInterval(-120)
    await fixture.store.publish(
      machineID: "alpha",
      snapshot: displayNameSnapshot(
        generatedAt: staleAt,
        machineDirectories: [("alpha", "/srv/shared-project")]
      ),
      coverageStart: .distantPast,
      revision: 0,
      generation: 0,
      now: staleAt
    )

    let current = try await fixture.store.selection(
      machine: "all",
      now: Date(),
      dataDisposition: .current
    )
    #expect(current.scope.includedMachineIds == ["local"])

    let inventory = await fixture.router.route(
      target: "/api/subdirectories?machine=all",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    let payload = try JSONDecoder().decode(SubdirectoriesResponse.self, from: inventory.body)

    #expect(inventory.status == 200)
    #expect(payload.machines == [
      MachineSubdirectories(machine: "alpha", directories: ["/srv/shared-project"]),
      MachineSubdirectories(machine: "local", directories: ["/work/shared-project"])
    ])

    let recoveredAt = Date()
    await fixture.store.publish(
      machineID: "alpha",
      snapshot: displayNameSnapshot(
        generatedAt: recoveredAt,
        machineDirectories: [("alpha", "/srv/shared-project")]
      ),
      coverageStart: .distantPast,
      revision: 0,
      generation: 0,
      now: recoveredAt
    )
    let recoveredInventory = await fixture.router.route(
      target: "/api/subdirectories?machine=all",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    let recoveredPayload = try JSONDecoder().decode(
      SubdirectoriesResponse.self,
      from: recoveredInventory.body
    )
    #expect(recoveredPayload == payload)
  }

  @Test func deletingAndRecreatingMachineIDDoesNotReuseExplicitNames() async throws {
    let remote = MachineDescriptor(
      id: "remote",
      displayName: "Original",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user")
    )
    let fixture = try await machineRouteFixture(sshMachines: [remote])
    defer { Task { await fixture.collector.stop() } }
    let now = Date()
    await fixture.store.publish(
      machineID: "remote",
      snapshot: displayNameSnapshot(
        generatedAt: now,
        machineDirectories: [("remote", "/srv/project")]
      ),
      coverageStart: .distantPast,
      revision: 0,
      generation: 0,
      now: now
    )

    let renamed = await fixture.router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: mutationHeaders(),
      body: requestBody(machine: "remote", directory: "/srv/project", name: "Sensitive"),
      listenerPort: 18_081
    )
    #expect(renamed.status == 200)

    let deleted = await fixture.router.route(
      target: "/api/machines/remote",
      method: "DELETE",
      headers: mutationHeaders(),
      body: Data(),
      listenerPort: 18_081
    )
    #expect(deleted.status == 204)
    #expect(try await fixture.directoryNameStore.names(machineIDs: ["remote"]) == [:])

    let recreated = await fixture.router.route(
      target: "/api/machines",
      method: "POST",
      headers: mutationHeaders().merging(["Content-Type": "application/json"]) { _, replacement in
        replacement
      },
      body: Data(
        #"{"id":"remote","displayName":"Replacement","kind":"ssh","enabled":true,"ssh":{"host":"localhost","port":22,"user":"user"}}"#.utf8
      ),
      listenerPort: 18_081
    )
    #expect(recreated.status == 201)
    let replacementTime = Date()
    await fixture.store.publish(
      machineID: "remote",
      snapshot: displayNameSnapshot(
        generatedAt: replacementTime,
        machineDirectories: [("remote", "/srv/project")]
      ),
      coverageStart: .distantPast,
      revision: 0,
      generation: 0,
      now: replacementTime
    )

    let inventory = await fixture.router.route(
      target: "/api/subdirectories?machine=all",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    let payload = try JSONDecoder().decode(SubdirectoriesResponse.self, from: inventory.body)
    #expect(inventory.status == 200)
    #expect(payload.machines.first(where: { $0.machine == "remote" })?.names == nil)
  }

  @Test func staleAuthorizedRenameCannotWriteBeneathDeletionMarker() async throws {
    let remote = MachineDescriptor(
      id: "remote",
      displayName: "Remote",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user")
    )
    let fixture = try await machineRouteFixture(sshMachines: [remote])
    defer { Task { await fixture.collector.stop() } }
    try await fixture.directoryNameStore.prepareMachineDeletion(machineID: "remote")

    let response = await fixture.router.route(
      target: "/api/subdirectories/name",
      method: "PUT",
      headers: mutationHeaders(),
      body: requestBody(machine: "remote", directory: "/srv/project", name: "Stale"),
      listenerPort: 18_081
    )

    #expect(response.status == 404)
    #expect(try await fixture.directoryNameStore.names(machineIDs: ["remote"]) == [:])
    try await fixture.directoryNameStore.cancelMachineDeletion(machineID: "remote")
  }

  private func machineRouteFixture(
    sshMachines: [MachineDescriptor] = [],
    localDirectory: String = "/work/project"
  ) async throws -> DirectoryNameMachineRouteFixture {
    let root = try displayNameTemporaryDirectory()
    let paths = AppPaths(
      configFile: root.appendingPathComponent("config/config.json"),
      stateFile: root.appendingPathComponent("state/state.json"),
      aggregationCacheFile: root.appendingPathComponent("cache/aggregates.sqlite3")
    )
    let registry = try MachineRegistry(sshMachines: sshMachines)
    let registryStore = MachineRegistryStore(fileURL: paths.machinesFile)
    try registryStore.save(registry)
    let snapshotStore = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    let collector = try MachineCollector(registry: registry, store: snapshotStore) { descriptor in
      SnapshotService(
        stateStore: StateStore(fileURL: paths.stateFile),
        client: CCUsageClient(commandRunner: DirectoryNameNoopRunner(), machine: descriptor.id),
        aggregationCache: nil
      )
    }
    let directoryNameStore = DashboardDirectoryNameStore(fileURL: paths.dashboardStateFile)
    let owner = MachineRegistryMutationOwner(
      store: registryStore,
      registry: registry,
      runtime: collector,
      metadataLifecycle: directoryNameStore
    )
    let router = MachineDashboardRouter(
      store: snapshotStore,
      collector: collector,
      mutationOwner: owner,
      paths: paths,
      directoryNameStore: directoryNameStore
    )
    let now = Date()
    await snapshotStore.publish(
      machineID: "local",
      snapshot: displayNameSnapshot(
        generatedAt: now,
        machineDirectories: [("local", localDirectory)]
      ),
      coverageStart: .distantPast,
      revision: 0,
      generation: 0,
      now: now
    )
    return DirectoryNameMachineRouteFixture(
      router: router,
      collector: collector,
      store: snapshotStore,
      paths: paths,
      directoryNameStore: directoryNameStore
    )
  }
}

private struct DirectoryNameMachineRouteFixture {
  let router: MachineDashboardRouter
  let collector: MachineCollector
  let store: MachineSnapshotStore
  let paths: AppPaths
  let directoryNameStore: DashboardDirectoryNameStore
}

private actor DirectoryNameTaskStartHandshake {
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func markStarted() {
    started = true
    let currentWaiters = waiters
    waiters.removeAll()
    currentWaiters.forEach { $0.resume() }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private actor DirectoryNameNoopRunner: CCUsageCommandRunner {
  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    let body = arguments.first == "blocks"
      ? #"{"blocks":[]}"#
      : #"{"daily":[],"session":[]}"#
    return ProcessResult(stdout: Data(body.utf8), stderr: Data(), exitStatus: 0)
  }
}

private func mutationHeaders() -> [String: String] {
  [
    "Host": "127.0.0.1:18081",
    "X-CCUsage-Gauge-Mutation": "1"
  ]
}

private func requestBody(machine: String, directory: String, name: String?) -> Data {
  let object: [String: Any] = [
    "machine": machine,
    "directory": directory,
    "name": name ?? NSNull()
  ]
  return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
}

private func responseObject(_ response: HTTPResponse) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
}

private func displayNameSnapshot(
  generatedAt: Date = Date(),
  machineDirectories: [(String, String)]
) -> CostSnapshot {
  let sessions = machineDirectories.enumerated().map { index, item in
    CCUsageSessionMetricRecord(
      timestamp: generatedAt.addingTimeInterval(TimeInterval(-index * 60)),
      agent: "codex",
      model: "gpt-test",
      costUSD: 1,
      inputTokens: 1,
      dataQuality: .timestamped,
      machine: item.0,
      directory: item.1
    )
  }
  return CostSnapshot(
    generatedAt: generatedAt,
    activeBoundaryAt: generatedAt.addingTimeInterval(-3_600),
    costSinceResetUSD: Decimal(sessions.count),
    budget: BudgetSummary(spentUSD: Decimal(sessions.count), budgetUSD: nil),
    resetCycle: .daily,
    points: [],
    dashboardMetrics: [],
    dashboardSessions: sessions
  )
}

private func displayNameTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("ccusage-directory-names-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func displayNameDashboardState() -> DashboardUIState {
  DashboardUIState(
    range: "today",
    customStart: "2026-07-01",
    customEnd: "2026-07-02",
    selectedModels: ["gpt-test"],
    selectedAgents: ["codex"],
    selectedMachines: ["local"],
    granularity: "hourly",
    chartMetric: "costUSD",
    stackBy: "subdirectory"
  )
}
