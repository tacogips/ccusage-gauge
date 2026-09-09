import Foundation

/// ccusage scans every JSONL under an agent's session directory even for a
/// bounded `--since/--until` query, so a query for today still pays for the
/// entire history (a multi-gigabyte `~/.codex/sessions` turns a sub-second
/// query into tens of CPU-seconds). A file whose modification time predates
/// the query window cannot contain events inside it, so runners hand ccusage
/// a temporary mirror holding hard links to only the recently modified files.
public enum SessionScanPruning {
  /// Buffer below the `--since` day (parsed as UTC midnight) that keeps the
  /// cutoff safe for any `--timezone` the query is evaluated in (max UTC
  /// offset is 14h) and for the remote adapter's `touch -t`, which applies
  /// the token in the remote machine's local timezone.
  static let cutoffBufferSeconds: TimeInterval = 48 * 3_600

  /// Absolute cutoff instant derived from a `--since yyyy-MM-dd` argument,
  /// or nil when the query is unbounded and pruning must not happen.
  public static func mtimeCutoff(arguments: [String]) -> Date? {
    guard let sinceIndex = arguments.firstIndex(of: "--since"),
          arguments.index(after: sinceIndex) < arguments.endIndex else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let day = formatter.date(from: arguments[arguments.index(after: sinceIndex)]) else { return nil }
    return day.addingTimeInterval(-cutoffBufferSeconds)
  }

  /// `touch -t` token (CCYYMMDDhhmm) for the SSH source adapter. Formatted in
  /// UTC; the cutoff buffer absorbs the remote machine's local-time reading.
  public static func mtimeCutoffToken(arguments: [String]) -> String? {
    guard let cutoff = mtimeCutoff(arguments: arguments) else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMddHHmm"
    return formatter.string(from: cutoff)
  }

  /// Builds a mirror of `rootPath` whose scan directory contains only the
  /// JSONL files modified at or after `cutoff`, preserving relative layout so
  /// path-derived metadata stays intact. Files are hard-linked (copied when
  /// linking fails, e.g. across volumes). Returns nil when the mirror cannot
  /// be built; callers then run against the real root. The caller removes the
  /// returned directory once the command has finished.
  public static func prunedRoot(
    original rootPath: String,
    agent: MachineSessionAgent,
    cutoff: Date,
    fileManager: FileManager = .default
  ) -> URL? {
    let scanRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
      .appendingPathComponent(agent.scanDirectoryName, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: scanRoot.path, isDirectory: &isDirectory),
          isDirectory.boolValue else { return nil }
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
    guard let enumerator = fileManager.enumerator(
      at: scanRoot,
      includingPropertiesForKeys: keys,
      options: [.skipsPackageDescendants, .skipsHiddenFiles]
    ) else { return nil }
    // itemReplacementDirectory lands on the same volume as the sessions, so
    // the mirror is hard links rather than copies whenever possible.
    let mirrorBase = (try? fileManager.url(
      for: .itemReplacementDirectory,
      in: .userDomainMask,
      appropriateFor: scanRoot,
      create: true
    )) ?? fileManager.temporaryDirectory
    let mirrorRoot = mirrorBase.appendingPathComponent(
      "ccusage-gauge-pruned-\(agent.rawValue)-\(UUID().uuidString)",
      isDirectory: true
    )
    let mirrorScan = mirrorRoot.appendingPathComponent(agent.scanDirectoryName, isDirectory: true)
    do {
      try fileManager.createDirectory(at: mirrorScan, withIntermediateDirectories: true)
      let scanComponents = scanRoot.standardizedFileURL.pathComponents
      for case let url as URL in enumerator {
        guard url.pathExtension == "jsonl",
              let values = try? url.resourceValues(forKeys: Set(keys)),
              values.isRegularFile == true else { continue }
        guard let modified = values.contentModificationDate, modified >= cutoff else { continue }
        let components = url.standardizedFileURL.pathComponents
        guard components.count > scanComponents.count else { continue }
        var destination = mirrorScan
        for component in components.dropFirst(scanComponents.count) {
          destination.appendPathComponent(component)
        }
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        do {
          try fileManager.linkItem(at: url, to: destination)
        } catch {
          try fileManager.copyItem(at: url, to: destination)
        }
      }
      return mirrorRoot
    } catch {
      try? fileManager.removeItem(at: mirrorRoot)
      return nil
    }
  }
}
