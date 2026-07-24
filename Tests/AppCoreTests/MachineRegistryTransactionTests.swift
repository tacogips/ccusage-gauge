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
