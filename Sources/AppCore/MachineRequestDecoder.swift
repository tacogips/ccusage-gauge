import Foundation

enum MachineBodyError: Error {
  case invalid
}

enum MachineRequestDecoder {
  static func decode<T: Decodable>(
    _ body: Data,
    allowedKeys: Set<String>,
    requiredKeys: Set<String> = []
  ) throws -> T {
    guard body.count <= 65_536,
          let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
          Set(object.keys).isSubset(of: allowedKeys) else {
      throw MachineBodyError.invalid
    }
    // Explicit top-level nulls mean "field omitted" (JSON-merge-patch style),
    // so they satisfy neither requiredKeys nor reach the typed decoder.
    let cleaned = object.filter { !($0.value is NSNull) }
    guard requiredKeys.isSubset(of: Set(cleaned.keys)) else {
      throw MachineBodyError.invalid
    }
    try validateSSHObject(cleaned["ssh"])
    let sanitized = try JSONSerialization.data(withJSONObject: cleaned)
    return try JSONDecoder().decode(T.self, from: sanitized)
  }

  private static func validateSSHObject(_ rawValue: Any?) throws {
    guard let rawValue else { return }
    guard let ssh = rawValue as? [String: Any] else { throw MachineBodyError.invalid }
    let allowed = Set(["host", "port", "user", "identityFile", "extraOptions", "proxy", "remoteCcusagePath"])
    let required = Set(["host", "port", "user"])
    guard Set(ssh.keys).isSubset(of: allowed),
          required.isSubset(of: Set(ssh.keys)),
          ssh["identityFile"] is NSNull == false,
          ssh["proxy"] is NSNull == false else {
      throw MachineBodyError.invalid
    }
    guard let proxy = ssh["proxy"] else { return }
    guard let object = proxy as? [String: Any],
          let kind = object["kind"] as? String else {
      throw MachineBodyError.invalid
    }
    let keys = Set(object.keys)
    switch kind {
    case "direct":
      guard keys == ["kind"] else { throw MachineBodyError.invalid }
    case "jump":
      let required = Set(["kind", "host", "port", "user"])
      guard required.isSubset(of: keys),
            keys.isSubset(of: required.union(["identityFile", "knownHostsFile"])),
            object["identityFile"] is NSNull == false,
            object["knownHostsFile"] is NSNull == false else {
        throw MachineBodyError.invalid
      }
    case "command":
      guard keys == ["kind", "executable"] else { throw MachineBodyError.invalid }
    default:
      throw MachineBodyError.invalid
    }
  }
}
