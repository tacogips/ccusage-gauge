import Foundation
import Testing
@testable import AppCore

@Suite("MachineSessionSourceRegistryTests")
struct MachineSessionSourceRegistryTests {
  @Test func legacyDescriptorDefaultsToEnabledBuiltInSources() throws {
    let data = Data(#"""
      {"id":"remote","displayName":"Remote","kind":"ssh","enabled":true,
       "ssh":{"host":"localhost","port":22,"user":"user","extraOptions":[],"remoteCcusagePath":"ccusage"}}
      """#.utf8)
    let descriptor = try JSONDecoder().decode(MachineDescriptor.self, from: data)
    #expect(descriptor.codexSessionDirs == [])
    #expect(descriptor.claudeConfigDirs == [])
    #expect(descriptor.includeDefaultCodexDir)
    #expect(descriptor.includeDefaultClaudeDir)
  }

  @Test func validatesEverySessionPathUnderItsIndexedField() {
    let descriptor = MachineDescriptor(
      id: "remote",
      displayName: "Remote",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user"),
      codexSessionDirs: ["/valid", "relative", "~other/path"],
      claudeConfigDirs: ["~/valid", "bad\npath"]
    )
    do {
      try MachineValidation.validate(descriptor: descriptor)
      Issue.record("Expected indexed session-source validation errors")
    } catch let error as MachineValidationError {
      #expect(error.fieldErrors["codexSessionDirs[0]"] == nil)
      #expect(error.fieldErrors["codexSessionDirs[1]"] != nil)
      #expect(error.fieldErrors["codexSessionDirs[2]"] != nil)
      #expect(error.fieldErrors["claudeConfigDirs[0]"] == nil)
      #expect(error.fieldErrors["claudeConfigDirs[1]"] != nil)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func acceptsPosixDotRepeatedAndTrailingSeparatorsWithoutNormalizingStoredValues() throws {
    let values = ["/", "//srv//codex/./sessions/../", "~", "~/claude//./projects/../"]
    let descriptor = MachineDescriptor(
      id: "remote",
      displayName: "Remote",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user"),
      codexSessionDirs: values,
      claudeConfigDirs: values
    )

    try MachineValidation.validate(descriptor: descriptor)
    #expect(descriptor.codexSessionDirs == values)
    #expect(descriptor.claudeConfigDirs == values)
  }

  @Test func versionThreeRoundTripPersistsLocalAndSSHSourceSettings() throws {
    let root = try temporaryDirectory()
    let file = root.appendingPathComponent("config/machines.json")
    let store = MachineRegistryStore(fileURL: file)
    let local = MachineDescriptor(
      id: "local",
      displayName: "Local",
      kind: .local,
      enabled: true,
      codexSessionDirs: ["/srv/local-codex"],
      includeDefaultCodexDir: false
    )
    let remote = MachineDescriptor(
      id: "remote",
      displayName: "Remote",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user"),
      claudeConfigDirs: ["~/remote-claude"],
      includeDefaultClaudeDir: false
    )
    let registry = try MachineRegistry(sshMachines: [remote], localMachine: local)
    try store.save(registry)

    let loaded = try store.load()
    #expect(loaded == registry)
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 3)
    #expect((object["localSessionSources"] as? [String: Any])?["includeDefaultCodexDir"] as? Bool == false)
  }

  @Test func versionTwoMigratesAtomicallyToVersionThreeDefaults() throws {
    let root = try temporaryDirectory()
    let directory = root.appendingPathComponent("config", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let file = directory.appendingPathComponent("machines.json")
    let versionTwo = #"""
      {"schemaVersion":2,"machines":[{
        "id":"remote","displayName":"Remote","kind":"ssh","enabled":true,
        "ssh":{"host":"localhost","port":22,"user":"user","extraOptions":[],"remoteCcusagePath":"ccusage"}
      }]}
      """#
    try Data(versionTwo.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

    let registry = try MachineRegistryStore(fileURL: file).load()
    #expect(registry.localMachine == .local)
    #expect(registry.machine(id: "remote")?.includeDefaultCodexDir == true)
    #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(#""schemaVersion" : 3"#))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
