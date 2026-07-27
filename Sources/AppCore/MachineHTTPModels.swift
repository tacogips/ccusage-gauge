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
  public let codexSessionDirs: [String]
  public let claudeConfigDirs: [String]
  public let includeDefaultCodexDir: Bool
  public let includeDefaultClaudeDir: Bool

  private enum CodingKeys: String, CodingKey {
    case id, displayName, kind, enabled, ssh
    case codexSessionDirs, claudeConfigDirs
    case includeDefaultCodexDir, includeDefaultClaudeDir
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    displayName = try values.decode(String.self, forKey: .displayName)
    kind = try values.decode(MachineKind.self, forKey: .kind)
    enabled = try values.decode(Bool.self, forKey: .enabled)
    ssh = try values.decode(SSHConnectionRequest.self, forKey: .ssh)
    codexSessionDirs = try values.decodeIfPresent([String].self, forKey: .codexSessionDirs) ?? []
    claudeConfigDirs = try values.decodeIfPresent([String].self, forKey: .claudeConfigDirs) ?? []
    includeDefaultCodexDir = try values.decodeIfPresent(Bool.self, forKey: .includeDefaultCodexDir) ?? true
    includeDefaultClaudeDir = try values.decodeIfPresent(Bool.self, forKey: .includeDefaultClaudeDir) ?? true
  }
}

public struct MachineReplaceRequest: Decodable, Sendable {
  public let displayName: String
  public let kind: MachineKind
  public let enabled: Bool
  public let ssh: SSHConnectionRequest
  public let codexSessionDirs: [String]
  public let claudeConfigDirs: [String]
  public let includeDefaultCodexDir: Bool
  public let includeDefaultClaudeDir: Bool

  private enum CodingKeys: String, CodingKey {
    case displayName, kind, enabled, ssh
    case codexSessionDirs, claudeConfigDirs
    case includeDefaultCodexDir, includeDefaultClaudeDir
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    displayName = try values.decode(String.self, forKey: .displayName)
    kind = try values.decode(MachineKind.self, forKey: .kind)
    enabled = try values.decode(Bool.self, forKey: .enabled)
    ssh = try values.decode(SSHConnectionRequest.self, forKey: .ssh)
    codexSessionDirs = try values.decodeIfPresent([String].self, forKey: .codexSessionDirs) ?? []
    claudeConfigDirs = try values.decodeIfPresent([String].self, forKey: .claudeConfigDirs) ?? []
    includeDefaultCodexDir = try values.decodeIfPresent(Bool.self, forKey: .includeDefaultCodexDir) ?? true
    includeDefaultClaudeDir = try values.decodeIfPresent(Bool.self, forKey: .includeDefaultClaudeDir) ?? true
  }
}

public enum MachinePatchField<Value: Sendable>: Sendable {
  case omitted
  case value(Value)
}

public struct MachinePatchRequest: Decodable, Sendable {
  public let displayName: String?
  public let enabled: Bool?
  public let ssh: SSHConnectionRequest?
  public let codexSessionDirs: MachinePatchField<[String]>
  public let claudeConfigDirs: MachinePatchField<[String]>
  public let includeDefaultCodexDir: MachinePatchField<Bool>
  public let includeDefaultClaudeDir: MachinePatchField<Bool>

  private enum CodingKeys: String, CodingKey {
    case displayName, enabled, ssh
    case codexSessionDirs, claudeConfigDirs
    case includeDefaultCodexDir, includeDefaultClaudeDir
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled)
    ssh = try values.decodeIfPresent(SSHConnectionRequest.self, forKey: .ssh)
    codexSessionDirs = try Self.field([String].self, key: .codexSessionDirs, values: values)
    claudeConfigDirs = try Self.field([String].self, key: .claudeConfigDirs, values: values)
    includeDefaultCodexDir = try Self.field(Bool.self, key: .includeDefaultCodexDir, values: values)
    includeDefaultClaudeDir = try Self.field(Bool.self, key: .includeDefaultClaudeDir, values: values)
  }

  public var isEmpty: Bool {
    displayName == nil && enabled == nil && ssh == nil
      && codexSessionDirs.isOmitted
      && claudeConfigDirs.isOmitted
      && includeDefaultCodexDir.isOmitted
      && includeDefaultClaudeDir.isOmitted
  }

  public var containsOnlySessionSources: Bool {
    displayName == nil && enabled == nil && ssh == nil
  }

  private static func field<Value: Decodable & Sendable>(
    _ type: Value.Type,
    key: CodingKeys,
    values: KeyedDecodingContainer<CodingKeys>
  ) throws -> MachinePatchField<Value> {
    guard values.contains(key) else { return .omitted }
    return .value(try values.decode(type, forKey: key))
  }
}

extension MachinePatchField {
  public var isOmitted: Bool {
    if case .omitted = self { return true }
    return false
  }

  public func value(or fallback: Value) -> Value {
    switch self {
    case .omitted: fallback
    case .value(let value): value
    }
  }
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
  public let requestedCoverageEnd: String?

  public init(
    id: String,
    phase: DashboardLoadPhase,
    message: String,
    completed: Int,
    total: Int,
    isLoading: Bool,
    coverageStart: String?,
    requestedCoverageStart: String?,
    requestedCoverageEnd: String? = nil
  ) {
    self.id = id
    self.phase = phase
    self.message = message
    self.completed = completed
    self.total = total
    self.isLoading = isLoading
    self.coverageStart = coverageStart
    self.requestedCoverageStart = requestedCoverageStart
    self.requestedCoverageEnd = requestedCoverageEnd
  }
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
