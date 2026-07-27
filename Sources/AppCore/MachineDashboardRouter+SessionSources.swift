import Foundation

extension MachineDashboardRouter {
  static let sourceKeys: Set<String> = [
    "codexSessionDirs",
    "claudeConfigDirs",
    "includeDefaultCodexDir",
    "includeDefaultClaudeDir"
  ]
  static let machineCreateKeys = sourceKeys.union(["id", "displayName", "kind", "enabled", "ssh"])
  static let machineReplaceKeys = sourceKeys.union(["displayName", "kind", "enabled", "ssh"])
  static let machinePatchKeys = sourceKeys.union(["displayName", "enabled", "ssh"])

  func patchLocal(
    _ request: MachinePatchRequest
  ) async throws -> (MachineRegistry, MachineDescriptor) {
    guard request.containsOnlySessionSources else {
      throw MachineRegistryMutationError.conflict
    }
    return try await mutationOwner.patchLocalSources(
      codexSessionDirs: request.codexSessionDirs,
      claudeConfigDirs: request.claudeConfigDirs,
      includeDefaultCodexDir: request.includeDefaultCodexDir,
      includeDefaultClaudeDir: request.includeDefaultClaudeDir
    )
  }
}
