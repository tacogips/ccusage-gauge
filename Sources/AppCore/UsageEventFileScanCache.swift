import Foundation

struct CachedUsageEvent: Sendable {
  let day: String
  let event: TimestampedUsageEvent
}

/// Result of scanning one JSONL log, retained across polls so an unchanged file is not
/// re-read and a file that only grew has just its appended bytes parsed. Session logs are
/// append-only, but that is verified (`boundary`) rather than assumed.
struct UsageEventFileScan<Context: Sendable>: Sendable {
  var fileSize: UInt64
  var modified: Date?
  /// Offset just past the last newline-terminated line covered by `events`, or nil when the
  /// scan cannot be resumed and any change forces a full rescan.
  var scannedThrough: UInt64?
  /// Bytes immediately preceding `scannedThrough`, compared before resuming so a file that
  /// was rewritten in place rather than appended to is rescanned from scratch.
  var boundary: Data
  /// Local calendar day: `events` holds every event dated on or after this day.
  var since: String
  var timeZoneIdentifier: String
  /// Events keyed by `TimestampedUsageEvent.identity`.
  var events: [String: CachedUsageEvent]
  var context: Context

  static func make(
    file: UsageEventLogFile,
    region: UsageEventLogRegion,
    since: String,
    timeZoneIdentifier: String,
    events: [String: CachedUsageEvent],
    context: Context
  ) -> UsageEventFileScan {
    var scan = UsageEventFileScan(
      fileSize: file.size,
      modified: file.modified,
      scannedThrough: nil,
      boundary: Data(),
      since: since,
      timeZoneIdentifier: timeZoneIdentifier,
      events: events,
      context: context
    )
    scan.advance(file: file, region: region)
    return scan
  }

  mutating func advance(file: UsageEventLogFile, region: UsageEventLogRegion) {
    fileSize = file.size
    modified = file.modified
    scannedThrough = region.terminated
    boundary = region.terminated.map { UsageEventFileScanPlanner.boundary(of: file.url, endingAt: $0) } ?? Data()
  }
}

enum UsageEventFileScanStep<Context: Sendable> {
  case reuse(UsageEventFileScan<Context>)
  case resume(UsageEventFileScan<Context>)
  case rescan
}

enum UsageEventFileScanPlanner {
  static let boundaryLength = 256

  static func step<Context>(
    for file: UsageEventLogFile,
    entry: UsageEventFileScan<Context>?,
    since: String,
    timeZoneIdentifier: String
  ) -> UsageEventFileScanStep<Context> {
    guard let entry, entry.timeZoneIdentifier == timeZoneIdentifier, entry.since <= since else { return .rescan }
    if entry.fileSize == file.size, entry.modified == file.modified { return .reuse(entry) }
    guard let scannedThrough = entry.scannedThrough, file.size >= scannedThrough,
          boundaryMatches(entry.boundary, endingAt: scannedThrough, in: file.url) else { return .rescan }
    return .resume(entry)
  }

  static func boundary(of url: URL, endingAt offset: UInt64) -> Data {
    let length = Int(min(UInt64(boundaryLength), offset))
    guard length > 0 else { return Data() }
    return (try? UsageEventLogReader.bytes(in: url, from: offset - UInt64(length), count: length)) ?? Data()
  }

  private static func boundaryMatches(_ boundary: Data, endingAt offset: UInt64, in url: URL) -> Bool {
    guard !boundary.isEmpty else { return offset == 0 }
    guard offset >= UInt64(boundary.count),
          let current = try? UsageEventLogReader.bytes(in: url, from: offset - UInt64(boundary.count), count: boundary.count) else {
      return false
    }
    return current == boundary
  }
}

struct UsageEventScanOutcome<Context: Sendable>: Sendable {
  let events: [TimestampedUsageEvent]
  let entries: [URL: UsageEventFileScan<Context>]
  /// Modification-date floor of the listing that produced `entries`; a cached file modified
  /// on or after it would have been listed if it still existed.
  let listingFloor: Date?
}

/// Scans are only cached for recent windows (the menu-bar poll and the current week), so the
/// resident cache stays proportional to recent activity while deep history loads still run as
/// bounded-memory full scans.
struct UsageEventScanCachePolicy: Sendable {
  var windowDays = 8

  private func windowStart(calendar: Calendar, now: Date) -> Date? {
    guard windowDays > 0 else { return nil }
    return calendar.date(byAdding: .day, value: -windowDays, to: calendar.startOfDay(for: now))
  }

  func isCacheable(since: String, calendar: Calendar, now: Date) -> Bool {
    guard let start = windowStart(calendar: calendar, now: now) else { return false }
    return since >= UsageEventLogReader.dayFormatter(calendar: calendar).string(from: start)
  }

  func retentionFloor(calendar: Calendar, now: Date) -> Date {
    guard let start = windowStart(calendar: calendar, now: now) else { return .distantFuture }
    return calendar.date(byAdding: .day, value: -2, to: start) ?? start
  }
}

actor UsageEventFileScanCache<Context: Sendable> {
  private var entries: [URL: UsageEventFileScan<Context>] = [:]

  func snapshot() -> [URL: UsageEventFileScan<Context>] { entries }

  func merge(_ outcome: UsageEventScanOutcome<Context>, retentionFloor: Date) {
    for (url, entry) in outcome.entries { entries[url] = entry }
    entries = entries.filter { url, entry in
      if outcome.entries[url] != nil { return true }
      guard let modified = entry.modified else { return false }
      if let floor = outcome.listingFloor, modified >= floor { return false }
      return modified >= retentionFloor
    }
  }
}
