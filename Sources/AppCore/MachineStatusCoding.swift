import Foundation

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
  public let consecutiveFailureCount: Int
  public let unavailableSince: Date?
  public let staleSince: Date?
  public let lastErrorAt: Date?
  public let lastError: SanitizedCollectionError?
  public let lastHourDataGap: MachineStatusDataGap?
  public let refreshIntervalSeconds: Int

  private enum CodingKeys: String, CodingKey {
    case id, displayName, kind, enabled, collectionState, snapshotAvailable
    case collectionInProgress, stale, coverageStart, snapshotGeneratedAt
    case lastAttemptAt, lastSuccessAt, consecutiveFailureCount, unavailableSince
    case staleSince, lastErrorAt, lastError, lastHourDataGap, refreshIntervalSeconds
  }

  public init(
    id: String,
    displayName: String,
    kind: MachineKind,
    enabled: Bool,
    collectionState: MachineCollectionState,
    snapshotAvailable: Bool,
    collectionInProgress: Bool,
    stale: Bool,
    coverageStart: String?,
    snapshotGeneratedAt: Date?,
    lastAttemptAt: Date?,
    lastSuccessAt: Date?,
    consecutiveFailureCount: Int,
    unavailableSince: Date?,
    staleSince: Date?,
    lastErrorAt: Date?,
    lastError: SanitizedCollectionError?,
    lastHourDataGap: MachineStatusDataGap?,
    refreshIntervalSeconds: Int
  ) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.enabled = enabled
    self.collectionState = collectionState
    self.snapshotAvailable = snapshotAvailable
    self.collectionInProgress = collectionInProgress
    self.stale = stale
    self.coverageStart = coverageStart
    self.snapshotGeneratedAt = snapshotGeneratedAt
    self.lastAttemptAt = lastAttemptAt
    self.lastSuccessAt = lastSuccessAt
    self.consecutiveFailureCount = consecutiveFailureCount
    self.unavailableSince = unavailableSince
    self.staleSince = staleSince
    self.lastErrorAt = lastErrorAt
    self.lastError = lastError
    self.lastHourDataGap = lastHourDataGap
    self.refreshIntervalSeconds = refreshIntervalSeconds
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    displayName = try values.decode(String.self, forKey: .displayName)
    kind = try values.decode(MachineKind.self, forKey: .kind)
    enabled = try values.decode(Bool.self, forKey: .enabled)
    collectionState = try values.decode(MachineCollectionState.self, forKey: .collectionState)
    snapshotAvailable = try values.decode(Bool.self, forKey: .snapshotAvailable)
    collectionInProgress = try values.decode(Bool.self, forKey: .collectionInProgress)
    stale = try values.decode(Bool.self, forKey: .stale)
    coverageStart = try values.decodeIfPresent(String.self, forKey: .coverageStart)
    snapshotGeneratedAt = try values.decodeIfPresent(Date.self, forKey: .snapshotGeneratedAt)
    lastAttemptAt = try values.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
    lastSuccessAt = try values.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
    consecutiveFailureCount = try values.decodeIfPresent(Int.self, forKey: .consecutiveFailureCount) ?? 0
    unavailableSince = try values.decodeIfPresent(Date.self, forKey: .unavailableSince)
    staleSince = try values.decodeIfPresent(Date.self, forKey: .staleSince)
    lastErrorAt = try values.decodeIfPresent(Date.self, forKey: .lastErrorAt)
    lastError = try values.decodeIfPresent(SanitizedCollectionError.self, forKey: .lastError)
    lastHourDataGap = try values.decodeIfPresent(MachineStatusDataGap.self, forKey: .lastHourDataGap)
    refreshIntervalSeconds = try values.decode(Int.self, forKey: .refreshIntervalSeconds)
  }
}
