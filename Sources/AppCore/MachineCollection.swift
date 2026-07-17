import Foundation

public struct SanitizedCollectionError: Codable, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct MachineCollectionStatus: Equatable, Sendable {
  public var lastAttemptAt: Date?
  public var lastSuccessAt: Date?
  public var lastErrorAt: Date?
  public var lastError: SanitizedCollectionError?
  public var collectionInProgress: Bool
  public let refreshIntervalSeconds: Int

  public init(refreshIntervalSeconds: Int) {
    lastAttemptAt = nil
    lastSuccessAt = nil
    lastErrorAt = nil
    lastError = nil
    collectionInProgress = false
    self.refreshIntervalSeconds = max(1, refreshIntervalSeconds)
  }
}

public struct MachineSnapshotEntry: Equatable, Sendable {
  public let descriptor: MachineDescriptor
  public var snapshot: CostSnapshot?
  public var coverageStart: Date?
  public var loadStatus: DashboardLoadStatus
  public var collectionStatus: MachineCollectionStatus
  public var revision: UInt64
  public var generation: UInt64
}

public enum MachineCollectionState: String, Codable, Equatable, Sendable {
  case disabled
  case neverCollected
  case healthy
  case stale
  case error
}

public struct MachineStatusResponseItem: Codable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let kind: MachineKind
  public let enabled: Bool
  public let collectionState: MachineCollectionState
  public let snapshotAvailable: Bool
  public let collectionInProgress: Bool
  public let stale: Bool
  public let coverageStart: String?
  public let snapshotGeneratedAt: Date?
  public let lastAttemptAt: Date?
  public let lastSuccessAt: Date?
  public let lastErrorAt: Date?
  public let lastError: SanitizedCollectionError?
  public let refreshIntervalSeconds: Int
}

public struct MachineStatusResponse: Codable, Equatable, Sendable {
  public let requested: String
  public let generatedAt: Date
  public let machines: [MachineStatusResponseItem]
}

public struct DashboardScope: Codable, Equatable, Sendable {
  public let requested: String
  public let includedMachineIds: [String]
  public let staleMachineIds: [String]
  public let unavailableMachineIds: [String]
  public let generatedAt: Date?
}

public struct MachineSnapshotSelection: Sendable {
  public let snapshot: CostSnapshot?
  public let scope: DashboardScope
  public let collectionState: MachineCollectionState?
  public let refreshIntervalSeconds: Int
}

public enum MachineSelectionError: Error, Equatable, Sendable {
  case invalid
  case notFound(String)
  case disabled(String)
  case unavailable(String, MachineCollectionState, Int)
  case aggregateUnavailable(Int)
  case rangeUnavailable(String, Date, Date?, Int)
  case aggregateRangeUnavailable(Date, Int)
}

public actor MachineSnapshotStore {
  private var entries: [String: MachineSnapshotEntry] = [:]
  private var registryRevision: UInt64
  private let calendar: Calendar

  public init(registry: MachineRegistry, refreshIntervalSeconds: Int, calendar: Calendar = .current) {
    registryRevision = registry.revision
    self.calendar = calendar
    for descriptor in registry.machines {
      entries[descriptor.id] = Self.emptyEntry(
        descriptor: descriptor,
        refreshIntervalSeconds: refreshIntervalSeconds,
        revision: registry.revision,
        generation: 0
      )
    }
  }

  public func descriptors() -> [MachineDescriptor] {
    orderedEntries().map(\.descriptor)
  }

  public func entry(machineID: String) -> MachineSnapshotEntry? { entries[machineID] }

  public func replaceRegistry(_ registry: MachineRegistry, generations: [String: UInt64]) {
    var next: [String: MachineSnapshotEntry] = [:]
    for descriptor in registry.machines {
      if var existing = entries[descriptor.id] {
        existing = MachineSnapshotEntry(
          descriptor: descriptor,
          snapshot: existing.snapshot,
          coverageStart: existing.coverageStart,
          loadStatus: existing.loadStatus,
          collectionStatus: existing.collectionStatus,
          revision: registry.revision,
          generation: generations[descriptor.id] ?? existing.generation
        )
        next[descriptor.id] = existing
      } else {
        next[descriptor.id] = Self.emptyEntry(
          descriptor: descriptor,
          refreshIntervalSeconds: AppConfiguration.defaultPollIntervalSeconds,
          revision: registry.revision,
          generation: generations[descriptor.id] ?? 0
        )
      }
    }
    registryRevision = registry.revision
    entries = next
  }

  public func beginCollection(
    machineID: String,
    revision: UInt64,
    generation: UInt64,
    phase: DashboardLoadPhase,
    requestedCoverageStart: Date?,
    now: Date
  ) {
    guard var entry = fencedEntry(machineID: machineID, revision: revision, generation: generation) else { return }
    entry.collectionStatus.lastAttemptAt = now
    entry.collectionStatus.collectionInProgress = true
    entry.loadStatus = DashboardLoadStatus(
      phase: phase,
      message: phase == .loadingHistory ? "Loading usage history" : phase == .refreshing ? "Refreshing usage data" : "Loading this week",
      completed: 0,
      total: 1,
      isLoading: true
    )
    entries[machineID] = entry
  }

  public func publish(
    machineID: String,
    snapshot: CostSnapshot,
    coverageStart: Date,
    revision: UInt64,
    generation: UInt64,
    now: Date
  ) {
    guard var entry = fencedEntry(machineID: machineID, revision: revision, generation: generation) else { return }
    entry.snapshot = snapshot
    entry.coverageStart = min(entry.coverageStart ?? coverageStart, coverageStart)
    entry.collectionStatus.lastSuccessAt = now
    entry.collectionStatus.lastErrorAt = nil
    entry.collectionStatus.lastError = nil
    entry.collectionStatus.collectionInProgress = false
    entry.loadStatus = DashboardLoadStatus(phase: .ready, message: "Usage data is ready", completed: 1, total: 1, isLoading: false)
    entries[machineID] = entry
  }

  public func publishFailure(
    machineID: String,
    error: Error,
    revision: UInt64,
    generation: UInt64,
    now: Date
  ) {
    guard !(error is CancellationError),
          var entry = fencedEntry(machineID: machineID, revision: revision, generation: generation) else { return }
    entry.collectionStatus.lastErrorAt = now
    entry.collectionStatus.lastError = Self.sanitizedError(error)
    entry.collectionStatus.collectionInProgress = false
    entry.loadStatus = DashboardLoadStatus(phase: .failed, message: "Usage data loading failed", completed: 0, total: 1, isLoading: false)
    entries[machineID] = entry
  }

  public func finishCancellation(machineID: String, revision: UInt64, generation: UInt64) {
    guard var entry = fencedEntry(machineID: machineID, revision: revision, generation: generation) else { return }
    entry.collectionStatus.collectionInProgress = false
    entries[machineID] = entry
  }

  public func clear(machineID: String) {
    guard var entry = entries[machineID] else { return }
    entry.snapshot = nil
    entry.coverageStart = nil
    entry.loadStatus = DashboardLoadStatus(phase: .idle, message: "Cache cleared", completed: 0, total: 1, isLoading: false)
    entry.collectionStatus.lastSuccessAt = nil
    entry.collectionStatus.lastErrorAt = nil
    entry.collectionStatus.lastError = nil
    entries[machineID] = entry
  }

  public func selection(
    machine requested: String,
    now: Date = Date(),
    requiredCoverageStart: Date? = nil
  ) throws -> MachineSnapshotSelection {
    if requested == "all" { return try aggregateSelection(now: now, requiredCoverageStart: requiredCoverageStart) }
    guard let entry = entries[requested] else { throw MachineSelectionError.notFound(requested) }
    let state = collectionState(entry, now: now)
    let scope = scope(requested: requested, selected: [entry], now: now, requiredCoverageStart: requiredCoverageStart)
    guard entry.descriptor.enabled else { throw MachineSelectionError.disabled(requested) }
    guard let snapshot = entry.snapshot else {
      throw MachineSelectionError.unavailable(requested, state, entry.collectionStatus.refreshIntervalSeconds)
    }
    if let requiredCoverageStart,
       entry.coverageStart == nil || entry.coverageStart! > requiredCoverageStart {
      throw MachineSelectionError.rangeUnavailable(
        requested,
        requiredCoverageStart,
        entry.coverageStart,
        entry.collectionStatus.refreshIntervalSeconds
      )
    }
    return MachineSnapshotSelection(
      snapshot: snapshot,
      scope: scope,
      collectionState: state,
      refreshIntervalSeconds: entry.collectionStatus.refreshIntervalSeconds
    )
  }

  public func status(machine requested: String, now: Date = Date()) throws -> MachineStatusResponse {
    let selected: [MachineSnapshotEntry]
    if requested == "all" {
      selected = orderedEntries()
    } else if let entry = entries[requested] {
      selected = [entry]
    } else {
      throw MachineSelectionError.notFound(requested)
    }
    return MachineStatusResponse(
      requested: requested,
      generatedAt: now,
      machines: selected.map { statusItem($0, now: now) }
    )
  }

  public func loadStatuses(machine requested: String) throws -> [(String, DashboardLoadStatus, Date?)] {
    if requested == "all" {
      return orderedEntries().filter(\.descriptor.enabled).map { ($0.descriptor.id, $0.loadStatus, $0.coverageStart) }
    }
    guard let entry = entries[requested] else { throw MachineSelectionError.notFound(requested) }
    guard entry.descriptor.enabled else { throw MachineSelectionError.disabled(requested) }
    return [(entry.descriptor.id, entry.loadStatus, entry.coverageStart)]
  }

  private func aggregateSelection(now: Date, requiredCoverageStart: Date?) throws -> MachineSnapshotSelection {
    let enabled = orderedEntries().filter(\.descriptor.enabled)
    let usable = enabled.filter { entry in
      entry.snapshot != nil && (requiredCoverageStart == nil || (entry.coverageStart != nil && entry.coverageStart! <= requiredCoverageStart!))
    }
    let scope = scope(requested: "all", selected: enabled, now: now, requiredCoverageStart: requiredCoverageStart)
    let refresh = enabled.map(\.collectionStatus.refreshIntervalSeconds).filter { $0 > 0 }.min()
      ?? AppConfiguration.defaultPollIntervalSeconds
    guard !usable.isEmpty else {
      if let requiredCoverageStart { throw MachineSelectionError.aggregateRangeUnavailable(requiredCoverageStart, refresh) }
      throw MachineSelectionError.aggregateUnavailable(refresh)
    }
    return MachineSnapshotSelection(
      snapshot: merge(usable.compactMap(\.snapshot), now: now),
      scope: scope,
      collectionState: nil,
      refreshIntervalSeconds: refresh
    )
  }

  private func merge(_ snapshots: [CostSnapshot], now: Date) -> CostSnapshot {
    let points = snapshots.flatMap(\.points)
    let metrics = snapshots.flatMap(\.dashboardMetrics)
    let sessions = snapshots.flatMap(\.dashboardSessions)
    let exemplar = snapshots[0]
    let interval = (try? ResetWindowCalculator(calendar: calendar).aggregationInterval(for: exemplar.resetCycle, now: now))
      ?? DateInterval(start: exemplar.activeBoundaryAt, end: now)
    let cost = selectedPeriodCost(cycle: exemplar.resetCycle, interval: interval, metrics: metrics, sessions: sessions, calendar: calendar)
    return CostSnapshot(
      generatedAt: snapshots.map(\.generatedAt).min() ?? now,
      activeBoundaryAt: interval.start,
      costSinceResetUSD: cost,
      budget: BudgetSummary(spentUSD: cost, budgetUSD: exemplar.budget.budgetUSD),
      resetCycle: exemplar.resetCycle,
      refreshIntervalSeconds: snapshots.map(\.refreshIntervalSeconds).filter { $0 > 0 }.min() ?? exemplar.refreshIntervalSeconds,
      points: points,
      dashboardMetrics: metrics,
      dashboardSessions: sessions
    )
  }

  private func scope(
    requested: String,
    selected: [MachineSnapshotEntry],
    now: Date,
    requiredCoverageStart: Date?
  ) -> DashboardScope {
    let included = selected.filter { entry in
      entry.descriptor.enabled && entry.snapshot != nil &&
        (requiredCoverageStart == nil || (entry.coverageStart != nil && entry.coverageStart! <= requiredCoverageStart!))
    }
    let includedIDs = Set(included.map(\.descriptor.id))
    return DashboardScope(
      requested: requested,
      includedMachineIds: included.map(\.descriptor.id),
      staleMachineIds: included.filter { collectionState($0, now: now) == .stale }.map(\.descriptor.id),
      unavailableMachineIds: selected.filter { $0.descriptor.enabled && !includedIDs.contains($0.descriptor.id) }.map(\.descriptor.id),
      generatedAt: included.compactMap { $0.snapshot?.generatedAt }.min()
    )
  }

  private func statusItem(_ entry: MachineSnapshotEntry, now: Date) -> MachineStatusResponseItem {
    let state = collectionState(entry, now: now)
    return MachineStatusResponseItem(
      id: entry.descriptor.id,
      displayName: entry.descriptor.displayName,
      kind: entry.descriptor.kind,
      enabled: entry.descriptor.enabled,
      collectionState: state,
      snapshotAvailable: entry.snapshot != nil,
      collectionInProgress: entry.collectionStatus.collectionInProgress,
      stale: state == .stale,
      coverageStart: entry.coverageStart.map(formatDay),
      snapshotGeneratedAt: entry.snapshot?.generatedAt,
      lastAttemptAt: entry.collectionStatus.lastAttemptAt,
      lastSuccessAt: entry.collectionStatus.lastSuccessAt,
      lastErrorAt: entry.collectionStatus.lastErrorAt,
      lastError: entry.collectionStatus.lastError,
      refreshIntervalSeconds: entry.collectionStatus.refreshIntervalSeconds
    )
  }

  private func collectionState(_ entry: MachineSnapshotEntry, now: Date) -> MachineCollectionState {
    guard entry.descriptor.enabled else { return .disabled }
    guard let snapshot = entry.snapshot else { return entry.collectionStatus.lastError == nil ? .neverCollected : .error }
    if entry.collectionStatus.lastError != nil || now.timeIntervalSince(snapshot.generatedAt) > Double(entry.collectionStatus.refreshIntervalSeconds * 2) {
      return .stale
    }
    return .healthy
  }

  private func orderedEntries() -> [MachineSnapshotEntry] {
    entries.values.sorted { lhs, rhs in
      if lhs.descriptor.id == "local" { return true }
      if rhs.descriptor.id == "local" { return false }
      return lhs.descriptor.id < rhs.descriptor.id
    }
  }

  private func fencedEntry(machineID: String, revision: UInt64, generation: UInt64) -> MachineSnapshotEntry? {
    guard revision == registryRevision, let entry = entries[machineID],
          entry.revision == revision, entry.generation == generation else { return nil }
    return entry
  }

  private func formatDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private static func emptyEntry(
    descriptor: MachineDescriptor,
    refreshIntervalSeconds: Int,
    revision: UInt64,
    generation: UInt64
  ) -> MachineSnapshotEntry {
    MachineSnapshotEntry(
      descriptor: descriptor,
      snapshot: nil,
      coverageStart: nil,
      loadStatus: DashboardLoadStatus(phase: .idle, message: "Waiting to load usage data", completed: 0, total: 1, isLoading: false),
      collectionStatus: MachineCollectionStatus(refreshIntervalSeconds: refreshIntervalSeconds),
      revision: revision,
      generation: generation
    )
  }

  public static func sanitizedError(_ error: Error) -> SanitizedCollectionError {
    if let ccusage = error as? CCUsageError {
      switch ccusage {
      case .commandFailed(let failure):
        switch failure.phase {
        case .spawnFailed, .timedOut, .signalled, .transportExited:
          return SanitizedCollectionError(code: "transport_failed", message: "Command transport failed")
        case .commandExited:
          return SanitizedCollectionError(code: "remote_command_failed", message: "ccusage command failed")
        }
      case .invalidJSON:
        return SanitizedCollectionError(code: "invalid_response", message: "ccusage response was invalid")
      default:
        break
      }
    }
    if error is AggregationCacheError || error is CacheLifecycleError {
      return SanitizedCollectionError(code: "cache_failed", message: "Usage cache operation failed")
    }
    return SanitizedCollectionError(code: "internal_error", message: "Collection failed")
  }
}

public actor MachineCollector {
  public typealias ServiceFactory = @Sendable (MachineDescriptor) throws -> SnapshotService

  public let store: MachineSnapshotStore
  private var registry: MachineRegistry
  private let serviceFactory: ServiceFactory
  private var services: [String: SnapshotService] = [:]
  private var generations: [String: UInt64] = [:]
  private var pollers: [String: Task<Void, Never>] = [:]
  private var inFlight: [String: Task<CostSnapshot, Error>] = [:]
  private var pendingCoverage: [String: Date] = [:]
  private let calendar: Calendar
  private let now: @Sendable () -> Date

  public init(
    registry: MachineRegistry,
    store: MachineSnapshotStore,
    calendar: Calendar = .current,
    now: @escaping @Sendable () -> Date = Date.init,
    serviceFactory: @escaping ServiceFactory
  ) throws {
    self.registry = registry
    self.store = store
    self.calendar = calendar
    self.now = now
    self.serviceFactory = serviceFactory
    for descriptor in registry.machines where descriptor.enabled {
      services[descriptor.id] = try serviceFactory(descriptor)
      generations[descriptor.id] = 0
    }
  }

  public func start() {
    for descriptor in registry.machines where descriptor.enabled { startPoller(descriptor) }
  }

  public func stop() async {
    let tasks = Array(pollers.values)
    pollers.values.forEach { $0.cancel() }
    inFlight.values.forEach { $0.cancel() }
    pollers.removeAll()
    inFlight.removeAll()
    for task in tasks { await task.value }
  }

  public func applyRegistry(_ updated: MachineRegistry) async throws {
    let old = registry
    registry = updated
    var changedIDs = Set(old.machines.map(\.id))
    changedIDs.formUnion(updated.machines.map(\.id))
    changedIDs = changedIDs.filter { old.machine(id: $0) != updated.machine(id: $0) }
    for id in changedIDs {
      generations[id, default: 0] &+= 1
      pollers[id]?.cancel()
      inFlight[id]?.cancel()
      if let poller = pollers.removeValue(forKey: id) { await poller.value }
      _ = try? await inFlight.removeValue(forKey: id)?.value
      services[id] = nil
      if let descriptor = updated.machine(id: id), descriptor.enabled {
        services[id] = try serviceFactory(descriptor)
      }
    }
    await store.replaceRegistry(updated, generations: generations)
    for id in changedIDs {
      if let descriptor = updated.machine(id: id), descriptor.enabled { startPoller(descriptor) }
    }
  }

  public func pause(machineID: String) async {
    pollers[machineID]?.cancel()
    inFlight[machineID]?.cancel()
    if let poller = pollers.removeValue(forKey: machineID) { await poller.value }
    if let load = inFlight.removeValue(forKey: machineID) { _ = try? await load.value }
  }

  public func resume(machineID: String) {
    guard let descriptor = registry.machine(id: machineID), descriptor.enabled else { return }
    startPoller(descriptor)
  }

  public func refresh(machine requested: String) async -> (succeeded: [String], failed: [String]) {
    let targets = requested == "all"
      ? registry.machines.filter(\.enabled)
      : registry.machines.filter { $0.id == requested && $0.enabled }
    return await withTaskGroup(of: (String, Bool).self) { group in
      for descriptor in targets {
        group.addTask { [weak self] in
          guard let self else { return (descriptor.id, false) }
          do { _ = try await self.collect(descriptor: descriptor, earliestDate: nil, phase: .refreshing); return (descriptor.id, true) }
          catch { return (descriptor.id, false) }
        }
      }
      var succeeded: [String] = []
      var failed: [String] = []
      for await result in group { result.1 ? succeeded.append(result.0) : failed.append(result.0) }
      return (succeeded.sorted(), failed.sorted())
    }
  }

  public func expand(machine requested: String, earliestDate: Date) async {
    let targets = requested == "all"
      ? registry.machines.filter(\.enabled)
      : registry.machines.filter { $0.id == requested && $0.enabled }
    await withTaskGroup(of: Void.self) { group in
      for descriptor in targets {
        group.addTask { [weak self] in _ = try? await self?.collect(descriptor: descriptor, earliestDate: earliestDate, phase: .loadingHistory) }
      }
    }
  }

  private func startPoller(_ descriptor: MachineDescriptor) {
    guard pollers[descriptor.id] == nil else { return }
    let generation = generations[descriptor.id, default: 0]
    let revision = registry.revision
    pollers[descriptor.id] = Task { [weak self] in
      guard let self else { return }
      let current = self.now()
      let weekStart = self.calendar.dateInterval(of: .weekOfYear, for: current)?.start ?? self.calendar.startOfDay(for: current)
      _ = try? await self.collect(descriptor: descriptor, earliestDate: weekStart, phase: .loadingWeek)
      guard !Task.isCancelled else { return }
      let monthStart = self.calendar.dateInterval(of: .month, for: current)?.start ?? weekStart
      let warmStart = self.calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
      _ = try? await self.collect(descriptor: descriptor, earliestDate: warmStart, phase: .loadingHistory)
      while !Task.isCancelled, await self.isCurrent(machineID: descriptor.id, generation: generation, revision: revision) {
        do { try await Task.sleep(for: .seconds(max(1, descriptor.id == "local" ? AppConfiguration.defaultPollIntervalSeconds : AppConfiguration.defaultPollIntervalSeconds))) }
        catch { break }
        _ = try? await self.collect(descriptor: descriptor, earliestDate: nil, phase: .refreshing)
      }
    }
  }

  private func isCurrent(machineID: String, generation: UInt64, revision: UInt64) -> Bool {
    generation == generations[machineID] && revision == registry.revision
  }

  private func collect(
    descriptor: MachineDescriptor,
    earliestDate: Date?,
    phase: DashboardLoadPhase
  ) async throws -> CostSnapshot {
    let machineID = descriptor.id
    if let earliestDate {
      pendingCoverage[machineID] = min(pendingCoverage[machineID] ?? earliestDate, earliestDate)
    }
    if let existing = inFlight[machineID] {
      let result = try await existing.value
      if let pending = pendingCoverage[machineID], let entry = await store.entry(machineID: machineID),
         entry.coverageStart == nil || entry.coverageStart! > pending {
        pendingCoverage[machineID] = nil
        return try await collect(descriptor: descriptor, earliestDate: pending, phase: .loadingHistory)
      }
      return result
    }
    guard let service = services[machineID] else { throw CancellationError() }
    let revision = registry.revision
    let generation = generations[machineID, default: 0]
    let requested = earliestDate ?? pendingCoverage[machineID]
    pendingCoverage[machineID] = nil
    let started = now()
    await store.beginCollection(
      machineID: machineID,
      revision: revision,
      generation: generation,
      phase: phase,
      requestedCoverageStart: requested,
      now: started
    )
    let task = Task { try await service.snapshot(now: started, earliestDate: requested) }
    inFlight[machineID] = task
    do {
      let snapshot = try await task.value
      inFlight[machineID] = nil
      let coverage = requested ?? calendar.dateInterval(of: .weekOfYear, for: started)?.start ?? calendar.startOfDay(for: started)
      await store.publish(
        machineID: machineID,
        snapshot: snapshot,
        coverageStart: coverage,
        revision: revision,
        generation: generation,
        now: now()
      )
      return snapshot
    } catch {
      inFlight[machineID] = nil
      if error is CancellationError {
        await store.finishCancellation(machineID: machineID, revision: revision, generation: generation)
      } else {
        await store.publishFailure(machineID: machineID, error: error, revision: revision, generation: generation, now: now())
      }
      throw error
    }
  }
}
