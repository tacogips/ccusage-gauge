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
      )
    )
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.machineAdd(payload)
      return RenderedResponse(raw: response.raw, text: MachineRenderer.added(response.value))
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
