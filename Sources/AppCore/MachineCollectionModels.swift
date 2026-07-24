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
