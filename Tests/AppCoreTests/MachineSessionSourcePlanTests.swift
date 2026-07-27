import Foundation
import Testing
@testable import AppCore

@Suite("MachineSessionSourcePlanTests")
struct MachineSessionSourcePlanTests {
  @Test func aggregatesDisjointRootsAndDisablesDefaults() throws {
    let root = try temporaryDirectory()
    let codexA = root.appendingPathComponent("codex-a", isDirectory: true)
    let codexB = root.appendingPathComponent("codex-b", isDirectory: true)
    let claude = root.appendingPathComponent("claude", isDirectory: true)
    for directory in [
      codexA.appendingPathComponent("sessions"),
      codexB.appendingPathComponent("sessions"),
      claude.appendingPathComponent("projects")
    ] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let descriptor = MachineDescriptor(
      id: "local",
      displayName: "Local",
      kind: .local,
      enabled: true,
      codexSessionDirs: [codexA.path, codexB.path],
      claudeConfigDirs: [claude.path],
      includeDefaultCodexDir: false,
      includeDefaultClaudeDir: false
    )

    let plan = MachineSessionSourcePlan(descriptor: descriptor, environment: ["HOME": root.path])
    #expect(plan.commandSources(for: .codex).count == 2)
    #expect(plan.commandSources(for: .claude).count == 1)
    #expect(plan.commandSources(for: .codex).allSatisfy { !$0.isDefault })
  }

  @Test func equalNestedAndSymlinkAliasScopesAreDeduplicated() throws {
    let root = try temporaryDirectory()
    let codex = root.appendingPathComponent("codex", isDirectory: true)
    try FileManager.default.createDirectory(
      at: codex.appendingPathComponent("sessions/nested"),
      withIntermediateDirectories: true
    )
    let alias = root.appendingPathComponent("codex-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: codex)
    let descriptor = MachineDescriptor(
      id: "local",
      displayName: "Local",
      kind: .local,
      enabled: true,
      codexSessionDirs: [codex.path, codex.path, alias.path, codex.appendingPathComponent("sessions").path],
      includeDefaultCodexDir: false,
      includeDefaultClaudeDir: false
    )
    let plan = MachineSessionSourcePlan(descriptor: descriptor, environment: ["HOME": root.path])
    #expect(plan.commandSources(for: .codex).count == 1)
  }

  @Test func missingSourceAppearsInFingerprintAndIsObservedOnNextPlan() throws {
    let root = try temporaryDirectory()
    let codex = root.appendingPathComponent("codex", isDirectory: true)
    let descriptor = MachineDescriptor(
      id: "local",
      displayName: "Local",
      kind: .local,
      enabled: true,
      codexSessionDirs: [codex.path],
      includeDefaultCodexDir: false,
      includeDefaultClaudeDir: false
    )
    let missing = MachineSessionSourcePlan(descriptor: descriptor, environment: ["HOME": root.path])
    #expect(missing.commandSources(for: .codex).isEmpty)
    try FileManager.default.createDirectory(
      at: codex.appendingPathComponent("sessions"),
      withIntermediateDirectories: true
    )
    let present = MachineSessionSourcePlan(descriptor: descriptor, environment: ["HOME": root.path])
    #expect(present.commandSources(for: .codex).count == 1)
    #expect(present.fingerprint != missing.fingerprint)
  }

  @Test func scanDirectorySymlinkRetargetChangesTheNextPlanFingerprint() throws {
    let root = try temporaryDirectory()
    let codex = root.appendingPathComponent("codex", isDirectory: true)
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let sessions = codex.appendingPathComponent("sessions")
    try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: first)
    let descriptor = MachineDescriptor(
      id: "local",
      displayName: "Local",
      kind: .local,
      enabled: true,
      codexSessionDirs: [codex.path],
      includeDefaultCodexDir: false,
      includeDefaultClaudeDir: false
    )

    let firstPlan = MachineSessionSourcePlan(descriptor: descriptor, environment: ["HOME": root.path])
    try FileManager.default.removeItem(at: sessions)
    try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: second)
    let secondPlan = MachineSessionSourcePlan(descriptor: descriptor, environment: ["HOME": root.path])

    #expect(firstPlan.codex.first?.scanScope == first.path)
    #expect(secondPlan.codex.first?.scanScope == second.path)
    #expect(firstPlan.fingerprint != secondPlan.fingerprint)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
