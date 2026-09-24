import Foundation
import Testing
@testable import AppCore

@Suite("UsageEventLogReaderTests") struct UsageEventLogReaderTests {
  @Test func reverseReaderYieldsEveryLineNewestFirstForAnyWindowSize() throws {
    let lines = (0..<120).map { index -> String in
      String(repeating: Character(UnicodeScalar(UInt8(97 + index % 26))), count: (index * 37) % 301 + 1) + "#\(index)"
    }
    var content = ""
    for (index, line) in lines.enumerated() {
      content += line
      content += index % 7 == 3 ? "\n\n" : "\n"
    }
    content += "tail-without-newline"
    let url = try temporaryFile(content)
    let expected = Array((lines + ["tail-without-newline"]).reversed())

    for chunkSize in [1, 7, 64, 300, 4_096, UsageEventLogReader.defaultReverseChunkSize] {
      var seen: [String] = []
      try UsageEventLogReader.forEachLineFromEnd(in: url, chunkSize: chunkSize) { line in
        seen.append(String(bytes: line, encoding: .utf8) ?? "")
        return true
      }
      #expect(seen == expected, "chunk size \(chunkSize)")
    }
  }

  @Test func reverseReaderStopsWhenBodyDeclinesAndFiltersByNeedle() throws {
    let url = try temporaryFile("alpha 1\nbeta 2\nalpha 3\nbeta 4\nalpha 5\n")
    var seen: [String] = []
    try UsageEventLogReader.forEachLineFromEnd(in: url, matchingAny: [Data("alpha".utf8)], chunkSize: 5) { line in
      seen.append(String(bytes: line, encoding: .utf8) ?? "")
      return seen.count < 2
    }
    #expect(seen == ["alpha 5", "alpha 3"])
  }

  @Test func reverseReaderHonorsEndOffset() throws {
    let url = try temporaryFile("first\nsecond\nthird\n")
    let region = try UsageEventLogReader.region(of: url)
    #expect(region.terminated == region.size)
    var seen: [String] = []
    try UsageEventLogReader.forEachLineFromEnd(in: url, endingAt: UInt64("first\nsecond\n".utf8.count), chunkSize: 4) { line in
      seen.append(String(bytes: line, encoding: .utf8) ?? "")
      return true
    }
    #expect(seen == ["second", "first"])
  }

  @Test func forwardReaderRespectsByteRange() throws {
    let url = try temporaryFile("first\nsecond\nthird\nfourth")
    var seen: [String] = []
    let start = UInt64("first\n".utf8.count)
    let end = UInt64("first\nsecond\nthird\n".utf8.count)
    try UsageEventLogReader.forEachLine(in: url, from: start, to: end) { line in
      seen.append(String(bytes: line, encoding: .utf8) ?? "")
    }
    #expect(seen == ["second", "third"])
    seen = []
    try UsageEventLogReader.forEachLine(in: url, from: end) { line in
      seen.append(String(bytes: line, encoding: .utf8) ?? "")
    }
    #expect(seen == ["fourth"])
  }

  @Test func regionReportsTerminatedPrefixOfUnterminatedFile() throws {
    let terminated = try UsageEventLogReader.region(of: try temporaryFile("one\ntwo\npartial"))
    #expect(terminated.size == 15)
    #expect(terminated.terminated == 8)
    let single = try UsageEventLogReader.region(of: try temporaryFile("no newline at all"))
    #expect(single.terminated == 0)
    let empty = try UsageEventLogReader.region(of: try temporaryFile(""))
    #expect(empty == UsageEventLogRegion(size: 0, terminated: 0))
  }

  private func temporaryFile(_ content: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ccusage-reader-\(UUID().uuidString).jsonl")
    try Data(content.utf8).write(to: url)
    return url
  }
}
