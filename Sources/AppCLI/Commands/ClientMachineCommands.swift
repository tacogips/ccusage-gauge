import AppCore
import ArgumentParser

/// `ccusage-gauge client machines list`
struct MachinesListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List registered machines."
  )

  @OptionGroup var options: ClientOptions

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.machinesList()
      return RenderedResponse(raw: response.raw, text: MachineRenderer.list(response.value))
    }
  }
}

/// `ccusage-gauge client machines show <id>`
struct MachinesShowCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Show a single machine descriptor."
  )

  @Argument(help: "Canonical machine id, or 'local'.")
  var id: String

  @OptionGroup var options: ClientOptions

  func validate() throws {
    guard id == "local" || (id != "all" && MachineValidation.isCanonicalMachineID(id)) else {
      throw ValidationError("Invalid machine id: \(id)")
    }
  }

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.machineShow(id: id)
      return RenderedResponse(raw: response.raw, text: MachineRenderer.show(response.value))
    }
  }
}

/// `ccusage-gauge client machines add <id> --host <host> --user <user> ...`
struct MachinesAddCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Register a new SSH machine."
  )

  @Argument(help: "Canonical machine id.")
  var id: String

  @Option(name: .long, help: "SSH host (DNS name or IP literal).")
  var host: String

  @Option(name: .long, help: "SSH user.")
  var user: String

  @Option(name: .customLong("display-name"), help: "Human-readable name. Defaults to the id.")
  var displayName: String?

  @Option(name: .customLong("ssh-port"), help: "SSH port (1...65535). Defaults to 22.")
  var sshPort: Int = 22

  @Option(name: .customLong("identity-file"), help: "Absolute path to an identity file. The path is stored as a reference; its contents are never read.")
  var identityFile: String?

  @Option(name: .customLong("ssh-option"), help: "Additional SSH option. Repeatable. Values that begin with a dash must use --ssh-option=<value>.")
  var sshOptions: [String] = []

  @Option(name: .customLong("remote-ccusage-path"), help: "Remote ccusage executable. Defaults to ccusage.")
  var remoteCcusagePath: String = "ccusage"

  @Option(name: .customLong("proxy-jump-host"), help: "Structured SSH jump host.")
  var proxyJumpHost: String?

  @Option(name: .customLong("proxy-jump-user"), help: "Structured SSH jump user.")
  var proxyJumpUser: String?

  @Option(name: .customLong("proxy-jump-port"), help: "Structured SSH jump port. Defaults to 22.")
  var proxyJumpPort: Int = 22

  @Option(name: .customLong("proxy-jump-identity-file"), help: "Absolute jump-host identity-file reference.")
  var proxyJumpIdentityFile: String?

  @Option(name: .customLong("proxy-jump-known-hosts-file"), help: "Absolute jump-host known-hosts file.")
  var proxyJumpKnownHostsFile: String?

  @Option(name: .customLong("proxy-command-executable"), help: "Absolute executable implementing the fixed stdio adapter protocol.")
  var proxyCommandExecutable: String?

  @Flag(name: .long, help: "Register the machine in a disabled state.")
  var disabled = false

  @Option(name: .customLong("codex-session-dir"), help: "Additional Codex home directory. Repeatable.")
  var codexSessionDirs: [String] = []

  @Option(name: .customLong("claude-config-dir"), help: "Additional Claude configuration directory. Repeatable.")
  var claudeConfigDirs: [String] = []

  @Flag(name: .customLong("exclude-default-codex-dir"), help: "Do not include the default Codex home.")
  var excludeDefaultCodexDir = false

  @Flag(name: .customLong("exclude-default-claude-dir"), help: "Do not include the default Claude configuration directory.")
  var excludeDefaultClaudeDir = false

  @OptionGroup var options: ClientOptions

  func validate() throws {
    guard id != "local", id != "all", MachineValidation.isCanonicalMachineID(id) else {
      throw ValidationError("Invalid machine id: \(id)")
    }
    guard (1...65_535).contains(sshPort) else {
      throw ValidationError("Invalid ssh-port: \(sshPort)")
    }
    let hasJumpOption = proxyJumpHost != nil || proxyJumpUser != nil ||
      proxyJumpIdentityFile != nil || proxyJumpKnownHostsFile != nil || proxyJumpPort != 22
    guard !(hasJumpOption && proxyCommandExecutable != nil) else {
      throw ValidationError("Jump and command proxy options are mutually exclusive.")
    }
    if hasJumpOption {
      guard proxyJumpHost != nil, proxyJumpUser != nil, (1...65_535).contains(proxyJumpPort) else {
        throw ValidationError("Jump proxy requires host and user with a valid port.")
      }
    }
    try validateSessionPaths(codexSessionDirs + claudeConfigDirs)
  }

  func run() async throws {
    let proxy: SSHProxy?
    if let executable = proxyCommandExecutable {
      proxy = .command(executable: executable)
    } else if let host = proxyJumpHost, let user = proxyJumpUser {
      proxy = .jump(SSHJumpProxy(
        host: host,
        port: proxyJumpPort,
        user: user,
        identityFile: proxyJumpIdentityFile,
        knownHostsFile: proxyJumpKnownHostsFile
      ))
    } else {
      proxy = nil
    }
    let payload = MachineCreatePayload(
      id: id,
      displayName: displayName ?? id,
      enabled: !disabled,
      ssh: MachineCreatePayload.SSHPayload(
        host: host,
        port: sshPort,
        user: user,
        identityFile: identityFile,
        extraOptions: sshOptions,
        remoteCcusagePath: remoteCcusagePath,
        proxy: proxy
      ),
      codexSessionDirs: codexSessionDirs,
      claudeConfigDirs: claudeConfigDirs,
      includeDefaultCodexDir: !excludeDefaultCodexDir,
      includeDefaultClaudeDir: !excludeDefaultClaudeDir
    )
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.machineAdd(payload)
      return RenderedResponse(raw: response.raw, text: MachineRenderer.added(response.value))
    }
  }
}

/// `ccusage-gauge client machines update <id> ...`
struct MachinesUpdateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "update",
    abstract: "Update Codex and Claude session-source settings."
  )

  @Argument(help: "Canonical machine id, or 'local'.")
  var id: String

  @Option(name: .customLong("codex-session-dir"), help: "Replacement Codex home directory. Repeatable.")
  var codexSessionDirs: [String] = []

  @Flag(name: .customLong("clear-codex-session-dirs"), help: "Replace the Codex directory list with an empty list.")
  var clearCodexSessionDirs = false

  @Option(name: .customLong("claude-config-dir"), help: "Replacement Claude configuration directory. Repeatable.")
  var claudeConfigDirs: [String] = []

  @Flag(name: .customLong("clear-claude-config-dirs"), help: "Replace the Claude directory list with an empty list.")
  var clearClaudeConfigDirs = false

  @Flag(name: .customLong("include-default-codex-dir"), help: "Include the default Codex home.")
  var includeDefaultCodexDir = false

  @Flag(name: .customLong("exclude-default-codex-dir"), help: "Exclude the default Codex home.")
  var excludeDefaultCodexDir = false

  @Flag(name: .customLong("include-default-claude-dir"), help: "Include the default Claude configuration directory.")
  var includeDefaultClaudeDir = false

  @Flag(name: .customLong("exclude-default-claude-dir"), help: "Exclude the default Claude configuration directory.")
  var excludeDefaultClaudeDir = false

  @OptionGroup var options: ClientOptions

  func validate() throws {
    guard id == "local" || (id != "all" && MachineValidation.isCanonicalMachineID(id)) else {
      throw ValidationError("Invalid machine id: \(id)")
    }
    guard codexSessionDirs.isEmpty || !clearCodexSessionDirs else {
      throw ValidationError("--codex-session-dir and --clear-codex-session-dirs are mutually exclusive.")
    }
    guard claudeConfigDirs.isEmpty || !clearClaudeConfigDirs else {
      throw ValidationError("--claude-config-dir and --clear-claude-config-dirs are mutually exclusive.")
    }
    guard !(includeDefaultCodexDir && excludeDefaultCodexDir),
          !(includeDefaultClaudeDir && excludeDefaultClaudeDir) else {
      throw ValidationError("Include and exclude default flags are mutually exclusive.")
    }
    try validateSessionPaths(codexSessionDirs + claudeConfigDirs)
    guard clearCodexSessionDirs || clearClaudeConfigDirs
      || !codexSessionDirs.isEmpty || !claudeConfigDirs.isEmpty
      || includeDefaultCodexDir || excludeDefaultCodexDir
      || includeDefaultClaudeDir || excludeDefaultClaudeDir else {
      throw ValidationError("At least one session-source field is required.")
    }
  }

  func run() async throws {
    let codex = clearCodexSessionDirs ? [] : codexSessionDirs.isEmpty ? nil : codexSessionDirs
    let claude = clearClaudeConfigDirs ? [] : claudeConfigDirs.isEmpty ? nil : claudeConfigDirs
    let payload = MachineSourcePatchPayload(
      codexSessionDirs: codex,
      claudeConfigDirs: claude,
      includeDefaultCodexDir: includeDefaultCodexDir ? true : excludeDefaultCodexDir ? false : nil,
      includeDefaultClaudeDir: includeDefaultClaudeDir ? true : excludeDefaultClaudeDir ? false : nil
    )
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.machineUpdate(id: id, payload: payload)
      return RenderedResponse(raw: response.raw, text: MachineRenderer.updated(response.value))
    }
  }
}

/// `ccusage-gauge client machines test-connection <id>`
struct MachinesTestConnectionCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "test-connection",
    abstract: "Run the fixed ccusage version probe for a machine."
  )

  @Argument(help: "Canonical machine id, or 'local'.")
  var id: String

  @OptionGroup var options: ClientOptions

  func validate() throws {
    guard id == "local" || (id != "all" && MachineValidation.isCanonicalMachineID(id)) else {
      throw ValidationError("Invalid machine id: \(id)")
    }
  }

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.machineTestConnection(id: id)
      return RenderedResponse(
        raw: response.raw,
        text: MachineRenderer.connectionTest(response.value),
        failed: response.value.status == "failed"
      )
    }
  }
}

/// `ccusage-gauge client machines refresh <id>`
struct MachinesRefreshCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "refresh",
    abstract: "Reload the registry and refresh one enabled machine."
  )

  @Argument(help: "Canonical machine id, or 'local'.")
  var id: String

  @OptionGroup var options: ClientOptions

  func validate() throws {
    guard id == "local" || (id != "all" && MachineValidation.isCanonicalMachineID(id)) else {
      throw ValidationError("Invalid machine id: \(id)")
    }
  }

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.machineRefresh(id: id)
      return RenderedResponse(
        raw: response.raw,
        text: MachineRenderer.refresh(response.value),
        failed: response.value.status == "failed"
      )
    }
  }
}

private func validateSessionPaths(_ paths: [String]) throws {
  if let invalid = paths.first(where: { !MachineValidation.isValidSessionSourcePath($0) }) {
    throw ValidationError("Invalid session-source path: \(invalid)")
  }
}
