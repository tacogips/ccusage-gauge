import Foundation

private actor CollectionSourceIdentityBox {
  private var identity: MachineCollectionSourceIdentity?

  func set(_ identity: MachineCollectionSourceIdentity) {
    self.identity = identity
  }

  func get() -> MachineCollectionSourceIdentity? {
    identity
  }
}

extension MachineCollector {
  func collect(
    descriptor: MachineDescriptor,
    earliestDate: Date?,
    latestDate: Date?,
    phase: DashboardLoadPhase
  ) async throws -> CostSnapshot {
    let machineID = descriptor.id
    let key = MachineRangeLoadKey(machineID: machineID, start: earliestDate, end: latestDate)
    guard let service = services[machineID] else { throw CancellationError() }
    if let existing = inFlight[key] {
      let result = try await existing.value
      guard await service.isCurrentSourcePlan(result) else { throw CancellationError() }
      return result.snapshot
    }
    let revision = registry.revision
    let generation = generations[machineID, default: 0]
    let started = now()
    await store.beginCollection(
      machineID: machineID,
      revision: revision,
      generation: generation,
      phase: phase,
      requestedCoverageStart: earliestDate,
      now: started
    )
    rangeLoads[key] = MachineRangeLoadState(
      machineID: machineID,
      requestedStart: earliestDate,
      requestedEnd: latestDate,
      phase: phase,
      progress: SnapshotLoadProgress(completed: 0, total: 1),
      isLoading: true
    )
    let sourceIdentityBox = CollectionSourceIdentityBox()
    let task = Task {
      try await service.collectionSnapshot(
        now: started,
        earliestDate: earliestDate,
        latestDate: latestDate,
        progress: { [store] progress in
          let sourceIdentity = await sourceIdentityBox.get()
          await store.updateCollectionProgress(
            machineID: machineID,
            revision: revision,
            generation: generation,
            progress: progress,
            sourceIdentity: sourceIdentity
          )
          await self.updateRangeProgress(key: key, phase: phase, progress: progress)
        },
        sourceAttemptStarted: { [store] identity in
          await sourceIdentityBox.set(identity)
          await store.beginSourceAttempt(
            machineID: machineID,
            identity: identity,
            revision: revision,
            generation: generation
          )
        }
      )
    }
    inFlight[key] = task
    do {
      let result = try await task.value
      inFlight[key] = nil
      guard await service.isCurrentSourcePlan(result) else {
        throw CancellationError()
      }
      finishRange(key: key, phase: .ready, failed: false)
      let coverage = earliestDate
        ?? calendar.dateInterval(of: .weekOfYear, for: started)?.start
        ?? calendar.startOfDay(for: started)
      await store.publish(
        machineID: machineID,
        snapshot: result.snapshot,
        coverageStart: coverage,
        revision: revision,
        generation: generation,
        now: now(),
        sourceIdentity: result.sourceIdentity
      )
      return result.snapshot
    } catch {
      inFlight[key] = nil
      let sourceIdentity = await sourceIdentityBox.get()
      finishRange(
        key: key,
        phase: error is CancellationError ? .idle : .failed,
        failed: !(error is CancellationError)
      )
      if error is CancellationError {
        await store.finishCancellation(
          machineID: machineID,
          revision: revision,
          generation: generation,
          sourceIdentity: sourceIdentity
        )
      } else {
        await store.publishFailure(
          machineID: machineID,
          error: error,
          revision: revision,
          generation: generation,
          now: now(),
          sourceIdentity: sourceIdentity
        )
      }
      throw error
    }
  }

  private func updateRangeProgress(
    key: MachineRangeLoadKey,
    phase: DashboardLoadPhase,
    progress: SnapshotLoadProgress
  ) {
    rangeLoads[key] = MachineRangeLoadState(
      machineID: key.machineID,
      requestedStart: key.start,
      requestedEnd: key.end,
      phase: phase,
      progress: progress,
      isLoading: true
    )
  }

  private func finishRange(
    key: MachineRangeLoadKey,
    phase: DashboardLoadPhase,
    failed: Bool
  ) {
    let progress = rangeLoads[key]?.progress ?? SnapshotLoadProgress(completed: 0, total: 1)
    rangeLoads[key] = MachineRangeLoadState(
      machineID: key.machineID,
      requestedStart: key.start,
      requestedEnd: key.end,
      phase: phase,
      progress: failed
        ? progress
        : SnapshotLoadProgress(
          completed: max(progress.completed, progress.total),
          total: max(progress.total, 1)
        ),
      isLoading: false,
      failed: failed
    )
  }
}
