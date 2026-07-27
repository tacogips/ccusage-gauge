import Foundation

struct MachineCollectionSourceIdentity: Equatable, Sendable {
  let fingerprint: String
  let generation: UInt64
}

struct MachineCollectionSnapshotResult: Sendable {
  let snapshot: CostSnapshot
  let sourceIdentity: MachineCollectionSourceIdentity?
}

struct SessionSourceAttemptContext: Sendable {
  let plan: MachineSessionSourcePlan
  let cacheGeneration: UInt64?
  let publicationGeneration: UInt64
}

extension SnapshotService {
  func collectionSnapshot(
    now: Date,
    earliestDate: Date?,
    latestDate: Date?,
    progress: SnapshotLoadProgressHandler?,
    sourceAttemptStarted: @escaping @Sendable (MachineCollectionSourceIdentity) async -> Void = { _ in }
  ) async throws -> MachineCollectionSnapshotResult {
    if let attempt = try await beginSessionSourceAttempt() {
      let identity = MachineCollectionSourceIdentity(
        fingerprint: attempt.plan.fingerprint,
        generation: attempt.publicationGeneration
      )
      await sourceAttemptStarted(identity)
      let collectedSnapshot: CostSnapshot = try await withSessionSourceAttempt(attempt) {
        try await snapshot(
          now: now,
          earliestDate: earliestDate,
          latestDate: latestDate,
          progress: progress
        )
      }
      return MachineCollectionSnapshotResult(
        snapshot: collectedSnapshot,
        sourceIdentity: identity
      )
    }
    return MachineCollectionSnapshotResult(
      snapshot: try await snapshot(
        now: now,
        earliestDate: earliestDate,
        latestDate: latestDate,
        progress: progress
      ),
      sourceIdentity: MachineSessionSourceAttempt.plan.flatMap { plan in
        MachineSessionSourceAttempt.publicationGeneration.map {
          MachineCollectionSourceIdentity(fingerprint: plan.fingerprint, generation: $0)
        }
      }
    )
  }

  func isCurrentSourcePlan(_ result: MachineCollectionSnapshotResult) async -> Bool {
    guard let identity = result.sourceIdentity else { return true }
    return await sourceGenerationFence.isCurrent(
      fingerprint: identity.fingerprint,
      generation: identity.generation
    )
  }

  func beginSessionSourceAttempt() async throws -> SessionSourceAttemptContext? {
    guard MachineSessionSourceAttempt.plan == nil, let sourcePlanProvider else { return nil }
    let plan = try await sourcePlanProvider()
    let cacheGeneration = await aggregationCache?.beginSourceAttempt(
      sourceConfigurationFingerprint: plan.fingerprint
    )
    let publicationGeneration = await sourceGenerationFence.begin(fingerprint: plan.fingerprint)
    return SessionSourceAttemptContext(
      plan: plan,
      cacheGeneration: cacheGeneration,
      publicationGeneration: publicationGeneration
    )
  }

  func withSessionSourceAttempt<Value: Sendable>(
    _ attempt: SessionSourceAttemptContext,
    operation: @Sendable () async throws -> Value
  ) async rethrows -> Value {
    try await MachineSessionSourceAttempt.$plan.withValue(attempt.plan) {
      try await MachineSessionSourceAttempt.$cacheGeneration.withValue(attempt.cacheGeneration) {
        try await MachineSessionSourceAttempt.$publicationGeneration.withValue(attempt.publicationGeneration) {
          try await operation()
        }
      }
    }
  }
}
