import Foundation

/// One JSONL log discovered under a session-source root, with the metadata the scan
/// cache needs to decide whether an earlier scan of the same file is still valid.
struct UsageEventLogFile: Hashable, Sendable {
  let url: URL
  let size: UInt64
  let modified: Date?
}

/// Byte extent of a log at the moment a scan starts. `terminated` is the offset just past
/// the last newline in the file (nil when no newline was found in the probed tail), which is
/// where an incremental resume may safely continue from: a trailing partial line is parsed
/// now and parsed again on resume, so a line that was mid-write is never lost.
struct UsageEventLogRegion: Equatable, Sendable {
  let size: UInt64
  let terminated: UInt64?
}

enum UsageEventLogReader {
  private static let compactTimestampNeedle = Data(#""timestamp":""#.utf8)
  private static let spacedTimestampNeedle = Data(#""timestamp": ""#.utf8)
  /// Reverse scans read a file in fixed-size windows from its end, so resident memory stays
  /// bounded by one window plus one line however large the session log grows. Mapping the
  /// whole file instead made every poll's resident size ramp by the size of each active
  /// multi-hundred-megabyte session log.
  static let defaultReverseChunkSize = 1 << 20
  private static let forwardChunkSize = 64 * 1_024
  private static let lineTerminatorProbeSize: UInt64 = 64 * 1_024
  private static let newline: UInt8 = 0x0A

  static func dayFormatter(calendar: Calendar) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }

  static func timestampDay(in line: Data) -> String? {
    let match = line.range(of: compactTimestampNeedle) ?? line.range(of: spacedTimestampNeedle)
    guard let match else { return nil }
    let end = line.index(match.upperBound, offsetBy: 10, limitedBy: line.endIndex) ?? line.endIndex
    guard line.distance(from: match.upperBound, to: end) == 10 else { return nil }
    return String(data: Data(line[match.upperBound..<end]), encoding: .utf8)
  }

  static func jsonlFiles(roots: [URL], modifiedSince: Date?) -> [UsageEventLogFile] {
    let manager = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
    return roots.flatMap { root -> [UsageEventLogFile] in
      guard let enumerator = manager.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsPackageDescendants, .skipsHiddenFiles]
      ) else { return [] }
      return enumerator.compactMap { item in
        guard let url = item as? URL, url.pathExtension == "jsonl",
              let values = try? url.resourceValues(forKeys: Set(keys)),
              values.isRegularFile == true else { return nil }
        if let modifiedSince, let modified = values.contentModificationDate, modified < modifiedSince { return nil }
        // Enumerator URLs carry a base URL and compare unequal to a plain file URL of the
        // same path, so normalize before the URL becomes a cache key.
        return UsageEventLogFile(
          url: URL(fileURLWithPath: url.path),
          size: UInt64(max(0, values.fileSize ?? 0)),
          modified: values.contentModificationDate
        )
      }
    }.sorted { $0.url.path < $1.url.path }
  }

  /// Calls `body` with every non-empty line in `[offset, endOffset)` (through EOF when
  /// `endOffset` is nil) that contains at least one needle, in file order.
  static func forEachLine(
    in url: URL,
    from offset: UInt64 = 0,
    to endOffset: UInt64? = nil,
    matchingAny needles: [Data] = [],
    body: (Data) -> Void
  ) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    if offset > 0 { try handle.seek(toOffset: offset) }
    var remaining = endOffset.map { $0 > offset ? $0 - offset : 0 }
    if remaining == 0 { return }
    var pending = Data()
    func emit(_ range: Range<Data.Index>) {
      guard !range.isEmpty, matches(pending, in: range, anyOf: needles) else { return }
      body(Data(pending[range]))
    }
    // Every FileHandle read hands back an autoreleased buffer on Darwin; the pool around each
    // chunk releases it right away instead of at the end of the surrounding task.
    var hasMore = true
    while hasMore {
      hasMore = try withTransientAutoreleasePool {
        let requested = remaining.map { Int(min(UInt64(forwardChunkSize), $0)) } ?? forwardChunkSize
        guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else { return false }
        remaining = remaining.map { $0 - UInt64(chunk.count) }
        pending.append(chunk)
        while let terminator = pending.firstIndex(of: newline) {
          emit(pending.startIndex..<terminator)
          pending.removeSubrange(...terminator)
        }
        return remaining != 0
      }
    }
    if !pending.isEmpty { withTransientAutoreleasePool { emit(pending.startIndex..<pending.endIndex) } }
  }

  /// Calls `body` with every non-empty line in `[0, endOffset)` (from EOF when `endOffset`
  /// is nil) that contains at least one needle, newest line first, until `body` returns
  /// false. The file is read backwards in `chunkSize` windows; a line straddling two windows
  /// is carried into the next read, so memory use is bounded by the window plus one line.
  static func forEachLineFromEnd(
    in url: URL,
    endingAt endOffset: UInt64? = nil,
    matchingAny needles: [Data] = [],
    chunkSize: Int = defaultReverseChunkSize,
    body: (Data) -> Bool
  ) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var position = try endOffset ?? handle.seekToEnd()
    let window = UInt64(max(1, chunkSize))
    // Head of the previously read window that had no terminator yet: the tail of a line
    // whose start lies in an earlier window.
    var carry = Data()
    while position > 0 {
      if Task.isCancelled { return }
      // Every FileHandle read hands back an autoreleased buffer on Darwin, and objects bridged
      // while matching and decoding lines are autoreleased too. Draining a pool per window
      // keeps the footprint at one window instead of pinning every window until the
      // surrounding task finishes.
      let shouldContinue = try withTransientAutoreleasePool { () throws -> Bool in
        let readSize = min(window, position)
        let start = position - readSize
        try handle.seek(toOffset: start)
        guard let chunk = try handle.read(upToCount: Int(readSize)), chunk.count == Int(readSize) else { return false }
        var buffer = chunk
        buffer.append(carry)
        position = start
        let completeStart: Data.Index
        if start == 0 {
          completeStart = buffer.startIndex
          carry = Data()
        } else if let firstTerminator = buffer.firstIndex(of: newline) {
          completeStart = buffer.index(after: firstTerminator)
          carry = Data(buffer[buffer.startIndex..<firstTerminator])
        } else {
          carry = buffer
          return true
        }
        var upperBound = buffer.endIndex
        while upperBound > completeStart {
          while upperBound > completeStart, buffer[buffer.index(before: upperBound)] == newline {
            upperBound = buffer.index(before: upperBound)
          }
          guard upperBound > completeStart else { break }
          var lowerBound = upperBound
          while lowerBound > completeStart, buffer[buffer.index(before: lowerBound)] != newline {
            lowerBound = buffer.index(before: lowerBound)
          }
          let lineRange = lowerBound..<upperBound
          if matches(buffer, in: lineRange, anyOf: needles), !body(Data(buffer[lineRange])) { return false }
          upperBound = lowerBound
        }
        return true
      }
      if !shouldContinue { return }
    }
  }

  /// Current size of the log and the offset just past its last newline, probing only the
  /// tail so the call stays cheap for large files.
  static func region(of url: URL) throws -> UsageEventLogRegion {
    try withTransientAutoreleasePool { try probeRegion(of: url) }
  }

  private static func probeRegion(of url: URL) throws -> UsageEventLogRegion {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    guard size > 0 else { return UsageEventLogRegion(size: 0, terminated: 0) }
    let probe = min(lineTerminatorProbeSize, size)
    try handle.seek(toOffset: size - probe)
    guard let tail = try handle.read(upToCount: Int(probe)), tail.count == Int(probe) else {
      return UsageEventLogRegion(size: size, terminated: nil)
    }
    guard let last = tail.lastIndex(of: newline) else {
      return UsageEventLogRegion(size: size, terminated: probe == size ? 0 : nil)
    }
    return UsageEventLogRegion(
      size: size,
      terminated: size - probe + UInt64(tail.distance(from: tail.startIndex, to: last)) + 1
    )
  }

  static func bytes(in url: URL, from offset: UInt64, count: Int) throws -> Data {
    guard count > 0 else { return Data() }
    return try withTransientAutoreleasePool {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      try handle.seek(toOffset: offset)
      return try handle.read(upToCount: count).map { Data($0) } ?? Data()
    }
  }

  /// Substring test over raw bytes. `Data.range(of:)` bridges through NSData and leaves an
  /// autoreleased wrapper per call that keeps the window buffer alive; this stays in Swift.
  private static func matches(_ data: Data, in range: Range<Data.Index>, anyOf needles: [Data]) -> Bool {
    guard !needles.isEmpty else { return true }
    let offset = data.distance(from: data.startIndex, to: range.lowerBound)
    let length = range.count
    guard length > 0 else { return false }
    return data.withUnsafeBytes { haystack -> Bool in
      guard let base = haystack.baseAddress?.advanced(by: offset) else { return false }
      return needles.contains { needle in
        needle.withUnsafeBytes { pattern -> Bool in
          guard let patternBase = pattern.baseAddress, pattern.count > 0, pattern.count <= length else { return false }
          let first = patternBase.load(as: UInt8.self)
          var index = 0
          let last = length - pattern.count
          while index <= last {
            if base.load(fromByteOffset: index, as: UInt8.self) == first,
               memcmp(base.advanced(by: index), patternBase, pattern.count) == 0 {
              return true
            }
            index += 1
          }
          return false
        }
      }
    }
  }

  private static func withTransientAutoreleasePool<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if canImport(ObjectiveC)
    return try autoreleasepool { try body() }
    #else
    return try body()
    #endif
  }
}
