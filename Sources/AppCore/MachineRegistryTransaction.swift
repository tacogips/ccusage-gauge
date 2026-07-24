import Foundation

public protocol MachineRegistryRuntimeReconciler: Sendable {
  func reconcileRegistry(_ registry: MachineRegistry) async throws
}

public enum MachineRegistryTransactionError: Error, Equatable, Sendable {
  case reconciliationFailed(reconciliationRequired: Bool)
  case reconciliationRequired
}

public actor MachineRegistryMutationOwner {
  private let store: any MachineRegistryPersistence
  private let runtime: any MachineRegistryRuntimeReconciler
  private var reconciliationRequired = false
  private var transactionActive = false
  private var transactionWaiters: [CheckedContinuation<Void, Never>] = []
  public private(set) var registry: MachineRegistry

  public init(
    store: any MachineRegistryPersistence,
    registry: MachineRegistry,
    runtime: any MachineRegistryRuntimeReconciler
  ) {
    self.store = store
    self.registry = registry
    self.runtime = runtime
  }

  public func current() -> MachineRegistry { registry }

  public func reload() async throws -> (registry: MachineRegistry, changed: Bool) {
    await acquireTransaction()
    defer { releaseTransaction() }
    try requireCoherentRuntime()
    let loaded = try store.load()
    guard loaded.sshMachines != registry.sshMachines else { return (registry, false) }
    let candidate = try MachineRegistry(sshMachines: loaded.sshMachines, revision: registry.revision + 1)
    do {
      try await runtime.reconcileRegistry(candidate)
      registry = candidate
      return (candidate, true)
    } catch {
      do {
        try await runtime.reconcileRegistry(registry)
      } catch {
        reconciliationRequired = true
        throw MachineRegistryTransactionError.reconciliationFailed(reconciliationRequired: true)
      }
      throw MachineRegistryTransactionError.reconciliationFailed(reconciliationRequired: false)
    }
  }

  public func create(_ descriptor: MachineDescriptor) async throws -> (MachineRegistry, MachineDescriptor) {
    await acquireTransaction()
    defer { releaseTransaction() }
    try requireCoherentRuntime()
    guard descriptor.id != "local", descriptor.id != "all", registry.machine(id: descriptor.id) == nil else {
      throw MachineRegistryMutationError.conflict
    }
    let normalized = try normalizedDescriptor(descriptor)
    return (try await commit(registry.sshMachines + [normalized]), normalized)
  }

  public func replace(id: String, with descriptor: MachineDescriptor) async throws -> (MachineRegistry, MachineDescriptor) {
    await acquireTransaction()
    defer { releaseTransaction() }
    try requireCoherentRuntime()
    guard id != "local" else { throw MachineRegistryMutationError.conflict }
    guard registry.machine(id: id) != nil else { throw MachineRegistryMutationError.notFound }
    let normalized = try normalizedDescriptor(MachineDescriptor(
      id: id,
      displayName: descriptor.displayName,
      kind: descriptor.kind,
      enabled: descriptor.enabled,
      ssh: descriptor.ssh
    ))
    let machines = registry.sshMachines.map { $0.id == id ? normalized : $0 }
    return (try await commit(machines), normalized)
  }

  public func patch(
    id: String,
    displayName: String?,
    enabled: Bool?,
    ssh: SSHConnection?
  ) async throws -> (MachineRegistry, MachineDescriptor) {
    await acquireTransaction()
    defer { releaseTransaction() }
    try requireCoherentRuntime()
    guard id != "local" else { throw MachineRegistryMutationError.conflict }
    guard let existing = registry.machine(id: id) else { throw MachineRegistryMutationError.notFound }
    let normalized = try normalizedDescriptor(MachineDescriptor(
      id: id,
      displayName: displayName ?? existing.displayName,
      kind: .ssh,
      enabled: enabled ?? existing.enabled,
      ssh: ssh ?? existing.ssh
    ))
    let machines = registry.sshMachines.map { $0.id == id ? normalized : $0 }
    return (try await commit(machines), normalized)
  }

  public func delete(id: String) async throws -> MachineRegistry {
    await acquireTransaction()
    defer { releaseTransaction() }
    try requireCoherentRuntime()
    guard id != "local" else { throw MachineRegistryMutationError.conflict }
    guard registry.machine(id: id) != nil else { throw MachineRegistryMutationError.notFound }
    return try await commit(registry.sshMachines.filter { $0.id != id })
  }

  @discardableResult
  public func replaceSSHMachines(_ machines: [MachineDescriptor]) async throws -> MachineRegistry {
    await acquireTransaction()
    defer { releaseTransaction() }
    return try await commit(machines)
  }

  private func commit(_ machines: [MachineDescriptor]) async throws -> MachineRegistry {
    try requireCoherentRuntime()
    let previous = registry
    let candidate = try MachineRegistry(sshMachines: machines, revision: previous.revision + 1)
    try store.save(candidate)
    do {
      try await runtime.reconcileRegistry(candidate)
      registry = candidate
      return candidate
    } catch {
      var rollbackFailed = false
      do {
        try store.save(previous)
      } catch {
        rollbackFailed = true
      }
      do {
        try await runtime.reconcileRegistry(previous)
      } catch {
        rollbackFailed = true
      }
      reconciliationRequired = rollbackFailed
      throw MachineRegistryTransactionError.reconciliationFailed(reconciliationRequired: rollbackFailed)
    }
  }

  private func requireCoherentRuntime() throws {
    if reconciliationRequired {
      throw MachineRegistryTransactionError.reconciliationRequired
    }
  }

  private func acquireTransaction() async {
    guard transactionActive else {
      transactionActive = true
      return
    }
    await withCheckedContinuation { continuation in
      transactionWaiters.append(continuation)
    }
  }

  private func releaseTransaction() {
    guard !transactionWaiters.isEmpty else {
      transactionActive = false
      return
    }
    transactionWaiters.removeFirst().resume()
  }

  private func normalizedDescriptor(_ descriptor: MachineDescriptor) throws -> MachineDescriptor {
    let normalized = MachineDescriptor(
      id: descriptor.id,
      displayName: try MachineValidation.normalizedDisplayName(descriptor.displayName),
      kind: descriptor.kind,
      enabled: descriptor.enabled,
      ssh: descriptor.ssh
    )
    try MachineValidation.validate(descriptor: normalized)
    if let connection = normalized.ssh {
      try MachineValidation.validate(connection: connection, requireReadableIdentity: true)
    }
    return normalized
  }
}
