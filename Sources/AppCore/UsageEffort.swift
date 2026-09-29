import Foundation

enum UsageEffort {
  static func normalized(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let bytes = Array(value.utf8)
    guard (1...32).contains(bytes.count), bytes.allSatisfy(isAllowed) else { return nil }
    return value
  }

  private static func isAllowed(_ byte: UInt8) -> Bool {
    (0x61...0x7a).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x5f || byte == 0x2d
  }
}
