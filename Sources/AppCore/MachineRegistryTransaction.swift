import Foundation

public protocol MachineRegistryRuntimeReconciler: Sendable {
  func reconcileRegistry(_ registry: MachineRegistry) async throws
}

public protocol MachineRegistryMetadataLifecycle: Sendable {
  func prepareMachineCreation(machineID: String) async throws
  func prepareMachineDeletion(machineID: String) async throws
  func commitMachineDeletion(machineID: String) async throws
  func prepareMachineDeletionRollback(machineID: String) async throws
  func cancelMachineDeletion(machineID: String) async throws
  func finalizeMachineDeletion(machineID: String) async -> Bool
}

public extension MachineRegistryMetadataLifecycle {
  func prepareMachineDeletionRollback(machineID: String) async throws {
    try await cancelMachineDeletion(machineID: machineID)
  }
}

public enum MachineRegistryTransactionError: Error, Equatable, Sendable {
  case reconciliationFailed(reconciliationRequired: Bool)
  case reconciliationRequired
}

public actor MachineRegistryMutationOwner {
  private let store: any MachineRegistryPersistence
  private let runtime: any MachineRegistryRuntimeReconciler
  private let metadataLifecycle: (any MachineRegistryMetadataLifecycle)?
  private let metadataCleanupRetryDelaysNanoseconds: [UInt64]
  private var reconciliationRequired = false
  private var pendingMetadataCleanupMachineIDs: Set<String> = []
  private var transactionActive = false
  private var transactionWaiters: [CheckedContinuation<Void, Never>] = []
  public private(set) var registry: MachineRegistry

  public init(
    store: any MachineRegistryPersistence,
    registry: MachineRegistry,
    runtime: any MachineRegistryRuntimeReconciler,
    metadataLifecycle: (any MachineRegistryMetadataLifecycle)? = nil,
    metadataCleanupRetryDelaysNanoseconds: [UInt64] = [
      100_000_000,
      500_000_000,
      2_000_000_000
    ]
  ) {
    self.store = store
    self.registry = registry
    self.runtime = runtime
    self.metadataLifecycle = metadataLifecycle
    self.metadataCleanupRetryDelaysNanoseconds = metadataCleanupRetryDelaysNanoseconds
  }

  public func current() -> MachineRegistry { registry }

  public func metadataCleanupPendingMachineIDs() -> [String] {
    pendingMetadataCleanupMachineIDs.sorted()
  }

  @discardableResult
  public func retryPendingMetadataCleanup() async -> [String] {
    await acquireTransaction()
    defer { releaseTransaction() }
    guard let metadataLifecycle else { return [] }
    for machineID in pendingMetadataCleanupMachineIDs.sorted() {
      if registry.machine(id: machineID) != nil {
        pendingMetadataCleanupMachineIDs.remove(machineID)
      } else if await metadataLifecycle.finalizeMachineDeletion(machineID: machineID) {
        pendingMetadataCleanupMachineIDs.remove(machineID)
      }
    }
    return pendingMetadataCleanupMachineIDs.sorted()
  }

  public func reload() async throws -> (registry: MachineRegistry, changed: Bool) {
    await acquireTransaction()
    defer { releaseTransaction() }
    try requireCoherentRuntime()
    let loaded = try store.load()
    guard loaded.machines != registry.machines else { return (registry, false) }
    let candidate = try MachineRegistry(
      sshMachines: loaded.sshMachines,
      localMachine: loaded.localMachine,
      revision: registry.revision + 1
    )
    let deletedMachineIDs = try await prepareMetadataTransition(from: registry, to: candidate)
    do {
      try await commitMetadataDeletions(deletedMachineIDs)
    } catch {
      try await cancelMetadataDeletions(deletedMachineIDs)
      throw error
    }
    do {
      try await runtime.reconcileRegistry(candidate)
      registry = candidate
      await finalizeMetadataDeletions(deletedMachineIDs)
      return (candidate, true)
    } catch {
      do {
        try await runtime.reconcileRegistry(registry)
      } catch {
        reconciliationRequired = true
        throw MachineRegistryTransactionError.reconciliationFailed(reconciliationRequired: true)
      }
      try await cancelMetadataDeletions(deletedMachineIDs)
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
      ssh: descriptor.ssh,
      codexSessionDirs: descriptor.codexSessionDirs,
      claudeConfigDirs: descriptor.claudeConfigDirs,
      includeDefaultCodexDir: descriptor.includeDefaultCodexDir,
      includeDefaultClaudeDir: descriptor.includeDefaultClaudeDir
    ))
    let machines = registry.sshMachines.map { $0.id == id ? normalized : $0 }
    return (try await commit(machines), normalized)
  }

  public func patch(
    id: String,
    displayName: String?,
    enabled: Bool?,
    ssh: SSHConnection?,
    codexSessionDirs: MachinePatchField<[String]> = .omitted,
    claudeConfigDirs: MachinePatchField<[String]> = .omitted,
    includeDefaultCodexDir: MachinePatchField<Bool> = .omitted,
    includeDefaultClaudeDir: MachinePatchField<Bool> = .omitted
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
      ssh: ssh ?? existing.ssh,
      codexSessionDirs: codexSessionDirs.value(or: existing.codexSessionDirs),
      claudeConfigDirs: claudeConfigDirs.value(or: existing.claudeConfigDirs),
      includeDefaultCodexDir: includeDefaultCodexDir.value(or: existing.includeDefaultCodexDir),
      includeDefaultClaudeDir: includeDefaultClaudeDir.value(or: existing.includeDefaultClaudeDir)
    ))
    let machines = registry.sshMachines.map { $0.id == id ? normalized : $0 }
    return (try await commit(machines), normalized)
  }

  public func patchLocalSources(
    codexSessionDirs: MachinePatchField<[String]>,
    claudeConfigDirs: MachinePatchField<[String]>,
    includeDefaultCodexDir: MachinePatchField<Bool>,
    includeDefaultClaudeDir: MachinePatchField<Bool>
  ) async throws -> (MachineRegistry, MachineDescriptor) {
    await acquireTransaction()
    defer { releaseTransaction() }
    try requireCoherentRuntime()
    let existing = registry.localMachine
    let local = MachineDescriptor(
      id: "local",
      displayName: "Local",
      kind: .local,
      enabled: true,
      codexSessionDirs: codexSessionDirs.value(or: existing.codexSessionDirs),
      claudeConfigDirs: claudeConfigDirs.value(or: existing.claudeConfigDirs),
      includeDefaultCodexDir: includeDefaultCodexDir.value(or: existing.includeDefaultCodexDir),
      includeDefaultClaudeDir: includeDefaultClaudeDir.value(or: existing.includeDefaultClaudeDir)
    )
    try MachineValidation.validate(descriptor: local, allowSyntheticLocal: true)
    return (try await commit(registry.sshMachines, localMachine: local), local)
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

  private func commit(
    _ machines: [MachineDescriptor],
    localMachine: MachineDescriptor? = nil
  ) async throws -> MachineRegistry {
    try requireCoherentRuntime()
    let previous = registry
    let candidate = try MachineRegistry(
      sshMachines: machines,
      localMachine: localMachine ?? previous.localMachine,
      revision: previous.revision + 1
    )
    let deletedMachineIDs = try await prepareMetadataTransition(from: previous, to: candidate)
    do {
      try store.save(candidate)
    } catch {
      try await cancelMetadataDeletions(deletedMachineIDs)
      throw error
    }
    do {
      try await commitMetadataDeletions(deletedMachineIDs)
    } catch {
      do {
        try await prepareMetadataDeletionRollback(deletedMachineIDs)
        try store.save(previous)
        try await cancelMetadataDeletions(deletedMachineIDs)
      } catch {
        reconciliationRequired = true
        throw MachineRegistryTransactionError.reconciliationFailed(
          reconciliationRequired: true
        )
      }
      throw error
    }
    do {
      try await runtime.reconcileRegistry(candidate)
      registry = candidate
      await finalizeMetadataDeletions(deletedMachineIDs)
      return candidate
    } catch {
      var rollbackFailed = false
      var persistenceRollbackSucceeded = false
      do {
        try await prepareMetadataDeletionRollback(deletedMachineIDs)
        try store.save(previous)
        persistenceRollbackSucceeded = true
      } catch {
        rollbackFailed = true
      }
      if persistenceRollbackSucceeded {
        do {
          try await cancelMetadataDeletions(deletedMachineIDs)
        } catch {
          rollbackFailed = true
        }
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

  private func prepareMetadataTransition(
    from previous: MachineRegistry,
    to candidate: MachineRegistry
  ) async throws -> [String] {
    let previousIDs = Set(previous.sshMachines.map(\.id))
    let candidateIDs = Set(candidate.sshMachines.map(\.id))
    for machineID in candidateIDs.subtracting(previousIDs).sorted() {
      try await metadataLifecycle?.prepareMachineCreation(machineID: machineID)
    }
    let deletedMachineIDs = previousIDs.subtracting(candidateIDs).sorted()
    var preparedDeletionIDs: [String] = []
    do {
      for machineID in deletedMachineIDs {
        try await metadataLifecycle?.prepareMachineDeletion(machineID: machineID)
        preparedDeletionIDs.append(machineID)
      }
    } catch {
      try await cancelMetadataDeletions(preparedDeletionIDs)
      throw error
    }
    return deletedMachineIDs
  }

  private func commitMetadataDeletions(_ machineIDs: [String]) async throws {
    for machineID in machineIDs {
      try await metadataLifecycle?.commitMachineDeletion(machineID: machineID)
    }
  }

  private func prepareMetadataDeletionRollback(_ machineIDs: [String]) async throws {
    for machineID in machineIDs {
      try await metadataLifecycle?.prepareMachineDeletionRollback(machineID: machineID)
    }
  }

  private func cancelMetadataDeletions(_ machineIDs: [String]) async throws {
    do {
      for machineID in machineIDs.reversed() {
        try await metadataLifecycle?.cancelMachineDeletion(machineID: machineID)
      }
    } catch {
      reconciliationRequired = true
      throw MachineRegistryTransactionError.reconciliationFailed(reconciliationRequired: true)
    }
  }

  private func finalizeMetadataDeletions(_ machineIDs: [String]) async {
    guard let metadataLifecycle else { return }
    for machineID in machineIDs {
      if await metadataLifecycle.finalizeMachineDeletion(machineID: machineID) {
        pendingMetadataCleanupMachineIDs.remove(machineID)
      } else if pendingMetadataCleanupMachineIDs.insert(machineID).inserted {
        scheduleMetadataCleanupRetry(machineID: machineID)
      }
    }
  }

  private func scheduleMetadataCleanupRetry(machineID: String) {
    let retryDelays = metadataCleanupRetryDelaysNanoseconds
    Task { [weak self] in
      for delay in retryDelays {
        do {
          try await Task.sleep(nanoseconds: delay)
        } catch {
          return
        }
        guard let self else { return }
        if await self.retryMetadataCleanup(machineID: machineID) {
          return
        }
      }
    }
  }

  private func retryMetadataCleanup(machineID: String) async -> Bool {
    await acquireTransaction()
    defer { releaseTransaction() }
    guard pendingMetadataCleanupMachineIDs.contains(machineID) else { return true }
    guard registry.machine(id: machineID) == nil else {
      pendingMetadataCleanupMachineIDs.remove(machineID)
      return true
    }
    guard let metadataLifecycle,
          await metadataLifecycle.finalizeMachineDeletion(machineID: machineID) else {
      return false
    }
    pendingMetadataCleanupMachineIDs.remove(machineID)
    return true
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
      ssh: descriptor.ssh,
      codexSessionDirs: descriptor.codexSessionDirs,
      claudeConfigDirs: descriptor.claudeConfigDirs,
      includeDefaultCodexDir: descriptor.includeDefaultCodexDir,
      includeDefaultClaudeDir: descriptor.includeDefaultClaudeDir
    )
    try MachineValidation.validate(descriptor: normalized)
    if let connection = normalized.ssh {
      try MachineValidation.validate(connection: connection, requireReadableIdentity: true)
    }
    return normalized
  }
}
