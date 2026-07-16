import Foundation

public enum BoundaryKind: String, Codable, Sendable { case scheduled, manual }

public struct ResetBaseline: Codable, Equatable, Sendable {
  public var scheduledBoundaryAt: Date
  public var manualResetAtConsidered: Date?
  public var activeBoundaryAt: Date
  public var boundaryKind: BoundaryKind
  public var cycle: ResetCycle
  public var calendarIdentifier: String
  public var timeZoneIdentifier: String
  public var computedAt: Date

  public init(
    scheduledBoundaryAt: Date,
    manualResetAtConsidered: Date?,
    activeBoundaryAt: Date,
    boundaryKind: BoundaryKind,
    cycle: ResetCycle,
    calendarIdentifier: String,
    timeZoneIdentifier: String,
    computedAt: Date
  ) {
    self.scheduledBoundaryAt = scheduledBoundaryAt
    self.manualResetAtConsidered = manualResetAtConsidered
    self.activeBoundaryAt = activeBoundaryAt
    self.boundaryKind = boundaryKind
    self.cycle = cycle
    self.calendarIdentifier = calendarIdentifier
    self.timeZoneIdentifier = timeZoneIdentifier
    self.computedAt = computedAt
  }
}

public struct AppState: Codable, Equatable, Sendable {
  public var budgetUSD: Decimal?
  public var resetCycle: ResetCycle
  public var lastManualResetAt: Date?
  public var baseline: ResetBaseline?
  public var refreshIntervalSeconds: Int?

  public init(
    budgetUSD: Decimal? = nil,
    resetCycle: ResetCycle = .daily,
    lastManualResetAt: Date? = nil,
    baseline: ResetBaseline? = nil,
    refreshIntervalSeconds: Int? = nil
  ) {
    self.budgetUSD = budgetUSD
    self.resetCycle = resetCycle
    self.lastManualResetAt = lastManualResetAt
    self.baseline = baseline
    self.refreshIntervalSeconds = refreshIntervalSeconds
  }
}

public actor StateStore {
  public let fileURL: URL
  private let fileManager: FileManager

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public func load(defaultCycle: ResetCycle = .daily) throws -> AppState {
    guard fileManager.fileExists(atPath: fileURL.path) else { return AppState(resetCycle: defaultCycle) }
    return try Self.decoder.decode(AppState.self, from: Data(contentsOf: fileURL))
  }

  public func save(_ state: AppState) throws {
    if let budget = state.budgetUSD, budget < 0 { throw StateError.negativeBudget }
    if let interval = state.refreshIntervalSeconds, interval <= 0 { throw StateError.invalidRefreshInterval(interval) }
    try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = try Self.encoder.encode(state)
    data.append(0x0A)
    try data.write(to: fileURL, options: .atomic)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

public enum StateError: Error, Equatable, Sendable {
  case negativeBudget
  case invalidRefreshInterval(Int)
}
