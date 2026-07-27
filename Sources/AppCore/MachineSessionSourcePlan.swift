import Foundation

enum MachineSessionSourceAttempt {
  @TaskLocal static var plan: MachineSessionSourcePlan?
  @TaskLocal static var cacheGeneration: UInt64?
  @TaskLocal static var publicationGeneration: UInt64?
}

actor MachineSessionSourceGenerationFence {
  private var fingerprint: String?
  private var generation: UInt64 = 0

  func begin(fingerprint: String) -> UInt64 {
    if self.fingerprint != fingerprint {
      generation &+= 1
      self.fingerprint = fingerprint
    }
    return generation
  }

  func isCurrent(fingerprint: String, generation: UInt64) -> Bool {
    self.fingerprint == fingerprint && self.generation == generation
  }
}

public enum MachineSessionAgent: String, CaseIterable, Sendable {
  case codex
  case claude

  var environmentKey: String {
    switch self {
    case .codex: "CODEX_HOME"
    case .claude: "CLAUDE_CONFIG_DIR"
    }
  }

  var defaultDirectoryName: String {
    switch self {
    case .codex: ".codex"
    case .claude: ".claude"
    }
  }

  var scanDirectoryName: String {
    switch self {
    case .codex: "sessions"
    case .claude: "projects"
    }
  }
}

public enum MachineSessionSourceExecution: Equatable, Sendable {
  case value(String)
  case remoteDefault
}

public struct MachineSessionSource: Equatable, Sendable {
  public let agent: MachineSessionAgent
  public let execution: MachineSessionSourceExecution
  public let resolvedRoot: String
  public let scanScope: String
  public let exists: Bool
  public let isDirectory: Bool
  public let isDefault: Bool

  public init(
    agent: MachineSessionAgent,
    execution: MachineSessionSourceExecution,
    resolvedRoot: String,
    scanScope: String,
    exists: Bool,
    isDirectory: Bool,
    isDefault: Bool
  ) {
    self.agent = agent
    self.execution = execution
    self.resolvedRoot = resolvedRoot
    self.scanScope = scanScope
    self.exists = exists
    self.isDirectory = isDirectory
    self.isDefault = isDefault
  }
}

public struct MachineSessionSourcePlan: Equatable, Sendable {
  public let codex: [MachineSessionSource]
  public let claude: [MachineSessionSource]
  public let fingerprint: String

  public init(
    descriptor: MachineDescriptor,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    remote: Bool = false
  ) {
    if remote {
      codex = Self.remoteSources(agent: .codex, descriptor: descriptor)
      claude = Self.remoteSources(agent: .claude, descriptor: descriptor)
    } else {
      codex = Self.localSources(agent: .codex, descriptor: descriptor, environment: environment)
      claude = Self.localSources(agent: .claude, descriptor: descriptor, environment: environment)
    }
    fingerprint = Self.makeFingerprint(descriptor: descriptor, codex: codex, claude: claude)
  }

  init(
    descriptor: MachineDescriptor,
    codex: [MachineSessionSource],
    claude: [MachineSessionSource]
  ) {
    self.codex = Self.deduplicated(codex)
    self.claude = Self.deduplicated(claude)
    fingerprint = Self.makeFingerprint(descriptor: descriptor, codex: self.codex, claude: self.claude)
  }

  public func sources(for agent: MachineSessionAgent) -> [MachineSessionSource] {
    switch agent {
    case .codex: codex
    case .claude: claude
    }
  }

  public func commandSources(for agent: MachineSessionAgent) -> [MachineSessionSource] {
    sources(for: agent).filter { $0.isDirectory }
  }

  public func eventRoots(for agent: MachineSessionAgent) -> [URL] {
    commandSources(for: agent).map { URL(fileURLWithPath: $0.scanScope, isDirectory: true) }
  }

  private static func localSources(
    agent: MachineSessionAgent,
    descriptor: MachineDescriptor,
    environment: [String: String]
  ) -> [MachineSessionSource] {
    let home = environment["HOME"] ?? NSHomeDirectory()
    let configured = agent == .codex ? descriptor.codexSessionDirs : descriptor.claudeConfigDirs
    let includeDefault = agent == .codex ? descriptor.includeDefaultCodexDir : descriptor.includeDefaultClaudeDir
    var candidates: [(value: String, isDefault: Bool)] = []
    if includeDefault {
      candidates.append((environment[agent.environmentKey] ?? "\(home)/\(agent.defaultDirectoryName)", true))
    }
    candidates += configured.map { (expandTilde($0, home: home), false) }
    return deduplicated(candidates.map { candidate in
      localSource(agent: agent, value: candidate.value, isDefault: candidate.isDefault)
    })
  }

  private static func localSource(
    agent: MachineSessionAgent,
    value: String,
    isDefault: Bool
  ) -> MachineSessionSource {
    let root = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    let scan = root.appendingPathComponent(agent.scanDirectoryName, isDirectory: true)
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    let exists = manager.fileExists(atPath: scan.path, isDirectory: &isDirectory)
    let resolvedRoot = (exists ? root.resolvingSymlinksInPath() : root).standardizedFileURL
    let resolvedScan = (
      exists
        ? scan.resolvingSymlinksInPath()
        : resolvedRoot.appendingPathComponent(agent.scanDirectoryName, isDirectory: true)
    ).standardizedFileURL
    return MachineSessionSource(
      agent: agent,
      execution: .value(value),
      resolvedRoot: resolvedRoot.path,
      scanScope: resolvedScan.path,
      exists: exists,
      isDirectory: exists && isDirectory.boolValue,
      isDefault: isDefault
    )
  }

  private static func remoteSources(
    agent: MachineSessionAgent,
    descriptor: MachineDescriptor
  ) -> [MachineSessionSource] {
    let configured = agent == .codex ? descriptor.codexSessionDirs : descriptor.claudeConfigDirs
    let includeDefault = agent == .codex ? descriptor.includeDefaultCodexDir : descriptor.includeDefaultClaudeDir
    var sources: [MachineSessionSource] = []
    if includeDefault {
      sources.append(MachineSessionSource(
        agent: agent,
        execution: .remoteDefault,
        resolvedRoot: "<remote-default:\(agent.rawValue)>",
        scanScope: "<remote-default:\(agent.rawValue)>/\(agent.scanDirectoryName)",
        exists: true,
        isDirectory: true,
        isDefault: true
      ))
    }
    sources += configured.map { value in
      let normalized = normalizeRemotePath(value)
      return MachineSessionSource(
        agent: agent,
        execution: .value(value),
        resolvedRoot: normalized,
        scanScope: "\(normalized)/\(agent.scanDirectoryName)",
        exists: true,
        isDirectory: true,
        isDefault: false
      )
    }
    return deduplicated(sources)
  }

  private static func deduplicated(_ sources: [MachineSessionSource]) -> [MachineSessionSource] {
    let ordered = sources.enumerated().sorted { lhs, rhs in
      let leftDepth = pathDepth(lhs.element.scanScope)
      let rightDepth = pathDepth(rhs.element.scanScope)
      return leftDepth == rightDepth ? lhs.offset < rhs.offset : leftDepth < rightDepth
    }
    var selected: [MachineSessionSource] = []
    for (_, source) in ordered {
      guard !selected.contains(where: { contains(scope: $0.scanScope, other: source.scanScope) }) else { continue }
      selected.append(source)
    }
    return selected
  }

  private static func contains(scope: String, other: String) -> Bool {
    scope == other || other.hasPrefix(scope.hasSuffix("/") ? scope : scope + "/")
  }

  private static func pathDepth(_ path: String) -> Int {
    path.split(separator: "/", omittingEmptySubsequences: true).count
  }

  private static func expandTilde(_ value: String, home: String) -> String {
    if value == "~" { return home }
    if value.hasPrefix("~/") { return home + String(value.dropFirst()) }
    return value
  }

  static func normalizeRemotePath(_ value: String) -> String {
    let prefix = value.hasPrefix("~/") ? "~/" : value.hasPrefix("/") ? "/" : ""
    var components: [String] = []
    for component in value.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".": continue
      case "..":
        if !components.isEmpty { components.removeLast() }
      default:
        components.append(String(component))
      }
    }
    if value == "~" { return "~" }
    return prefix + components.joined(separator: "/")
  }

  private static func makeFingerprint(
    descriptor: MachineDescriptor,
    codex: [MachineSessionSource],
    claude: [MachineSessionSource]
  ) -> String {
    let configured = [
      "session-source-v1",
      descriptor.includeDefaultCodexDir ? "1" : "0",
      descriptor.includeDefaultClaudeDir ? "1" : "0",
      descriptor.codexSessionDirs.joined(separator: "\u{1e}"),
      descriptor.claudeConfigDirs.joined(separator: "\u{1e}")
    ]
    let resolved = (codex + claude).map {
      [
        $0.agent.rawValue,
        $0.resolvedRoot,
        $0.scanScope,
        $0.exists ? "1" : "0",
        $0.isDirectory ? "1" : "0",
        $0.isDefault ? "1" : "0"
      ].joined(separator: "\u{1f}")
    }
    return (configured + resolved).joined(separator: "\u{1d}")
  }
}
