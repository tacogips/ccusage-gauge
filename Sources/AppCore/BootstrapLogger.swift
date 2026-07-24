import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum BootstrapRuntime: String, Codable, Sendable {
  case menuBar
  case configCheck
  case usageSnapshot
  case serve
  case client
}

public enum BootstrapLogSeverity: String, Codable, Sendable {
  case warning
  case error
}

public final class BootstrapLogger: @unchecked Sendable {
  public static let activeFileName = "ccusage-gauge.jsonl"
  public static let maximumRecordBytes = 16 * 1_024
  public static let maximumFileBytes = 10 * 1_024 * 1_024
  public static let retentionSeconds: TimeInterval = 72 * 60 * 60

  private struct Record: Encodable {
    let timestamp: String
    let severity: BootstrapLogSeverity
    let runtime: BootstrapRuntime
    let phase: String
    let code: String
    let message: String
  }

  private let primaryDirectory: URL
  private let fallbackDirectory: URL?
  private let runtime: BootstrapRuntime
  private let now: @Sendable () -> Date
  private let maximumFileBytes: Int
  private let retentionSeconds: TimeInterval
  private let fileManager: FileManager
  private let mutex = NSLock()
  private var directory: URL?
  private var disabled = false

  public init(
    primaryDirectory: URL,
    fallbackDirectory: URL? = nil,
    runtime: BootstrapRuntime,
    now: @escaping @Sendable () -> Date = Date.init,
    maximumFileBytes: Int = BootstrapLogger.maximumFileBytes,
    retentionSeconds: TimeInterval = BootstrapLogger.retentionSeconds,
    fileManager: FileManager = .default
  ) {
    self.primaryDirectory = primaryDirectory
    self.fallbackDirectory = fallbackDirectory == primaryDirectory ? nil : fallbackDirectory
    self.runtime = runtime
    self.now = now
    self.maximumFileBytes = maximumFileBytes
    self.retentionSeconds = retentionSeconds
    self.fileManager = fileManager
  }

  public convenience init(
    paths: AppPaths,
    runtime: BootstrapRuntime,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    let hasExplicitStateRoot = environment["CCUSAGE_GAUGE_STATE_HOME"] != nil
    self.init(
      primaryDirectory: paths.logDirectory,
      fallbackDirectory: hasExplicitStateRoot ? AppPaths.defaultLogDirectory(environment: environment) : nil,
      runtime: runtime
    )
  }

  public func activate() {
    mutex.withLock {
      activateUnlocked()
    }
  }

  public func append(
    severity: BootstrapLogSeverity = .error,
    phase: String,
    code: String,
    message: String
  ) {
    mutex.withLock {
      guard !disabled else { return }
      if directory == nil { activateUnlocked() }
      guard let directory else { return }
      do {
        try withAdvisoryLock(in: directory) {
          let record = try encodedRecord(
            severity: severity,
            phase: phase,
            code: code,
            message: message
          )
          try rotateIfNeeded(in: directory, incomingBytes: record.count)
          try append(record, in: directory)
        }
      } catch {
        // Drop only this record: a transient failure (full disk, contention)
        // must not permanently silence bootstrap logging for the process.
      }
    }
  }

  private func activateUnlocked() {
    guard directory == nil, !disabled else { return }
    var primaryUnavailable = false
    for (index, candidate) in [primaryDirectory, fallbackDirectory].compactMap({ $0 }).enumerated() {
      do {
        try ensureSafeDirectory(candidate)
        try withAdvisoryLock(in: candidate) {
          try removeExpiredRotatedLogs(in: candidate, reference: now())
          if primaryUnavailable {
            let warning = try encodedRecord(
              severity: .warning,
              phase: "logging",
              code: "log_primary_unavailable",
              message: "Primary log location unavailable; using fallback"
            )
            try rotateIfNeeded(in: candidate, incomingBytes: warning.count)
            try append(warning, in: candidate)
          }
        }
        directory = candidate
        return
      } catch {
        if index == 0 { primaryUnavailable = true }
        continue
      }
    }
    disabled = true
  }

  private func ensureSafeDirectory(_ url: URL) throws {
    if !fileManager.fileExists(atPath: url.path) {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR,
          metadata.st_uid == getuid(),
          metadata.st_mode & 0o777 == 0o700 else {
      throw BootstrapLoggerError.unsafeObject
    }
  }

  private func withAdvisoryLock<T>(in directory: URL, operation: () throws -> T) throws -> T {
    let lockURL = directory.appendingPathComponent(".ccusage-gauge.lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw BootstrapLoggerError.lockFailed }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_nlink == 1,
          metadata.st_uid == getuid(),
          metadata.st_mode & 0o777 == 0o600,
          flock(descriptor, LOCK_EX) == 0 else {
      throw BootstrapLoggerError.lockFailed
    }
    defer { flock(descriptor, LOCK_UN) }
    return try operation()
  }

  private func encodedRecord(
    severity: BootstrapLogSeverity,
    phase: String,
    code: String,
    message: String
  ) throws -> Data {
    let timestamp = Self.timestamp(now())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(Record(
      timestamp: timestamp,
      severity: severity,
      runtime: runtime,
      phase: phase,
      code: code,
      message: message
    ))
    data.append(0x0A)
    if data.count > Self.maximumRecordBytes {
      data = try encoder.encode(Record(
        timestamp: timestamp,
        severity: severity,
        runtime: runtime,
        phase: "runtime",
        code: "runtime_failure",
        message: "Runtime failure"
      ))
      data.append(0x0A)
    }
    guard data.count <= Self.maximumRecordBytes else {
      throw BootstrapLoggerError.recordTooLarge
    }
    return data
  }

  private func rotateIfNeeded(in directory: URL, incomingBytes: Int) throws {
    let active = directory.appendingPathComponent(Self.activeFileName)
    guard fileManager.fileExists(atPath: active.path) else { return }
    let metadata = try safeFileMetadata(active)
    let size = (metadata[.size] as? NSNumber)?.intValue ?? 0
    guard size + incomingBytes > maximumFileBytes else { return }
    let stamp = Self.rotationTimestamp(now())
    var sequence = 0
    while true {
      let rotated = directory.appendingPathComponent(
        "ccusage-gauge-\(stamp)-\(sequence).jsonl"
      )
      if !fileManager.fileExists(atPath: rotated.path) {
        guard rename(active.path, rotated.path) == 0 else {
          throw BootstrapLoggerError.writeFailed
        }
        break
      }
      sequence += 1
    }
    try removeExpiredRotatedLogs(in: directory, reference: now())
  }

  private func append(_ data: Data, in directory: URL) throws {
    let active = directory.appendingPathComponent(Self.activeFileName)
    let descriptor = open(active.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw BootstrapLoggerError.writeFailed }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_nlink == 1,
          metadata.st_uid == getuid(),
          metadata.st_mode & 0o777 == 0o600 else {
      throw BootstrapLoggerError.unsafeObject
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let result = write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if result > 0 {
          offset += result
        } else if result < 0, errno == EINTR {
          continue
        } else {
          throw BootstrapLoggerError.writeFailed
        }
      }
    }
  }

  private func removeExpiredRotatedLogs(in directory: URL, reference: Date) throws {
    let cutoff = reference.addingTimeInterval(-retentionSeconds)
    for url in try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) {
      let name = url.lastPathComponent
      guard name.hasPrefix("ccusage-gauge-"),
            name.hasSuffix(".jsonl"),
            name != Self.activeFileName else { continue }
      // A foreign or unsafe file (wrong owner, mode, or link count) is left in
      // place; it must not make the whole log directory unusable.
      guard let metadata = try? safeFileMetadata(url) else { continue }
      guard let modified = metadata[.modificationDate] as? Date, modified < cutoff else { continue }
      try fileManager.removeItem(at: url)
    }
  }

  private func safeFileMetadata(_ url: URL) throws -> [FileAttributeKey: Any] {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_nlink == 1,
          metadata.st_uid == getuid(),
          metadata.st_mode & 0o777 == 0o600 else {
      throw BootstrapLoggerError.unsafeObject
    }
    return try fileManager.attributesOfItem(atPath: url.path)
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func rotationTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
    return formatter.string(from: date)
  }
}

private enum BootstrapLoggerError: Error {
  case unsafeObject
  case lockFailed
  case recordTooLarge
  case writeFailed
}

private extension NSLock {
  func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try operation()
  }
}
