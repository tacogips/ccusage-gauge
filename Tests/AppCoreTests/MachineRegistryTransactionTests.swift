import Foundation
import Testing
@testable import AppCore

@Suite("Machine registry transaction")
struct MachineRegistryTransactionTests {
  @Test func concurrentCreatesLinearizeWithoutLostUpdates() async throws {
    let initial = try MachineRegistry()
    let persistence = TestRegistryPersistence(initial)
    let runtime = TestRegistryRuntime(initial)
    let owner = MachineRegistryMutationOwner(store: persistence, registry: initial, runtime: runtime)

    async let first = owner.create(machine("alpha"))
    async let second = owner.create(machine("beta"))
    _ = try await (first, second)

    let committed = await owner.current()
    #expect(committed.revision == 2)
    #expect(committed.sshMachines.map(\.id) == ["alpha", "beta"])
    #expect(persistence.current().sshMachines.map(\.id) == ["alpha", "beta"])
    #expect(await runtime.current().sshMachines.map(\.id) == ["alpha", "beta"])
  }

  @Test func runtimeFailureRollsDiskAndRuntimeBackBeforeReturning() async throws {
    let initial = try MachineRegistry()
    let persistence = TestRegistryPersistence(initial)
    let runtime = TestRegistryRuntime(initial, failingCalls: [1])
    let owner = MachineRegistryMutationOwner(store: persistence, registry: initial, runtime: runtime)

    await #expect(throws: MachineRegistryTransactionError.reconciliationFailed(reconciliationRequired: false)) {
      _ = try await owner.create(machine("alpha"))
    }

    #expect(await owner.current() == initial)
    #expect(persistence.current() == initial)
    #expect(await runtime.current() == initial)
  }

  @Test func failedRollbackLatchesLaterMutations() async throws {
    let initial = try MachineRegistry()
    let persistence = TestRegistryPersistence(initial, failingSaveCalls: [2])
    let runtime = TestRegistryRuntime(initial, failingCalls: [1])
    let owner = MachineRegistryMutationOwner(store: persistence, registry: initial, runtime: runtime)

    await #expect(throws: MachineRegistryTransactionError.reconciliationFailed(reconciliationRequired: true)) {
      _ = try await owner.create(machine("alpha"))
    }
    await #expect(throws: MachineRegistryTransactionError.reconciliationRequired) {
      _ = try await owner.create(machine("beta"))
    }

    #expect(await owner.current() == initial)
    #expect(persistence.saveCallCount() == 2)
  }

  @Test func failedMachineDeletionRestoresDirectoryNameVisibility() async throws {
    let initial = try MachineRegistry(sshMachines: [machine("remote")])
    let persistence = TestRegistryPersistence(initial)
    let runtime = TestRegistryRuntime(initial, failingCalls: [1])
    let nameStore = DashboardDirectoryNameStore(
      fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("dashboard-state.sqlite3")
    )
    _ = try await nameStore.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Original"
    )
    let owner = MachineRegistryMutationOwner(
      store: persistence,
      registry: initial,
      runtime: runtime,
      metadataLifecycle: nameStore
    )

    await #expect(throws: MachineRegistryTransactionError.reconciliationFailed(
      reconciliationRequired: false
    )) {
      _ = try await owner.delete(id: "remote")
    }

    #expect(await owner.current() == initial)
    #expect(try await nameStore.names(machineIDs: ["remote"]) == [
      "remote": ["/srv/project": "Original"]
    ])
  }

  @Test func persistedRollbackPreservesNamesWhenRuntimeRollbackAlsoFails() async throws {
    let initial = try MachineRegistry(sshMachines: [machine("remote")])
    let persistence = TestRegistryPersistence(initial)
    let runtime = TestRegistryRuntime(initial, failingCalls: [1, 2])
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("dashboard-state.sqlite3")
    let nameStore = DashboardDirectoryNameStore(fileURL: fileURL)
    _ = try await nameStore.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Original"
    )
    let owner = MachineRegistryMutationOwner(
      store: persistence,
      registry: initial,
      runtime: runtime,
      metadataLifecycle: nameStore
    )

    await #expect(throws: MachineRegistryTransactionError.reconciliationFailed(
      reconciliationRequired: true
    )) {
      _ = try await owner.delete(id: "remote")
    }

    #expect(await owner.current() == initial)
    #expect(persistence.current() == initial)
    #expect(try await nameStore.names(machineIDs: ["remote"]) == [
      "remote": ["/srv/project": "Original"]
    ])

    let reopenedStore = DashboardDirectoryNameStore(fileURL: fileURL)
    try await reopenedStore.reconcileMachineRegistry(machineIDs: initial.machines.map(\.id))
    #expect(try await reopenedStore.names(machineIDs: ["remote"]) == [
      "remote": ["/srv/project": "Original"]
    ])
  }

  @Test func persistedRollbackSurvivesMarkerCancellationFailureAndRestart() async throws {
    let initial = try MachineRegistry(sshMachines: [machine("remote")])
    let persistence = TestRegistryPersistence(initial)
    let runtime = TestRegistryRuntime(initial, failingCalls: [1])
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("dashboard-state.sqlite3")
    let nameStore = DashboardDirectoryNameStore(fileURL: fileURL)
    _ = try await nameStore.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Original"
    )
    let metadata = CancelFailingMetadataLifecycle(store: nameStore)
    let owner = MachineRegistryMutationOwner(
      store: persistence,
      registry: initial,
      runtime: runtime,
      metadataLifecycle: metadata
    )

    await #expect(throws: MachineRegistryTransactionError.reconciliationFailed(
      reconciliationRequired: true
    )) {
      _ = try await owner.delete(id: "remote")
    }

    #expect(persistence.current() == initial)
    let reopenedStore = DashboardDirectoryNameStore(fileURL: fileURL)
    try await reopenedStore.reconcileMachineRegistry(machineIDs: initial.machines.map(\.id))
    #expect(try await reopenedStore.names(machineIDs: ["remote"]) == [
      "remote": ["/srv/project": "Original"]
    ])
  }

  @Test func registryReloadRemovalAndReuseCannotRestoreDirectoryNames() async throws {
    let initial = try MachineRegistry(sshMachines: [machine("remote")])
    let persistence = TestRegistryPersistence(initial)
    let runtime = TestRegistryRuntime(initial)
    let nameStore = DashboardDirectoryNameStore(
      fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("dashboard-state.sqlite3")
    )
    _ = try await nameStore.setName(
      machine: "remote",
      directory: "/srv/project",
      name: "Original"
    )
    let owner = MachineRegistryMutationOwner(
      store: persistence,
      registry: initial,
      runtime: runtime,
      metadataLifecycle: nameStore
    )

    persistence.replaceCurrent(try MachineRegistry())
    _ = try await owner.reload()
    #expect(try await nameStore.names(machineIDs: ["remote"]) == [:])

    persistence.replaceCurrent(try MachineRegistry(sshMachines: [machine("remote")]))
    _ = try await owner.reload()
    #expect(try await nameStore.names(machineIDs: ["remote"]) == [:])
  }

  @Test func bulkReplacementAppliesAdditionAndRemovalMetadataLifecycleTogether() async throws {
    let initial = try MachineRegistry(sshMachines: [machine("removed")])
    let persistence = TestRegistryPersistence(initial)
    let runtime = TestRegistryRuntime(initial)
    let nameStore = DashboardDirectoryNameStore(
      fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("dashboard-state.sqlite3")
    )
    _ = try await nameStore.setName(
      machine: "removed",
      directory: "/srv/removed",
      name: "Removed"
    )
    _ = try await nameStore.setName(
      machine: "added",
      directory: "/srv/added",
      name: "Stale"
    )
    try await nameStore.prepareMachineDeletion(machineID: "added")
    let owner = MachineRegistryMutationOwner(
      store: persistence,
      registry: initial,
      runtime: runtime,
      metadataLifecycle: nameStore
    )

    _ = try await owner.replaceSSHMachines([machine("added")])

    #expect(try await nameStore.names(machineIDs: ["removed", "added"]) == [:])
    _ = try await nameStore.setName(
      machine: "added",
      directory: "/srv/added",
      name: "Replacement"
    )
    #expect(try await nameStore.names(machineIDs: ["added"]) == [
      "added": ["/srv/added": "Replacement"]
    ])
  }

  @Test func committedDeletionReportsAndRetriesMetadataCleanupFailure() async throws {
    let initial = try MachineRegistry(sshMachines: [machine("remote")])
    let persistence = TestRegistryPersistence(initial)
    let runtime = TestRegistryRuntime(initial)
    let metadata = TestRegistryMetadataLifecycle(finalizeResults: [false, true])
    let owner = MachineRegistryMutationOwner(
      store: persistence,
      registry: initial,
      runtime: runtime,
      metadataLifecycle: metadata,
      metadataCleanupRetryDelaysNanoseconds: []
    )

    _ = try await owner.delete(id: "remote")

    #expect(await owner.current().machine(id: "remote") == nil)
    #expect(await owner.metadataCleanupPendingMachineIDs() == ["remote"])
    #expect(await metadata.commitCallCount() == 1)
    #expect(await metadata.finalizeCallCount() == 1)

    #expect(await owner.retryPendingMetadataCleanup() == [])
    #expect(await owner.metadataCleanupPendingMachineIDs() == [])
    #expect(await metadata.finalizeCallCount() == 2)
  }

  @Test func deletionPhaseCommitFailureRollsRegistryBack() async throws {
    let initial = try MachineRegistry(sshMachines: [machine("remote")])
    let persistence = TestRegistryPersistence(initial)
    let runtime = TestRegistryRuntime(initial)
    let metadata = TestRegistryMetadataLifecycle(
      finalizeResults: [],
      commitFails: true
    )
    let owner = MachineRegistryMutationOwner(
      store: persistence,
      registry: initial,
      runtime: runtime,
      metadataLifecycle: metadata
    )

    await #expect(throws: DashboardDirectoryNameError.databaseUnavailable) {
      _ = try await owner.delete(id: "remote")
    }

    #expect(await owner.current() == initial)
    #expect(persistence.current() == initial)
    #expect(await runtime.current() == initial)
    #expect(await metadata.commitCallCount() == 1)
    #expect(await metadata.finalizeCallCount() == 0)
  }

  private func machine(_ id: String) -> MachineDescriptor {
    MachineDescriptor(
      id: id,
      displayName: id.capitalized,
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "tester")
    )
  }
}

private final class TestRegistryPersistence: MachineRegistryPersistence, @unchecked Sendable {
  private let lock = NSLock()
  private var registry: MachineRegistry
  private var saveCalls = 0
  private let failingSaveCalls: Set<Int>

  init(_ registry: MachineRegistry, failingSaveCalls: Set<Int> = []) {
    self.registry = registry
    self.failingSaveCalls = failingSaveCalls
  }

  func load() throws -> MachineRegistry {
    lock.withLock { registry }
  }

  func save(_ registry: MachineRegistry) throws {
    try lock.withLock {
      saveCalls += 1
      if failingSaveCalls.contains(saveCalls) {
        throw MachineRegistryStoreError.registryPersistenceFailed
      }
      self.registry = registry
    }
  }

  func current() -> MachineRegistry {
    lock.withLock { registry }
  }

  func replaceCurrent(_ registry: MachineRegistry) {
    lock.withLock {
      self.registry = registry
    }
  }

  func saveCallCount() -> Int {
    lock.withLock { saveCalls }
  }
}

private actor TestRegistryRuntime: MachineRegistryRuntimeReconciler {
  private var registry: MachineRegistry
  private var calls = 0
  private let failingCalls: Set<Int>

  init(_ registry: MachineRegistry, failingCalls: Set<Int> = []) {
    self.registry = registry
    self.failingCalls = failingCalls
  }

  func reconcileRegistry(_ registry: MachineRegistry) throws {
    calls += 1
    self.registry = registry
    if failingCalls.contains(calls) {
      throw MachineRegistryTransactionError.reconciliationFailed(reconciliationRequired: false)
    }
  }

  func current() -> MachineRegistry { registry }
}

private actor TestRegistryMetadataLifecycle: MachineRegistryMetadataLifecycle {
  private var finalizeResults: [Bool]
  private let commitFails: Bool
  private var commitCalls = 0
  private var finalizeCalls = 0

  init(finalizeResults: [Bool], commitFails: Bool = false) {
    self.finalizeResults = finalizeResults
    self.commitFails = commitFails
  }

  func prepareMachineCreation(machineID: String) {}

  func prepareMachineDeletion(machineID: String) {}

  func commitMachineDeletion(machineID: String) throws {
    commitCalls += 1
    if commitFails {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
  }

  func cancelMachineDeletion(machineID: String) {}

  func finalizeMachineDeletion(machineID: String) -> Bool {
    finalizeCalls += 1
    return finalizeResults.isEmpty ? false : finalizeResults.removeFirst()
  }

  func finalizeCallCount() -> Int {
    finalizeCalls
  }

  func commitCallCount() -> Int {
    commitCalls
  }
}

private actor CancelFailingMetadataLifecycle: MachineRegistryMetadataLifecycle {
  private let store: DashboardDirectoryNameStore

  init(store: DashboardDirectoryNameStore) {
    self.store = store
  }

  func prepareMachineCreation(machineID: String) async throws {
    try await store.prepareMachineCreation(machineID: machineID)
  }

  func prepareMachineDeletion(machineID: String) async throws {
    try await store.prepareMachineDeletion(machineID: machineID)
  }

  func commitMachineDeletion(machineID: String) async throws {
    try await store.commitMachineDeletion(machineID: machineID)
  }

  func prepareMachineDeletionRollback(machineID: String) async throws {
    try await store.prepareMachineDeletionRollback(machineID: machineID)
  }

  func cancelMachineDeletion(machineID: String) throws {
    throw DashboardDirectoryNameError.databaseUnavailable
  }

  func finalizeMachineDeletion(machineID: String) async -> Bool {
    await store.finalizeMachineDeletion(machineID: machineID)
  }
}
