import Foundation

public struct SanitizedCollectionError: Codable, Equatable, Sendable {
  public let code: String
  public let message: String
  public let detail: String?
  public let remediation: String?

  public init(code: String, message: String, detail: String? = nil, remediation: String? = nil) {
    self.code = code
    self.message = message
    self.detail = detail
    self.remediation = remediation
  }
}

public struct MachineCollectionStatus: Equatable, Sendable {
  public var lastAttemptAt: Date?
  public var lastSuccessAt: Date?
  public var lastErrorAt: Date?
  public var lastError: SanitizedCollectionError?
  public var collectionInProgress: Bool
  public var consecutiveFailureCount: Int
  public var unavailableSince: Date?
  public let statusTrackingStartedAt: Date
  public let refreshIntervalSeconds: Int

  public init(refreshIntervalSeconds: Int, statusTrackingStartedAt: Date = Date()) {
    lastAttemptAt = nil
    lastSuccessAt = nil
    lastErrorAt = nil
    lastError = nil
    collectionInProgress = false
    consecutiveFailureCount = 0
    unavailableSince = nil
    self.statusTrackingStartedAt = statusTrackingStartedAt
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

public struct MachineStatusResponse: Codable, Equatable, Sendable {
  public let requested: String
  public let generatedAt: Date
  public let machines: [MachineStatusResponseItem]
}

public enum DashboardDataDisposition: String, Codable, Equatable, Sendable {
  case current
  case historical
}

public enum MachineAvailabilityReason: String, Codable, Equatable, Sendable {
  case collectionStale = "collection_stale"
  case neverCollected = "never_collected"
  case tunnelUnreachable = "tunnel_unreachable"
  case authFailed = "auth_failed"
  case hostKeyVerificationFailed = "host_key_verification_failed"
  case timeout
  case transportFailed = "transport_failed"
  case remoteCommandFailed = "remote_command_failed"
  case invalidResponse = "invalid_response"
  case cacheFailed = "cache_failed"
  case executableUnavailable = "executable_unavailable"
  case insufficientCoverage = "insufficient_coverage"
  case internalError = "internal_error"

  init(diagnosticCode: String?) {
    self = diagnosticCode.flatMap(Self.init(rawValue:)) ?? .collectionStale
  }
}

public struct MachineAvailability: Codable, Equatable, Sendable {
  public let machine: String
  public let available: Bool
  public let unavailableSince: Date
  public let reasonCode: MachineAvailabilityReason
}

public struct MachineDataGap: Codable, Equatable, Sendable {
  public let machine: String
  public let startAt: Date
  public let endAt: Date
  public let reasonCode: MachineAvailabilityReason
}

public struct MachineStatusDataGap: Codable, Equatable, Sendable {
  public let startAt: Date
  public let endAt: Date
}

public struct MachineLatestEvent: Codable, Equatable, Sendable {
  public let machine: String
  public let latestEventAt: Date?
  public let markerState: String
  public let inLastHour: Bool
  public let dataQuality: UsageDataQuality?
}

public struct DashboardScope: Codable, Equatable, Sendable {
  public let requested: String
  public let dataDisposition: DashboardDataDisposition
  public let includedMachineIds: [String]
  public let staleMachineIds: [String]
  public let unavailableMachineIds: [String]
  public let excludedFromCurrentTotalsMachineIds: [String]
  public let machineAvailability: [MachineAvailability]
  public let lastHourDataGaps: [MachineDataGap]
  public let evaluatedAt: Date
  public let generatedAt: Date?

  public init(
    requested: String,
    dataDisposition: DashboardDataDisposition = .historical,
    includedMachineIds: [String],
    staleMachineIds: [String],
    unavailableMachineIds: [String],
    excludedFromCurrentTotalsMachineIds: [String] = [],
    machineAvailability: [MachineAvailability] = [],
    lastHourDataGaps: [MachineDataGap] = [],
    evaluatedAt: Date = Date(),
    generatedAt: Date?
  ) {
    self.requested = requested
    self.dataDisposition = dataDisposition
    self.includedMachineIds = includedMachineIds
    self.staleMachineIds = staleMachineIds
    self.unavailableMachineIds = unavailableMachineIds
    self.excludedFromCurrentTotalsMachineIds = excludedFromCurrentTotalsMachineIds
    self.machineAvailability = machineAvailability
    self.lastHourDataGaps = lastHourDataGaps
    self.evaluatedAt = evaluatedAt
    self.generatedAt = generatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case requested
    case dataDisposition
    case includedMachineIds
    case staleMachineIds
    case unavailableMachineIds
    case excludedFromCurrentTotalsMachineIds
    case machineAvailability
    case lastHourDataGaps
    case evaluatedAt
    case generatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    requested = try container.decode(String.self, forKey: .requested)
    dataDisposition = try container.decodeIfPresent(DashboardDataDisposition.self, forKey: .dataDisposition) ?? .historical
    includedMachineIds = try container.decode([String].self, forKey: .includedMachineIds)
    staleMachineIds = try container.decode([String].self, forKey: .staleMachineIds)
    unavailableMachineIds = try container.decode([String].self, forKey: .unavailableMachineIds)
    excludedFromCurrentTotalsMachineIds =
      try container.decodeIfPresent([String].self, forKey: .excludedFromCurrentTotalsMachineIds) ?? []
    machineAvailability = try container.decodeIfPresent([MachineAvailability].self, forKey: .machineAvailability) ?? []
    lastHourDataGaps = try container.decodeIfPresent([MachineDataGap].self, forKey: .lastHourDataGaps) ?? []
    evaluatedAt = try container.decodeIfPresent(Date.self, forKey: .evaluatedAt) ?? Date(timeIntervalSince1970: 0)
    generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt)
  }
}

public struct MachineSnapshotSelection: Sendable {
  public let snapshot: CostSnapshot?
  public let scope: DashboardScope
  public let collectionState: MachineCollectionState?
  public let refreshIntervalSeconds: Int
  public let machineLatestEvents: [MachineLatestEvent]
}

public enum MachineSelectionError: Error, Equatable, Sendable {
  case invalid
  case notFound(String)
  case disabled(String)
  case unavailable(String, MachineCollectionState, Int)
  case aggregateUnavailable(Int)
  case currentDataUnavailable(String, MachineCollectionState, Int, DashboardScope)
  case aggregateCurrentDataUnavailable(Int, DashboardScope)
  case rangeUnavailable(String, Date, Date?, Int)
  case aggregateRangeUnavailable(Date, Int)
}

public actor MachineSnapshotStore {
  private var entries: [String: MachineSnapshotEntry] = [:]
  private var registryRevision: UInt64
  private let calendar: Calendar

  /// Identity of one included snapshot in a merge: republishing, clearing, or replacing the
  /// registry mutates `generatedAt` or the entry set, so the composite key naturally changes.
  private struct MergeEntryKey: Equatable {
    let id: String
    let generatedAt: Date
  }

  /// The `now`-independent portion of a merged aggregate. Interval-dependent scalar fields
  /// (active boundary, cost, budget spend) are recomputed per request from these cached arrays.
  private struct MergedAggregate {
    let points: [CCUsageCostRecord]
    let metrics: [CCUsageMetricRecord]
    let sessions: [CCUsageSessionMetricRecord]
    let generatedAt: Date
    let resetCycle: ResetCycle
    let activeBoundaryFallback: Date
    let budgetUSD: Decimal?
    let refreshIntervalSeconds: Int
  }

  private var mergeCache: (key: [MergeEntryKey], value: MergedAggregate)?

  /// Number of times the aggregate arrays were rebuilt from scratch. Test-only observability for
  /// the merge memoization; unchanged inputs across requests must not increment it.
  private(set) var mergeComputations = 0

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
    mergeCache = nil
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
    entry.collectionStatus.consecutiveFailureCount = 0
    entry.collectionStatus.unavailableSince = nil
    entry.loadStatus = DashboardLoadStatus(phase: .ready, message: "Usage data is ready", completed: 1, total: 1, isLoading: false)
    entries[machineID] = entry
    mergeCache = nil
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
    if entry.collectionStatus.consecutiveFailureCount == 0 {
      entry.collectionStatus.unavailableSince = now
    }
    entry.collectionStatus.consecutiveFailureCount += 1
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
    entry.collectionStatus.consecutiveFailureCount = 0
    entry.collectionStatus.unavailableSince = nil
    entries[machineID] = entry
    mergeCache = nil
  }

  public func selection(
    machine requested: String,
    now: Date = Date(),
    requiredCoverageStart: Date? = nil,
    dataDisposition: DashboardDataDisposition = .historical
  ) throws -> MachineSnapshotSelection {
    if requested == "all" {
      return try aggregateSelection(
        now: now,
        requiredCoverageStart: requiredCoverageStart,
        dataDisposition: dataDisposition
      )
    }
    guard let entry = entries[requested] else { throw MachineSelectionError.notFound(requested) }
    let state = collectionState(entry, now: now)
    let scope = scope(
      requested: requested,
      selected: [entry],
      now: now,
      requiredCoverageStart: requiredCoverageStart,
      dataDisposition: dataDisposition
    )
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
    if dataDisposition == .current, state != .healthy {
      throw MachineSelectionError.currentDataUnavailable(
        requested,
        state,
        entry.collectionStatus.refreshIntervalSeconds,
        scope
      )
    }
    return MachineSnapshotSelection(
      snapshot: snapshot,
      scope: scope,
      collectionState: state,
      refreshIntervalSeconds: entry.collectionStatus.refreshIntervalSeconds,
      machineLatestEvents: latestEvents(for: [entry], now: now)
    )
  }

  public func observabilityScope(
    machine requested: String,
    now: Date = Date(),
    requiredCoverageStart: Date? = nil,
    dataDisposition: DashboardDataDisposition = .historical
  ) throws -> DashboardScope {
    let selected: [MachineSnapshotEntry]
    if requested == "all" {
      selected = orderedEntries().filter(\.descriptor.enabled)
    } else if let entry = entries[requested] {
      selected = [entry]
    } else {
      throw MachineSelectionError.notFound(requested)
    }
    return scope(
      requested: requested,
      selected: selected,
      now: now,
      requiredCoverageStart: requiredCoverageStart,
      dataDisposition: dataDisposition
    )
  }

  public func latestEvents(machine requested: String, now: Date = Date()) throws -> [MachineLatestEvent] {
    if requested == "all" {
      return latestEvents(for: orderedEntries().filter(\.descriptor.enabled), now: now)
    }
    guard let entry = entries[requested] else { throw MachineSelectionError.notFound(requested) }
    return latestEvents(for: [entry], now: now)
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

  private func aggregateSelection(
    now: Date,
    requiredCoverageStart: Date?,
    dataDisposition: DashboardDataDisposition
  ) throws -> MachineSnapshotSelection {
    let enabled = orderedEntries().filter(\.descriptor.enabled)
    let covering = enabled.filter { entry in
      entry.snapshot != nil &&
        (requiredCoverageStart == nil || (entry.coverageStart != nil && entry.coverageStart! <= requiredCoverageStart!))
    }
    let usable = covering.filter {
      dataDisposition == .historical || collectionState($0, now: now) == .healthy
    }
    let scope = scope(
      requested: "all",
      selected: enabled,
      now: now,
      requiredCoverageStart: requiredCoverageStart,
      dataDisposition: dataDisposition
    )
    let refresh = enabled.map(\.collectionStatus.refreshIntervalSeconds).filter { $0 > 0 }.min()
      ?? AppConfiguration.defaultPollIntervalSeconds
    guard !usable.isEmpty else {
      if let requiredCoverageStart, covering.isEmpty {
        throw MachineSelectionError.aggregateRangeUnavailable(requiredCoverageStart, refresh)
      }
      if dataDisposition == .current {
        throw MachineSelectionError.aggregateCurrentDataUnavailable(refresh, scope)
      }
      throw MachineSelectionError.aggregateUnavailable(refresh)
    }
    return MachineSnapshotSelection(
      snapshot: merge(usable: usable, now: now),
      scope: scope,
      collectionState: nil,
      refreshIntervalSeconds: refresh,
      machineLatestEvents: latestEvents(for: enabled, now: now)
    )
  }

  private func merge(usable: [MachineSnapshotEntry], now: Date) -> CostSnapshot {
    let key = usable.map { MergeEntryKey(id: $0.descriptor.id, generatedAt: $0.snapshot?.generatedAt ?? .distantPast) }
    let merged: MergedAggregate
    if let cache = mergeCache, cache.key == key {
      merged = cache.value
    } else {
      merged = buildMergedAggregate(usable.compactMap(\.snapshot), now: now)
      mergeCache = (key, merged)
    }
    // `merge` depends on `now` only through the reset interval, so the arrays are cached while the
    // interval-dependent scalars are recomputed each request from the cached metrics/sessions.
    let interval = (try? ResetWindowCalculator(calendar: calendar).aggregationInterval(for: merged.resetCycle, now: now))
      ?? DateInterval(start: merged.activeBoundaryFallback, end: now)
    let cost = selectedPeriodCost(cycle: merged.resetCycle, interval: interval, metrics: merged.metrics, sessions: merged.sessions, calendar: calendar)
    return CostSnapshot(
      generatedAt: merged.generatedAt,
      activeBoundaryAt: interval.start,
      costSinceResetUSD: cost,
      budget: BudgetSummary(spentUSD: cost, budgetUSD: merged.budgetUSD),
      resetCycle: merged.resetCycle,
      refreshIntervalSeconds: merged.refreshIntervalSeconds,
      points: merged.points,
      dashboardMetrics: merged.metrics,
      dashboardSessions: merged.sessions
    )
  }

  private func buildMergedAggregate(_ snapshots: [CostSnapshot], now: Date) -> MergedAggregate {
    mergeComputations += 1
    let exemplar = snapshots[0]
    return MergedAggregate(
      points: snapshots.flatMap(\.points),
      metrics: snapshots.flatMap(\.dashboardMetrics),
      sessions: snapshots.flatMap(\.dashboardSessions),
      generatedAt: snapshots.map(\.generatedAt).min() ?? now,
      resetCycle: exemplar.resetCycle,
      activeBoundaryFallback: exemplar.activeBoundaryAt,
      budgetUSD: exemplar.budget.budgetUSD,
      refreshIntervalSeconds: snapshots.map(\.refreshIntervalSeconds).filter { $0 > 0 }.min() ?? exemplar.refreshIntervalSeconds
    )
  }

  private func scope(
    requested: String,
    selected: [MachineSnapshotEntry],
    now: Date,
    requiredCoverageStart: Date?,
    dataDisposition: DashboardDataDisposition
  ) -> DashboardScope {
    let included = selected.filter { entry in
      entry.descriptor.enabled && entry.snapshot != nil &&
        (requiredCoverageStart == nil || (entry.coverageStart != nil && entry.coverageStart! <= requiredCoverageStart!)) &&
        (dataDisposition == .historical || collectionState(entry, now: now) == .healthy)
    }
    let includedIDs = Set(included.map(\.descriptor.id))
    let coveringIDs = Set(selected.filter { entry in
      entry.descriptor.enabled && entry.snapshot != nil &&
        (requiredCoverageStart == nil || (entry.coverageStart != nil && entry.coverageStart! <= requiredCoverageStart!))
    }.map(\.descriptor.id))
    let excluded = dataDisposition == .current
      ? selected.filter { $0.descriptor.enabled && !includedIDs.contains($0.descriptor.id) }
      : []
    let availability = excluded.map { entry -> MachineAvailability in
      let state = collectionState(entry, now: now)
      return MachineAvailability(
        machine: entry.descriptor.id,
        available: false,
        unavailableSince: unavailableSince(entry, state: state, now: now),
        reasonCode: availabilityReason(entry, state: state)
      )
    }
    return DashboardScope(
      requested: requested,
      dataDisposition: dataDisposition,
      includedMachineIds: included.map(\.descriptor.id),
      staleMachineIds: selected.filter {
        coveringIDs.contains($0.descriptor.id) && collectionState($0, now: now) == .stale
      }.map(\.descriptor.id),
      unavailableMachineIds: selected.filter {
        $0.descriptor.enabled && !coveringIDs.contains($0.descriptor.id)
      }.map(\.descriptor.id),
      excludedFromCurrentTotalsMachineIds: excluded.map(\.descriptor.id),
      machineAvailability: availability,
      lastHourDataGaps: availability.compactMap { value in
        // A healthy machine excluded only for range coverage has
        // unavailableSince == now; a zero-length gap is not a gap.
        guard value.unavailableSince < now else { return nil }
        return MachineDataGap(
          machine: value.machine,
          startAt: max(value.unavailableSince, now.addingTimeInterval(-3_600)),
          endAt: now,
          reasonCode: value.reasonCode
        )
      },
      evaluatedAt: now,
      generatedAt: included.compactMap { $0.snapshot?.generatedAt }.min()
    )
  }

  private func statusItem(_ entry: MachineSnapshotEntry, now: Date) -> MachineStatusResponseItem {
    let state = collectionState(entry, now: now)
    let staleSince = staleSince(entry, state: state, now: now)
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
      consecutiveFailureCount: entry.collectionStatus.consecutiveFailureCount,
      unavailableSince: statusUnavailableSince(entry, state: state, now: now),
      staleSince: staleSince,
      lastErrorAt: entry.collectionStatus.lastErrorAt,
      lastError: entry.collectionStatus.lastError,
      lastHourDataGap: staleSince.map {
        MachineStatusDataGap(startAt: max($0, now.addingTimeInterval(-3_600)), endAt: now)
      },
      refreshIntervalSeconds: entry.collectionStatus.refreshIntervalSeconds
    )
  }

  private func staleSince(_ entry: MachineSnapshotEntry, state: MachineCollectionState, now: Date) -> Date? {
    guard state == .stale, let generatedAt = entry.snapshot?.generatedAt else { return nil }
    let ageStaleAt = generatedAt.addingTimeInterval(Double(entry.collectionStatus.refreshIntervalSeconds * 2))
    if let failure = entry.collectionStatus.unavailableSince {
      return min(failure, ageStaleAt)
    }
    return ageStaleAt <= now ? ageStaleAt : nil
  }

  private func unavailableSince(
    _ entry: MachineSnapshotEntry,
    state: MachineCollectionState,
    now: Date
  ) -> Date {
    switch state {
    case .stale:
      return staleSince(entry, state: state, now: now) ?? entry.collectionStatus.statusTrackingStartedAt
    case .error:
      return entry.collectionStatus.unavailableSince ?? entry.collectionStatus.statusTrackingStartedAt
    case .neverCollected:
      return min(
        entry.collectionStatus.unavailableSince ?? entry.collectionStatus.statusTrackingStartedAt,
        entry.collectionStatus.statusTrackingStartedAt
      )
    case .disabled:
      return entry.collectionStatus.statusTrackingStartedAt
    case .healthy:
      return now
    }
  }

  private func statusUnavailableSince(
    _ entry: MachineSnapshotEntry,
    state: MachineCollectionState,
    now: Date
  ) -> Date? {
    guard state != .healthy, state != .disabled else { return nil }
    return unavailableSince(entry, state: state, now: now)
  }

  private func availabilityReason(
    _ entry: MachineSnapshotEntry,
    state: MachineCollectionState
  ) -> MachineAvailabilityReason {
    if state == .healthy { return .insufficientCoverage }
    if state == .neverCollected { return .neverCollected }
    if state == .stale, entry.collectionStatus.lastError == nil { return .collectionStale }
    return MachineAvailabilityReason(diagnosticCode: entry.collectionStatus.lastError?.code)
  }

  private func latestEvents(
    for values: [MachineSnapshotEntry],
    now: Date
  ) -> [MachineLatestEvent] {
    values.map { entry in
      let state = collectionState(entry, now: now)
      let latest = entry.snapshot?.dashboardSessions.max(by: { $0.timestamp < $1.timestamp })
      let marker: String
      if state == .stale {
        marker = "stale"
      } else if [.disabled, .error, .neverCollected].contains(state) {
        marker = "unavailable"
      } else {
        marker = latest == nil ? "noEvent" : "observed"
      }
      return MachineLatestEvent(
        machine: entry.descriptor.id,
        latestEventAt: latest?.timestamp,
        markerState: marker,
        inLastHour: latest.map { $0.timestamp >= now.addingTimeInterval(-3_600) && $0.timestamp <= now } ?? false,
        dataQuality: latest?.dataQuality
      )
    }
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
    MachineDiagnosticClassifier.classify(error)
  }
}

public actor MachineCollector: MachineRegistryRuntimeReconciler {
  public typealias ServiceFactory = @Sendable (MachineDescriptor) throws -> SnapshotService
  public typealias ConnectionTester = @Sendable (MachineDescriptor) async throws -> Void

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
  private let connectionTester: ConnectionTester

  public init(
    registry: MachineRegistry,
    store: MachineSnapshotStore,
    calendar: Calendar = .current,
    now: @escaping @Sendable () -> Date = Date.init,
    connectionTester: ConnectionTester? = nil,
    serviceFactory: @escaping ServiceFactory
  ) throws {
    self.registry = registry
    self.store = store
    self.calendar = calendar
    self.now = now
    self.serviceFactory = serviceFactory
    self.connectionTester = connectionTester ?? { descriptor in
      guard let connection = descriptor.ssh else { throw MachineSelectionError.notFound(descriptor.id) }
      _ = try await SSHCCUsageCommandRunner(connection: connection).run(
        arguments: ["--version"],
        timeoutSeconds: 30
      )
    }
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

  public func reconcileRegistry(_ updated: MachineRegistry) async throws {
    let old = registry
    var changedIDs = Set(old.machines.map(\.id))
    changedIDs.formUnion(updated.machines.map(\.id))
    changedIDs = changedIDs.filter { old.machine(id: $0) != updated.machine(id: $0) }
    var replacements: [String: SnapshotService] = [:]
    for id in changedIDs {
      if let descriptor = updated.machine(id: id), descriptor.enabled {
        replacements[id] = try serviceFactory(descriptor)
      }
    }

    // Runtime construction is the only throwing phase. Do not publish the
    // registry, cancel a poller, or alter snapshot state until every changed
    // enabled descriptor has a usable replacement service.
    registry = updated
    for id in changedIDs {
      generations[id, default: 0] &+= 1
      pollers[id]?.cancel()
      inFlight[id]?.cancel()
      if let poller = pollers.removeValue(forKey: id) { await poller.value }
      _ = try? await inFlight.removeValue(forKey: id)?.value
      services[id] = replacements[id]
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

  public func testConnection(machineID: String) async throws {
    guard let descriptor = registry.machine(id: machineID) else {
      throw MachineSelectionError.notFound(machineID)
    }
    guard descriptor.enabled else {
      throw MachineSelectionError.disabled(machineID)
    }
    try await connectionTester(descriptor)
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
        group.addTask { [weak self] in
          guard let self else { return }
          // Serve from the published snapshot when its coverage already satisfies the request:
          // a steady-state filter switch then never spawns ccusage. Only machines whose coverage
          // is missing or narrower than requested await a fresh collection.
          if let entry = await self.store.entry(machineID: descriptor.id),
             entry.snapshot != nil,
             let coverage = entry.coverageStart, coverage <= earliestDate {
            return
          }
          _ = try? await self.collect(descriptor: descriptor, earliestDate: earliestDate, phase: .loadingHistory)
        }
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
        do { try await Task.sleep(for: .seconds(max(1, AppConfiguration.defaultPollIntervalSeconds))) }
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
