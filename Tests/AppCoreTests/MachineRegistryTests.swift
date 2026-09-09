import Foundation
import Testing
@testable import AppCore

@Suite("MachineRegistryTests") struct MachineRegistryTests {
  @Test func missingRegistrySynthesizesLocalAndCanonicalSaveIsDeterministic() throws {
    let root = try machineTemporaryDirectory()
    let directory = root.appendingPathComponent("config/ccusage-gauge", isDirectory: true)
    let file = directory.appendingPathComponent("machines.json")
    let store = MachineRegistryStore(fileURL: file)
    let empty = try store.load()
    #expect(empty.machines == [.local])
    let b = descriptor(id: "machine-b")
    let a = descriptor(id: "machine-a")
    try store.save(try MachineRegistry(sshMachines: [b, a]))
    let data = try Data(contentsOf: file)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.firstIndex(of: "a") != nil)
    #expect(text.range(of: "machine-a")!.lowerBound < text.range(of: "machine-b")!.lowerBound)
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try store.load().machines.map(\.id) == ["local", "machine-a", "machine-b"])
  }

  @Test func rejectsUnknownVersionFieldsAndUnsafePermissions() throws {
    let root = try machineTemporaryDirectory()
    let directory = root.appendingPathComponent("config/ccusage-gauge", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let file = directory.appendingPathComponent("machines.json")
    try Data(#"{"schemaVersion":2,"machines":[],"extra":true}"#.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(throws: MachineRegistryStoreError.registryLoadFailed) { try MachineRegistryStore(fileURL: file).load() }
    try Data(#"{"schemaVersion":1,"machines":[]}"#.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: MachineRegistryStoreError.registryPermissionsInvalid) { try MachineRegistryStore(fileURL: file).load() }
  }

  @Test func rejectsUnsafeExistingConfigurationDirectoryPermissions() throws {
    let root = try machineTemporaryDirectory()
    let directory = root.appendingPathComponent("config/ccusage-gauge", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

    let store = MachineRegistryStore(fileURL: directory.appendingPathComponent("machines.json"))
    #expect(throws: MachineRegistryStoreError.registryPermissionsInvalid) { try store.load() }
    let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o755)
  }

  @Test func migratesVersionOneToCanonicalVersionThreeWithoutChangingMachines() throws {
    let root = try machineTemporaryDirectory()
    let directory = root.appendingPathComponent("config/ccusage-gauge", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let file = directory.appendingPathComponent("machines.json")
    let original = #"""
    {"schemaVersion":1,"machines":[{
      "id":"remote","displayName":"Remote","kind":"ssh","enabled":true,
      "ssh":{"host":"localhost","port":22,"user":"user","extraOptions":[],"remoteCcusagePath":"ccusage"}
    }]}
    """#
    try Data(original.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

    let registry = try MachineRegistryStore(fileURL: file).load()
    let migrated = String(decoding: try Data(contentsOf: file), as: UTF8.self)

    #expect(registry.machines.map(\.id) == ["local", "remote"])
    #expect(migrated.contains(#""schemaVersion" : 3"#))
    #expect(migrated.contains(#""localSessionSources""#))
    #expect(try MachineRegistryStore(fileURL: file).load() == registry)
  }

  @Test(arguments: ["", "A", "-machine", "machine-", "a_b", "a.b", "all", "local"])
  func rejectsInvalidOrReservedIDs(id: String) {
    #expect(throws: MachineValidationError.self) { try MachineValidation.validate(descriptor: descriptor(id: id)) }
  }

  @Test func normalizesDisplayNamesAndRejectsControlCharacters() throws {
    #expect(try MachineValidation.normalizedDisplayName("  Cafe\u{301}  ") == "Café")
    #expect(throws: MachineValidationError.self) { try MachineValidation.normalizedDisplayName("bad\u{7f}") }
  }

  private func descriptor(id: String) -> MachineDescriptor {
    MachineDescriptor(
      id: id,
      displayName: id,
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "127.0.0.1", port: 22, user: "ccusage")
    )
  }
}
