import Foundation
import Testing
@testable import AppCore

@Suite struct MachineLoadStatusTests {
  @Test func cancellationEndsLoadingWithCompletedIdleStatus() async throws {
    let store = MachineSnapshotStore(
      registry: try MachineRegistry(sshMachines: []),
      refreshIntervalSeconds: 20
    )
    await store.beginCollection(
      machineID: "local",
      revision: 0,
      generation: 0,
      phase: .refreshing,
      requestedCoverageStart: nil,
      now: Date()
    )
    await store.updateCollectionProgress(
      machineID: "local",
      revision: 0,
      generation: 0,
      progress: SnapshotLoadProgress(completed: 2, total: 7)
    )

    await store.finishCancellation(machineID: "local", revision: 0, generation: 0)

    let status = try await store.loadStatuses(machine: "local")[0].1
    #expect(status.phase == .idle)
    #expect(status.message == "Usage data loading was cancelled")
    #expect(status.completed == 7)
    #expect(status.total == 7)
    #expect(!status.isLoading)
  }
}
