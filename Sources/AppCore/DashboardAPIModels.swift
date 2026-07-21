import Foundation

/// Closed wire/CLI domains for dashboard reads. These mirror the ranges,
/// granularities, and machine selectors accepted by the loopback dashboard API
/// and are modeled as enums so invalid values cannot reach the transport.

/// Range accepted by `/api/period`.
public enum DashboardPeriodRange: String, Codable, CaseIterable, Equatable, Sendable {
  case today
  case yesterday
  case week
  case month
  case custom

  /// Whether the range requires explicit `--start` and `--end` dates.
  public var requiresExplicitDates: Bool { self == .custom }
}

/// Range accepted by `/api/metrics` and `/api/cost-series`.
public enum DashboardAnalyticsRange: String, Codable, CaseIterable, Equatable, Sendable {
  case all
  case recent12h
  case today
  case yesterday
  case week
  case month
  case custom

  /// Whether the range requires explicit `--start` and `--end` dates.
  public var requiresExplicitDates: Bool { self == .custom }
}

/// Granularity accepted by `/api/cost-series`. Raw values preserve the exact
/// wire spelling, including the leading-digit forms that are not valid Swift
/// identifiers.
public enum DashboardGranularity: String, Codable, CaseIterable, Equatable, Sendable {
  case min15 = "15min"
  case hourly
  case hour6 = "6hour"
  case daily
}

/// A machine selection: the `all` aggregate, the synthetic `local` machine, or
/// a canonical SSH machine identifier.
public enum MachineSelector: Equatable, Sendable {
  case all
  case local
  case machine(String)

  /// The exact `machine` query value expected by the server.
  public var wireValue: String {
    switch self {
    case .all: "all"
    case .local: "local"
    case .machine(let id): id
    }
  }

  /// Parses a selector from a CLI argument, rejecting non-canonical values.
  public init?(argument: String) {
    switch argument {
    case "all": self = .all
    case "local": self = .local
    default:
      guard MachineValidation.isCanonicalMachineID(argument) else { return nil }
      self = .machine(argument)
    }
  }
}

/// The exact closed machine-creation request shape accepted by the server. The
/// identity-file path is only encoded when present; the client never opens,
/// reads, or transmits identity-file contents.
public struct MachineCreatePayload: Encodable, Sendable {
  /// Backwards-compatible spelling for the SSH connection payload.
  public typealias SSHPayload = MachineCreateSSHPayload

  public let id: String
  public let displayName: String
  public let kind: MachineKind
  public let enabled: Bool
  public let ssh: MachineCreateSSHPayload

  public init(
    id: String,
    displayName: String,
    enabled: Bool,
    ssh: MachineCreateSSHPayload
  ) {
    self.id = id
    self.displayName = displayName
    kind = .ssh
    self.enabled = enabled
    self.ssh = ssh
  }
}

/// The SSH connection portion of a machine-creation request. The identity-file
/// path is only encoded when present; the client never opens, reads, or
/// transmits identity-file contents.
public struct MachineCreateSSHPayload: Encodable, Sendable {
  public let host: String
  public let port: Int
  public let user: String
  public let identityFile: String?
  public let extraOptions: [String]
  public let remoteCcusagePath: String

  public init(
    host: String,
    port: Int,
    user: String,
    identityFile: String?,
    extraOptions: [String],
    remoteCcusagePath: String
  ) {
    self.host = host
    self.port = port
    self.user = user
    self.identityFile = identityFile
    self.extraOptions = extraOptions
    self.remoteCcusagePath = remoteCcusagePath
  }

  private enum CodingKeys: String, CodingKey {
    case host, port, user, identityFile, extraOptions, remoteCcusagePath
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(host, forKey: .host)
    try container.encode(port, forKey: .port)
    try container.encode(user, forKey: .user)
    try container.encodeIfPresent(identityFile, forKey: .identityFile)
    try container.encode(extraOptions, forKey: .extraOptions)
    try container.encode(remoteCcusagePath, forKey: .remoteCcusagePath)
  }
}

/// A query response envelope that adds the router-injected `scope` sibling to an
/// otherwise complete response DTO. The base body decodes from the same keyed
/// container, so existing DTOs are reused without re-declaring their fields.
public struct ScopedResponse<Body: Decodable & Sendable>: Decodable, Sendable {
  public let body: Body
  public let scope: DashboardScope

  private enum ScopeKey: String, CodingKey { case scope }

  public init(from decoder: Decoder) throws {
    body = try Body(from: decoder)
    scope = try decoder.container(keyedBy: ScopeKey.self).decode(DashboardScope.self, forKey: .scope)
  }
}

/// A successful API response paired with the exact raw bytes returned by the
/// server, so `--json` output preserves `scope` and any future additive fields.
public struct DashboardAPIResponse<Value: Sendable>: Sendable {
  public let raw: Data
  public let value: Value

  public init(raw: Data, value: Value) {
    self.raw = raw
    self.value = value
  }
}

/// A non-2xx API rejection, decoded from the server error body.
public struct DashboardAPIError: Error, Equatable, Sendable {
  public let httpStatus: Int
  public let code: String
  public let message: String
  public let fieldErrors: [String: String]
  public let retryAfterSeconds: Int?
  public let rawBody: Data

  public init(
    httpStatus: Int,
    code: String,
    message: String,
    fieldErrors: [String: String] = [:],
    retryAfterSeconds: Int? = nil,
    rawBody: Data = Data()
  ) {
    self.httpStatus = httpStatus
    self.code = code
    self.message = message
    self.fieldErrors = fieldErrors
    self.retryAfterSeconds = retryAfterSeconds
    self.rawBody = rawBody
  }

  /// Whether the rejection is a server-side (5xx) failure.
  public var isServerError: Bool { (500...599).contains(httpStatus) }
}

/// A structured client failure. The associated categories map directly to the
/// documented CLI exit statuses.
public enum DashboardClientError: Error, Sendable {
  /// The dashboard API could not be reached (exit status 3).
  case unreachable(String)
  /// The API rejected the request (exit status 4 for non-5xx, 5 for 5xx).
  case api(DashboardAPIError)
  /// A response could not be decoded (exit status 1).
  case decoding(String)
}
