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
  }

  func run() async throws {
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
        remoteCcusagePath: remoteCcusagePath
      )
    )
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.machineAdd(payload)
      return RenderedResponse(raw: response.raw, text: MachineRenderer.added(response.value))
    }
  }
}
