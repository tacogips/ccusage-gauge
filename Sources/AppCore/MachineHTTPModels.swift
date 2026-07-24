import Foundation

public struct SSHConnectionRequest: Decodable, Sendable {
  public let host: String
  public let port: Int
  public let user: String
  public let identityFile: String?
  public let extraOptions: [String]
  public let proxy: SSHProxy?
  public let remoteCcusagePath: String

  private enum CodingKeys: String, CodingKey {
    case host, port, user, identityFile, extraOptions, proxy, remoteCcusagePath
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    host = try values.decode(String.self, forKey: .host)
    port = try values.decode(Int.self, forKey: .port)
    user = try values.decode(String.self, forKey: .user)
    identityFile = try values.decodeIfPresent(String.self, forKey: .identityFile)
    extraOptions = try values.decodeIfPresent([String].self, forKey: .extraOptions) ?? []
    proxy = try values.decodeIfPresent(SSHProxy.self, forKey: .proxy)
    remoteCcusagePath = try values.decodeIfPresent(String.self, forKey: .remoteCcusagePath) ?? "ccusage"
  }

  public var connection: SSHConnection {
    SSHConnection(
      host: host,
      port: port,
      user: user,
      identityFile: identityFile,
      extraOptions: extraOptions,
      proxy: proxy,
      remoteCcusagePath: remoteCcusagePath
    )
  }
}

public struct MachineCreateRequest: Decodable, Sendable {
  public let id: String
  public let displayName: String
  public let kind: MachineKind
  public let enabled: Bool
  public let ssh: SSHConnectionRequest
}

public struct MachineReplaceRequest: Decodable, Sendable {
  public let displayName: String
  public let kind: MachineKind
  public let enabled: Bool
  public let ssh: SSHConnectionRequest
}

public struct MachinePatchRequest: Decodable, Sendable {
  public let displayName: String?
  public let enabled: Bool?
  public let ssh: SSHConnectionRequest?

  public var isEmpty: Bool { displayName == nil && enabled == nil && ssh == nil }
}

public struct MachinesResponse: Codable, Sendable {
  public let machines: [MachineDescriptor]
}

public struct RefreshResponse: Codable, Sendable {
  public let status: String
  public let requested: String
  public let refreshedMachineIds: [String]
  public let failedMachineIds: [String]
  public let generatedAt: Date
  public let diagnostic: SanitizedCollectionError?

  public init(
    status: String,
    requested: String,
    refreshedMachineIds: [String],
    failedMachineIds: [String],
    generatedAt: Date,
    diagnostic: SanitizedCollectionError? = nil
  ) {
    self.status = status
    self.requested = requested
    self.refreshedMachineIds = refreshedMachineIds
    self.failedMachineIds = failedMachineIds
    self.generatedAt = generatedAt
    self.diagnostic = diagnostic
  }
}

public struct MachineConnectionTestResponse: Codable, Sendable {
  public let machine: String
  public let status: String
  public let testedAt: Date
  public let diagnostic: SanitizedCollectionError?
}

public struct MachineLoadStatusItem: Codable, Sendable {
  public let id: String
  public let phase: DashboardLoadPhase
  public let message: String
  public let completed: Int
  public let total: Int
  public let isLoading: Bool
  public let coverageStart: String?
  public let requestedCoverageStart: String?
}

public struct MachineLoadStatusResponse: Codable, Sendable {
  public let phase: DashboardLoadPhase
  public let message: String
  public let completed: Int
  public let total: Int
  public let isLoading: Bool
  public let requested: String
  public let machines: [MachineLoadStatusItem]
}

public struct CacheClearFailureItem: Codable, Sendable {
  public let id: String
  public let code: String
  public let message: String
  public let reconciliationRequired: Bool
}

public struct CacheClearResponse: Codable, Sendable {
  public let requested: String
  public let outcome: String
  public let clearedMachineIds: [String]
  public let failedMachines: [CacheClearFailureItem]
}
