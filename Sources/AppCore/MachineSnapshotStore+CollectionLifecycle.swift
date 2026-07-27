import Foundation

extension MachineSnapshotStore {
  func beginSourceAttempt(
    machineID: String,
    identity: MachineCollectionSourceIdentity,
    revision: UInt64,
    generation: UInt64
  ) {
    guard fencedEntry(machineID: machineID, revision: revision, generation: generation) != nil else { return }
    sourceIdentities[machineID] = identity
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

  public func updateCollectionProgress(
    machineID: String,
    revision: UInt64,
    generation: UInt64,
    progress: SnapshotLoadProgress
  ) {
    updateCollectionProgress(
      machineID: machineID,
      revision: revision,
      generation: generation,
      progress: progress,
      matching: nil
    )
  }

  func updateCollectionProgress(
    machineID: String,
    revision: UInt64,
    generation: UInt64,
    progress: SnapshotLoadProgress,
    sourceIdentity: MachineCollectionSourceIdentity?
  ) {
    updateCollectionProgress(
      machineID: machineID,
      revision: revision,
      generation: generation,
      progress: progress,
      matching: sourceIdentity
    )
  }

  private func updateCollectionProgress(
    machineID: String,
    revision: UInt64,
    generation: UInt64,
    progress: SnapshotLoadProgress,
    matching sourceIdentity: MachineCollectionSourceIdentity?
  ) {
    guard var entry = fencedEntry(machineID: machineID, revision: revision, generation: generation),
          sourceIdentityMatches(machineID: machineID, identity: sourceIdentity),
          entry.collectionStatus.collectionInProgress else { return }
    entry.loadStatus = DashboardLoadStatus(
      phase: entry.loadStatus.phase,
      message: entry.loadStatus.message,
      completed: min(max(0, progress.completed), max(progress.total, 1)),
      total: max(progress.total, 1),
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
    publish(
      machineID: machineID,
      snapshot: snapshot,
      coverageStart: coverageStart,
      revision: revision,
      generation: generation,
      now: now,
      matching: nil
    )
  }

  func publish(
    machineID: String,
    snapshot: CostSnapshot,
    coverageStart: Date,
    revision: UInt64,
    generation: UInt64,
    now: Date,
    sourceIdentity: MachineCollectionSourceIdentity?
  ) {
    publish(
      machineID: machineID,
      snapshot: snapshot,
      coverageStart: coverageStart,
      revision: revision,
      generation: generation,
      now: now,
      matching: sourceIdentity
    )
  }

  private func publish(
    machineID: String,
    snapshot: CostSnapshot,
    coverageStart: Date,
    revision: UInt64,
    generation: UInt64,
    now: Date,
    matching sourceIdentity: MachineCollectionSourceIdentity?
  ) {
    guard var entry = fencedEntry(machineID: machineID, revision: revision, generation: generation),
          sourceIdentityMatches(machineID: machineID, identity: sourceIdentity) else { return }
    entry.snapshot = mergingSnapshots(existing: entry.snapshot, fresh: snapshot, calendar: calendar)
    entry.coverageStart = min(entry.coverageStart ?? coverageStart, coverageStart)
    entry.collectionStatus.lastSuccessAt = now
    entry.collectionStatus.lastErrorAt = nil
    entry.collectionStatus.lastError = nil
    entry.collectionStatus.collectionInProgress = false
    entry.collectionStatus.consecutiveFailureCount = 0
    entry.collectionStatus.unavailableSince = nil
    let total = max(entry.loadStatus.total, 1)
    entry.loadStatus = DashboardLoadStatus(
      phase: .ready,
      message: "Usage data is ready",
      completed: total,
      total: total,
      isLoading: false
    )
    entries[machineID] = entry
    invalidateMergeCache()
  }

  public func publishFailure(
    machineID: String,
    error: Error,
    revision: UInt64,
    generation: UInt64,
    now: Date
  ) {
    publishFailure(
      machineID: machineID,
      error: error,
      revision: revision,
      generation: generation,
      now: now,
      matching: nil
    )
  }

  func publishFailure(
    machineID: String,
    error: Error,
    revision: UInt64,
    generation: UInt64,
    now: Date,
    sourceIdentity: MachineCollectionSourceIdentity?
  ) {
    publishFailure(
      machineID: machineID,
      error: error,
      revision: revision,
      generation: generation,
      now: now,
      matching: sourceIdentity
    )
  }

  private func publishFailure(
    machineID: String,
    error: Error,
    revision: UInt64,
    generation: UInt64,
    now: Date,
    matching sourceIdentity: MachineCollectionSourceIdentity?
  ) {
    guard !(error is CancellationError),
          var entry = fencedEntry(machineID: machineID, revision: revision, generation: generation),
          sourceIdentityMatches(machineID: machineID, identity: sourceIdentity) else { return }
    if entry.collectionStatus.consecutiveFailureCount == 0 {
      entry.collectionStatus.unavailableSince = now
    }
    entry.collectionStatus.consecutiveFailureCount += 1
    entry.collectionStatus.lastErrorAt = now
    entry.collectionStatus.lastError = Self.sanitizedError(error)
    entry.collectionStatus.collectionInProgress = false
    let total = max(entry.loadStatus.total, 1)
    entry.loadStatus = DashboardLoadStatus(
      phase: .failed,
      message: "Usage data loading failed",
      completed: total,
      total: total,
      isLoading: false
    )
    entries[machineID] = entry
  }

  public func finishCancellation(
    machineID: String,
    revision: UInt64,
    generation: UInt64
  ) {
    finishCancellation(
      machineID: machineID,
      revision: revision,
      generation: generation,
      matching: nil
    )
  }

  func finishCancellation(
    machineID: String,
    revision: UInt64,
    generation: UInt64,
    sourceIdentity: MachineCollectionSourceIdentity?
  ) {
    finishCancellation(
      machineID: machineID,
      revision: revision,
      generation: generation,
      matching: sourceIdentity
    )
  }

  private func finishCancellation(
    machineID: String,
    revision: UInt64,
    generation: UInt64,
    matching sourceIdentity: MachineCollectionSourceIdentity?
  ) {
    guard var entry = fencedEntry(machineID: machineID, revision: revision, generation: generation),
          sourceIdentityMatches(machineID: machineID, identity: sourceIdentity) else { return }
    entry.collectionStatus.collectionInProgress = false
    let total = max(entry.loadStatus.total, 1)
    entry.loadStatus = DashboardLoadStatus(
      phase: .idle,
      message: "Usage data loading was cancelled",
      completed: total,
      total: total,
      isLoading: false
    )
    entries[machineID] = entry
  }
}
