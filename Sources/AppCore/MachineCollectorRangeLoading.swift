import Foundation

extension MachineCollector {
  func collect(
    descriptor: MachineDescriptor,
    earliestDate: Date?,
    latestDate: Date?,
    phase: DashboardLoadPhase
  ) async throws -> CostSnapshot {
    let machineID = descriptor.id
    let key = MachineRangeLoadKey(machineID: machineID, start: earliestDate, end: latestDate)
    if let existing = inFlight[key] { return try await existing.value }
    guard let service = services[machineID] else { throw CancellationError() }
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
    let task = Task {
      try await service.snapshot(
        now: started,
        earliestDate: earliestDate,
        latestDate: latestDate,
        progress: { [store] progress in
          await store.updateCollectionProgress(
            machineID: machineID,
            revision: revision,
            generation: generation,
            progress: progress
          )
          await self.updateRangeProgress(key: key, phase: phase, progress: progress)
        }
      )
    }
    inFlight[key] = task
    do {
      let snapshot = try await task.value
      inFlight[key] = nil
      finishRange(key: key, phase: .ready, failed: false)
      let coverage = earliestDate
        ?? calendar.dateInterval(of: .weekOfYear, for: started)?.start
        ?? calendar.startOfDay(for: started)
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
      inFlight[key] = nil
      finishRange(
        key: key,
        phase: error is CancellationError ? .idle : .failed,
        failed: !(error is CancellationError)
      )
      if error is CancellationError {
        await store.finishCancellation(machineID: machineID, revision: revision, generation: generation)
      } else {
        await store.publishFailure(
          machineID: machineID,
          error: error,
          revision: revision,
          generation: generation,
          now: now()
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
