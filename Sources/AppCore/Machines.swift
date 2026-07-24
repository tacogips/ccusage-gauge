import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum MachineKind: String, Codable, Sendable {
  case local
  case ssh
}

public struct SSHJumpProxy: Codable, Equatable, Sendable {
  public let host: String
  public let port: Int
  public let user: String
  public let identityFile: String?
  public let knownHostsFile: String?

  public init(
    host: String,
    port: Int = 22,
    user: String,
    identityFile: String? = nil,
    knownHostsFile: String? = nil
  ) {
    self.host = host
    self.port = port
    self.user = user
    self.identityFile = identityFile
    self.knownHostsFile = knownHostsFile
  }
}

public enum SSHProxy: Equatable, Sendable {
  case direct
  case jump(SSHJumpProxy)
  case command(executable: String)
}

extension SSHProxy: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, host, port, user, identityFile, knownHostsFile, executable
  }

  private enum Kind: String, Codable {
    case direct, jump, command
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .kind) {
    case .direct:
      self = .direct
    case .jump:
      self = .jump(SSHJumpProxy(
        host: try values.decode(String.self, forKey: .host),
        port: try values.decode(Int.self, forKey: .port),
        user: try values.decode(String.self, forKey: .user),
        identityFile: try values.decodeIfPresent(String.self, forKey: .identityFile),
        knownHostsFile: try values.decodeIfPresent(String.self, forKey: .knownHostsFile)
      ))
    case .command:
      self = .command(executable: try values.decode(String.self, forKey: .executable))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .direct:
      try values.encode(Kind.direct, forKey: .kind)
    case .jump(let jump):
      try values.encode(Kind.jump, forKey: .kind)
      try values.encode(jump.host, forKey: .host)
      try values.encode(jump.port, forKey: .port)
      try values.encode(jump.user, forKey: .user)
      try values.encodeIfPresent(jump.identityFile, forKey: .identityFile)
      try values.encodeIfPresent(jump.knownHostsFile, forKey: .knownHostsFile)
    case .command(let executable):
      try values.encode(Kind.command, forKey: .kind)
      try values.encode(executable, forKey: .executable)
    }
  }
}

public struct SSHConnection: Codable, Equatable, Sendable {
  public let host: String
  public let port: Int
  public let user: String
  public let identityFile: String?
  public let extraOptions: [String]
  public let proxy: SSHProxy?
  public let remoteCcusagePath: String

  public init(
    host: String,
    port: Int,
    user: String,
    identityFile: String? = nil,
    extraOptions: [String] = [],
    proxy: SSHProxy? = nil,
    remoteCcusagePath: String = "ccusage"
  ) {
    self.host = host
    self.port = port
    self.user = user
    self.identityFile = identityFile
    self.extraOptions = extraOptions
    self.proxy = proxy
    self.remoteCcusagePath = remoteCcusagePath
  }
}

public struct MachineDescriptor: Codable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let kind: MachineKind
  public let enabled: Bool
  public let ssh: SSHConnection?

  public init(id: String, displayName: String, kind: MachineKind, enabled: Bool, ssh: SSHConnection? = nil) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.enabled = enabled
    self.ssh = ssh
  }

  public static let local = MachineDescriptor(
    id: "local",
    displayName: "Local",
    kind: .local,
    enabled: true
  )

  private enum CodingKeys: String, CodingKey { case id, displayName, kind, enabled, ssh }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    displayName = try values.decode(String.self, forKey: .displayName)
    kind = try values.decode(MachineKind.self, forKey: .kind)
    enabled = try values.decode(Bool.self, forKey: .enabled)
    ssh = try values.decodeIfPresent(SSHConnection.self, forKey: .ssh)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(displayName, forKey: .displayName)
    try values.encode(kind, forKey: .kind)
    try values.encode(enabled, forKey: .enabled)
    try values.encodeIfPresent(ssh, forKey: .ssh)
  }
}

public struct MachineValidationError: Error, Equatable, Sendable {
  public let fieldErrors: [String: String]

  public init(fieldErrors: [String: String]) {
    self.fieldErrors = fieldErrors
  }
}

public enum MachineValidation {
  private static let idPattern = try! NSRegularExpression(pattern: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
  private static let userPattern = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9._-]*$")
  private static let executableComponentPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._+\\-]*$")

  public static func validate(descriptor: MachineDescriptor, allowSyntheticLocal: Bool = false) throws {
    var errors: [String: String] = [:]
    if descriptor.kind == .local {
      if !allowSyntheticLocal || descriptor != .local { errors["kind"] = "must be ssh" }
    } else {
      if !isCanonicalMachineID(descriptor.id) {
        errors["id"] = "must be 1...63 lowercase ASCII letters, digits, or interior hyphens"
      } else if descriptor.id == "local" || descriptor.id == "all" {
        errors["id"] = "is reserved"
      }
      if let message = displayNameError(descriptor.displayName) { errors["displayName"] = message }
      guard let connection = descriptor.ssh else {
        errors["ssh"] = "is required"
        throw MachineValidationError(fieldErrors: errors)
      }
      do { try validate(connection: connection, requireReadableIdentity: false) }
      catch let error as MachineValidationError { errors.merge(error.fieldErrors) { current, _ in current } }
    }
    if !errors.isEmpty { throw MachineValidationError(fieldErrors: errors) }
  }

  public static func validate(connection: SSHConnection, requireReadableIdentity: Bool) throws {
    var errors: [String: String] = [:]
    if !isValidHost(connection.host) { errors["ssh.host"] = "must be a valid DNS name or IP literal" }
    if !(1...65_535).contains(connection.port) { errors["ssh.port"] = "must be in 1...65535" }
    if !matches(userPattern, connection.user) { errors["ssh.user"] = "has invalid characters" }
    if !isValidExecutable(connection.remoteCcusagePath) {
      errors["ssh.remoteCcusagePath"] = "must be one executable name or absolute POSIX path"
    }
    if let path = connection.identityFile {
      if !isNormalizedAbsolutePath(path) {
        errors["ssh.identityFile"] = "must be a normalized absolute local path"
      } else if requireReadableIdentity && !isSafeIdentityFile(path) {
        errors["ssh.identityFile"] = "must be a readable user-only regular file"
      }
    }
    validate(proxy: connection.proxy, requireReadableIdentity: requireReadableIdentity, errors: &errors)
    do { try validateExtraOptions(connection.extraOptions) }
    catch let error as MachineValidationError { errors.merge(error.fieldErrors) { current, _ in current } }
    if !errors.isEmpty { throw MachineValidationError(fieldErrors: errors) }
  }

  private static func validate(
    proxy: SSHProxy?,
    requireReadableIdentity: Bool,
    errors: inout [String: String]
  ) {
    guard let proxy else { return }
    switch proxy {
    case .direct:
      return
    case .jump(let jump):
      if !isValidHost(jump.host) { errors["ssh.proxy.host"] = "must be a valid DNS name or IP literal" }
      if !(1...65_535).contains(jump.port) { errors["ssh.proxy.port"] = "must be in 1...65535" }
      if !matches(userPattern, jump.user) { errors["ssh.proxy.user"] = "has invalid characters" }
      for (field, path) in [
        ("ssh.proxy.identityFile", jump.identityFile),
        ("ssh.proxy.knownHostsFile", jump.knownHostsFile)
      ] {
        guard let path else { continue }
        if !isNormalizedAbsolutePath(path) {
          errors[field] = "must be a normalized absolute local path"
        } else if requireReadableIdentity, field.hasSuffix("identityFile"), !isSafeIdentityFile(path) {
          errors[field] = "must be a readable user-only regular file"
        }
      }
    case .command(let executable):
      if !isNormalizedAbsolutePath(executable) {
        errors["ssh.proxy.executable"] = "must be a normalized absolute executable path"
      } else if requireReadableIdentity && !isSafeProxyExecutable(executable) {
        errors["ssh.proxy.executable"] = "must be a current-user executable regular file"
      }
    }
  }

  public static func normalizedDisplayName(_ value: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    if let message = displayNameError(normalized) {
      throw MachineValidationError(fieldErrors: ["displayName": message])
    }
    return normalized
  }

  public static func isCanonicalMachineID(_ value: String) -> Bool {
    guard value.utf8.count <= 63 else { return false }
    return matches(idPattern, value)
  }

  public static func destination(_ connection: SSHConnection) -> String {
    connection.host.contains(":") ? "\(connection.user)@[\(connection.host)]" : "\(connection.user)@\(connection.host)"
  }

  private static func displayNameError(_ value: String) -> String? {
    let scalars = value.unicodeScalars
    guard (1...80).contains(scalars.count), value.utf8.count <= 256,
          !scalars.contains(where: { scalar in
            scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029
          }) else {
      return "must contain 1...80 permitted Unicode scalars and at most 256 UTF-8 bytes"
    }
    return nil
  }

  private static func validateExtraOptions(_ values: [String]) throws {
    var seen: Set<String> = []
    var addressFamily: String?
    let bounded: [String: ClosedRange<Int>] = [
      "ConnectTimeout": 1...600,
      "ConnectionAttempts": 1...10,
      "ServerAliveInterval": 0...3_600,
      "ServerAliveCountMax": 0...100
    ]
    for value in values {
      guard seen.insert(value).inserted else { throw optionError() }
      if value == "-4" || value == "-6" {
        guard addressFamily == nil else { throw optionError() }
        addressFamily = value
        continue
      }
      guard value.hasPrefix("-o "), value.count > 3 else { throw optionError() }
      let option = String(value.dropFirst(3))
      let parts = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
      guard parts.count == 2 else { throw optionError() }
      if let range = bounded[parts[0]], let number = Int(parts[1]), range.contains(number), String(number) == parts[1] {
        continue
      }
      if parts[0] == "LogLevel", ["ERROR", "QUIET", "FATAL"].contains(parts[1]) { continue }
      if parts[0] == "StrictHostKeyChecking", ["yes", "accept-new"].contains(parts[1]) { continue }
      if parts[0] == "UserKnownHostsFile", isNormalizedAbsolutePath(parts[1]) { continue }
      throw optionError()
    }
  }

  private static func optionError() -> MachineValidationError {
    MachineValidationError(fieldErrors: ["ssh.extraOptions": "contains an unsupported or duplicate SSH option"])
  }

  private static func isValidHost(_ host: String) -> Bool {
    guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
    if host == "localhost" { return true }
    if host.contains(":") {
      var address = in6_addr()
      return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }
    var address = in_addr()
    if host.withCString({ inet_pton(AF_INET, $0, &address) == 1 }) { return true }
    guard host.utf8.count <= 253 else { return false }
    return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-" else { return false }
      return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
  }

  private static func isValidExecutable(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    if value.hasPrefix("/") {
      guard components.first == "", components.count > 1 else { return false }
      return components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && matches(executableComponentPattern, $0) }
    }
    return components.count == 1 && matches(executableComponentPattern, value)
  }

  private static func isNormalizedAbsolutePath(_ path: String) -> Bool {
    guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
    return URL(fileURLWithPath: path).standardizedFileURL.path == path
  }

  private static func isSafeIdentityFile(_ path: String) -> Bool {
    var metadata = stat()
    guard lstat(path, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == getuid(),
          metadata.st_mode & 0o077 == 0,
          access(path, R_OK) == 0 else { return false }
    return true
  }

  private static func isSafeProxyExecutable(_ path: String) -> Bool {
    var metadata = stat()
    guard lstat(path, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == getuid(),
          metadata.st_mode & 0o022 == 0,
          access(path, X_OK) == 0 else { return false }
    return true
  }

  private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
    expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
  }
}

public struct MachineRegistry: Equatable, Sendable {
  public let revision: UInt64
  public let machines: [MachineDescriptor]

  public init(sshMachines: [MachineDescriptor] = [], revision: UInt64 = 0) throws {
    var ids: Set<String> = []
    for descriptor in sshMachines {
      try MachineValidation.validate(descriptor: descriptor)
      guard ids.insert(descriptor.id).inserted else {
        throw MachineValidationError(fieldErrors: ["id": "must be unique"])
      }
    }
    self.revision = revision
    machines = [.local] + sshMachines.sorted { $0.id < $1.id }
  }

  public var sshMachines: [MachineDescriptor] { machines.filter { $0.kind == .ssh } }
  public func machine(id: String) -> MachineDescriptor? { machines.first { $0.id == id } }
}

public enum MachineRegistryStoreError: Error, Equatable, CustomStringConvertible, Sendable {
  case registryLoadFailed
  case registryPermissionsInvalid
  case registryPersistenceFailed

  public var description: String {
    switch self {
    case .registryLoadFailed: "Machine registry could not be loaded"
    case .registryPermissionsInvalid:
      "Machine registry permissions are invalid. Set the configuration directory mode to 0700 and machines.json to 0600."
    case .registryPersistenceFailed: "Machine registry could not be persisted"
    }
  }
}

private struct PersistedMachineRegistry: Codable {
  let schemaVersion: Int
  let machines: [MachineDescriptor]
}

public protocol MachineRegistryPersistence: Sendable {
  func load() throws -> MachineRegistry
  func save(_ registry: MachineRegistry) throws
}

public struct MachineRegistryStore: MachineRegistryPersistence, @unchecked Sendable {
  public let fileURL: URL
  private let fileManager: FileManager

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public func load() throws -> MachineRegistry {
    do {
      try ensureSafeDirectory()
      guard fileManager.fileExists(atPath: fileURL.path) else {
        try proveWritableDirectory()
        return try MachineRegistry()
      }
      try validateFileMetadata()
      let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
      guard data.count <= 65_536 else { throw MachineRegistryStoreError.registryLoadFailed }
      let schemaVersion = try validateClosedShape(data)
      let persisted = try JSONDecoder().decode(PersistedMachineRegistry.self, from: data)
      guard persisted.schemaVersion == schemaVersion, persisted.machines.allSatisfy({ $0.kind == .ssh }) else {
        throw MachineRegistryStoreError.registryLoadFailed
      }
      for descriptor in persisted.machines {
        if let connection = descriptor.ssh { try MachineValidation.validate(connection: connection, requireReadableIdentity: true) }
      }
      let registry = try MachineRegistry(sshMachines: persisted.machines)
      if schemaVersion == 1 {
        // Best-effort migration: a readable, valid v1 file must keep loading
        // even when the rewrite cannot be persisted (read-only file or
        // filesystem); the next successful save writes the v2 shape.
        try? save(registry)
      }
      return registry
    } catch let error as MachineRegistryStoreError {
      throw error
    } catch {
      throw MachineRegistryStoreError.registryLoadFailed
    }
  }

  public func save(_ registry: MachineRegistry) throws {
    do {
      try ensureSafeDirectory()
      for descriptor in registry.sshMachines {
        try MachineValidation.validate(descriptor: descriptor)
        if let connection = descriptor.ssh { try MachineValidation.validate(connection: connection, requireReadableIdentity: true) }
      }
      let payload = PersistedMachineRegistry(schemaVersion: 2, machines: registry.sshMachines.sorted { $0.id < $1.id })
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      var data = try encoder.encode(payload)
      data.append(0x0A)
      let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".machines.\(UUID().uuidString).tmp")
      defer { try? fileManager.removeItem(at: temporary) }
      try data.write(to: temporary, options: .withoutOverwriting)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
      let descriptor = open(temporary.path, O_RDONLY)
      guard descriptor >= 0, fsync(descriptor) == 0 else {
        if descriptor >= 0 { close(descriptor) }
        throw MachineRegistryStoreError.registryPersistenceFailed
      }
      close(descriptor)
      guard rename(temporary.path, fileURL.path) == 0 else { throw MachineRegistryStoreError.registryPersistenceFailed }
      try validateFileMetadata()
    } catch let error as MachineRegistryStoreError {
      throw error
    } catch {
      throw MachineRegistryStoreError.registryPersistenceFailed
    }
  }

  private func ensureSafeDirectory() throws {
    let directory = fileURL.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: directory.path) {
      do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      } catch { throw MachineRegistryStoreError.registryPersistenceFailed }
    }
    var metadata = stat()
    guard lstat(directory.path, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR,
          metadata.st_uid == getuid() else {
      throw MachineRegistryStoreError.registryPermissionsInvalid
    }
    guard metadata.st_mode & 0o777 == 0o700 else {
      throw MachineRegistryStoreError.registryPermissionsInvalid
    }
  }

  private func validateFileMetadata() throws {
    var metadata = stat()
    guard lstat(fileURL.path, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_nlink == 1,
          metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600 else {
      throw MachineRegistryStoreError.registryPermissionsInvalid
    }
  }

  private func proveWritableDirectory() throws {
    let probe = fileURL.deletingLastPathComponent().appendingPathComponent(".machines-probe-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: probe) }
    do {
      try Data().write(to: probe, options: .withoutOverwriting)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: probe.path)
      let descriptor = open(probe.path, O_RDONLY)
      guard descriptor >= 0, fsync(descriptor) == 0 else {
        if descriptor >= 0 { close(descriptor) }
        throw MachineRegistryStoreError.registryPersistenceFailed
      }
      close(descriptor)
    } catch { throw MachineRegistryStoreError.registryPersistenceFailed }
  }

  private func validateClosedShape(_ data: Data) throws -> Int {
    guard JSONDuplicateKeyScanner(data: data).isValid else {
      throw MachineRegistryStoreError.registryLoadFailed
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == ["schemaVersion", "machines"],
          object["schemaVersion"] != nil,
          let machines = object["machines"] as? [[String: Any]] else {
      throw MachineRegistryStoreError.registryLoadFailed
    }
    // Validate the raw token so Boolean and exponent spellings cannot alias an
    // integer through Foundation's NSNumber bridging.
    // (rejecting true/false, strings, and non-integer forms portably) rather than
    // an NSNumber type check, which cannot reliably tell 0/1 from a boolean.
    let text = String(decoding: data, as: UTF8.self)
    let versionTokens = capturedNumberTokens(named: "schemaVersion", in: text)
    guard versionTokens.count == 1, let version = Int(versionTokens[0]), [1, 2].contains(version),
          String(version) == versionTokens[0] else {
      throw MachineRegistryStoreError.registryLoadFailed
    }
    let portTokens = capturedNumberTokens(named: "port", in: text)
    guard portTokens.count >= machines.count,
          portTokens.allSatisfy({ !$0.contains(".") && !$0.lowercased().contains("e") && Int($0) != nil }) else {
      throw MachineRegistryStoreError.registryLoadFailed
    }
    for machine in machines {
      guard Set(machine.keys) == ["id", "displayName", "kind", "enabled", "ssh"],
            machine["kind"] as? String == "ssh",
            let ssh = machine["ssh"] as? [String: Any] else {
        throw MachineRegistryStoreError.registryLoadFailed
      }
      let allowed = Set(["host", "port", "user", "identityFile", "extraOptions", "proxy", "remoteCcusagePath"])
      let required = Set(["host", "port", "user", "extraOptions", "remoteCcusagePath"])
      guard Set(ssh.keys).isSubset(of: version == 1 ? allowed.subtracting(["proxy"]) : allowed),
            required.isSubset(of: Set(ssh.keys)),
            ssh["identityFile"] is NSNull == false,
            ssh["proxy"] is NSNull == false else {
        throw MachineRegistryStoreError.registryLoadFailed
      }
      if let proxy = ssh["proxy"] as? [String: Any] {
        guard version == 2, let kind = proxy["kind"] as? String else {
          throw MachineRegistryStoreError.registryLoadFailed
        }
        let keys = Set(proxy.keys)
        switch kind {
        case "direct":
          guard keys == ["kind"] else { throw MachineRegistryStoreError.registryLoadFailed }
        case "jump":
          let required = Set(["kind", "host", "port", "user"])
          let allowed = required.union(["identityFile", "knownHostsFile"])
          guard required.isSubset(of: keys), keys.isSubset(of: allowed),
                proxy["identityFile"] is NSNull == false,
                proxy["knownHostsFile"] is NSNull == false else {
            throw MachineRegistryStoreError.registryLoadFailed
          }
        case "command":
          guard keys == ["kind", "executable"] else { throw MachineRegistryStoreError.registryLoadFailed }
        default:
          throw MachineRegistryStoreError.registryLoadFailed
        }
      } else if ssh.keys.contains("proxy") {
        throw MachineRegistryStoreError.registryLoadFailed
      }
    }
    return version
  }

  private func capturedNumberTokens(named key: String, in text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: "\\\"\(key)\\\"\\s*:\\s*([-+0-9.eE]+)") else { return [] }
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
      guard let range = Range(match.range(at: 1), in: text) else { return nil }
      return String(text[range])
    }
  }
}

public enum MachineRegistryMutationError: Error, Equatable, Sendable {
  case conflict
  case notFound
}

private struct JSONDuplicateKeyScanner {
  let bytes: [UInt8]
  var index = 0

  init(data: Data) { bytes = Array(data) }

  var isValid: Bool {
    var scanner = self
    do {
      try scanner.parseValue()
      scanner.skipWhitespace()
      return scanner.index == scanner.bytes.count
    } catch { return false }
  }

  private mutating func parseValue() throws {
    skipWhitespace()
    guard let byte = current else { throw ScanError.invalid }
    switch byte {
    case 0x7B: try parseObject()
    case 0x5B: try parseArray()
    case 0x22: _ = try parseString()
    case 0x74: try consume("true")
    case 0x66: try consume("false")
    case 0x6E: try consume("null")
    case 0x2D, 0x30...0x39: try parseNumber()
    default: throw ScanError.invalid
    }
  }

  private mutating func parseObject() throws {
    index += 1
    skipWhitespace()
    if current == 0x7D { index += 1; return }
    var keys: Set<String> = []
    while true {
      let key = try parseString()
      guard keys.insert(key).inserted else { throw ScanError.invalid }
      skipWhitespace()
      guard current == 0x3A else { throw ScanError.invalid }
      index += 1
      try parseValue()
      skipWhitespace()
      if current == 0x7D { index += 1; return }
      guard current == 0x2C else { throw ScanError.invalid }
      index += 1
      skipWhitespace()
    }
  }

  private mutating func parseArray() throws {
    index += 1
    skipWhitespace()
    if current == 0x5D { index += 1; return }
    while true {
      try parseValue()
      skipWhitespace()
      if current == 0x5D { index += 1; return }
      guard current == 0x2C else { throw ScanError.invalid }
      index += 1
    }
  }

  private mutating func parseString() throws -> String {
    skipWhitespace()
    guard current == 0x22 else { throw ScanError.invalid }
    let start = index
    index += 1
    var escaped = false
    while let byte = current {
      index += 1
      if escaped { escaped = false; continue }
      if byte == 0x5C { escaped = true; continue }
      if byte == 0x22 {
        return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
      }
      if byte < 0x20 { throw ScanError.invalid }
    }
    throw ScanError.invalid
  }

  private mutating func parseNumber() throws {
    let allowed = Set("-+0123456789.eE".utf8)
    let start = index
    while let byte = current, allowed.contains(byte) { index += 1 }
    guard index > start else { throw ScanError.invalid }
    let token = String(decoding: bytes[start..<index], as: UTF8.self)
    guard Double(token) != nil else { throw ScanError.invalid }
  }

  private mutating func consume(_ text: String) throws {
    let value = Array(text.utf8)
    guard index + value.count <= bytes.count,
          Array(bytes[index..<(index + value.count)]) == value else { throw ScanError.invalid }
    index += value.count
  }

  private mutating func skipWhitespace() {
    while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) { index += 1 }
  }

  private var current: UInt8? { index < bytes.count ? bytes[index] : nil }
  private enum ScanError: Error { case invalid }
}
