import Foundation

struct MachineRangeLoadKey: Hashable, Sendable {
  let machineID: String
  let start: Date?
  let end: Date?
}

public struct MachineRangeLoadState: Equatable, Sendable {
  public let machineID: String
  public let requestedStart: Date?
  public let requestedEnd: Date?
  public let phase: DashboardLoadPhase
  public let progress: SnapshotLoadProgress
  public let isLoading: Bool
  public let failed: Bool

  public init(
    machineID: String,
    requestedStart: Date?,
    requestedEnd: Date?,
    phase: DashboardLoadPhase,
    progress: SnapshotLoadProgress,
    isLoading: Bool,
    failed: Bool = false
  ) {
    self.machineID = machineID
    self.requestedStart = requestedStart
    self.requestedEnd = requestedEnd
    self.phase = phase
    self.progress = progress
    self.isLoading = isLoading
    self.failed = failed
  }
}
