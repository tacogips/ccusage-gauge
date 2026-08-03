import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum CCUsageRunnerKind: String, Sendable {
  case local
  case ssh
}

public enum CCUsageCommandFailurePhase: String, Sendable {
  case spawnFailed
  case timedOut
  case signalled
  case transportExited
  case commandExited
}

public struct CCUsageCommandFailure: Error, Equatable, Sendable {
  public let runnerKind: CCUsageRunnerKind
  public let phase: CCUsageCommandFailurePhase
  public let exitStatus: Int32?
  public let stderr: String

  public init(
    runnerKind: CCUsageRunnerKind,
    phase: CCUsageCommandFailurePhase,
    exitStatus: Int32? = nil,
    stderr: String = ""
  ) {
    self.runnerKind = runnerKind
    self.phase = phase
    self.exitStatus = exitStatus
    self.stderr = String(stderr.prefix(4_096))
  }
}

public enum ProcessTerminationReason: Equatable, Sendable {
  case exit
  case uncaughtSignal
}

public struct ProcessResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let exitStatus: Int32
  public let terminationReason: ProcessTerminationReason

  public init(
    stdout: Data,
    stderr: Data,
    exitStatus: Int32,
    terminationReason: ProcessTerminationReason = .exit
  ) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitStatus = exitStatus
    self.terminationReason = terminationReason
  }
}

public enum ProcessExecutionFailure: Error, Equatable, Sendable {
  case spawnFailed
  case timedOut
}

public protocol CCUsageProcessRunning: Sendable {
  func run(executable: URL, arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult
}

public protocol CCUsageEnvironmentProcessRunning: CCUsageProcessRunning {
  func run(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    timeoutSeconds: TimeInterval
  ) async throws -> ProcessResult
}

public struct CCUsageProcessRunner: CCUsageEnvironmentProcessRunning, Sendable {
  public init() {}

  public func run(
    executable: URL,
    arguments: [String],
    timeoutSeconds: TimeInterval = 30
  ) async throws -> ProcessResult {
    try await runProcess(executable: executable, arguments: arguments, environment: nil, timeoutSeconds: timeoutSeconds)
  }

  public func run(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    timeoutSeconds: TimeInterval
  ) async throws -> ProcessResult {
    try await runProcess(executable: executable, arguments: arguments, environment: environment, timeoutSeconds: timeoutSeconds)
  }

  private func runProcess(
    executable: URL,
    arguments: [String],
    environment: [String: String]?,
    timeoutSeconds: TimeInterval
  ) async throws -> ProcessResult {
    let worker = Task.detached(priority: .utility) {
      let process = Process()
      let stdout = Pipe()
      let stderr = Pipe()
      process.executableURL = executable
      process.arguments = arguments
      process.environment = environment
      process.standardOutput = stdout
      process.standardError = stderr
      do { try process.run() } catch { throw ProcessExecutionFailure.spawnFailed }
      let processID = process.processIdentifier
      let ownsProcessGroup = setpgid(processID, processID) == 0

      let outHandle = stdout.fileHandleForReading
      let errHandle = stderr.fileHandleForReading
      async let outData = readPipe(outHandle)
      async let errData = readPipe(errHandle)

      let deadline = Date().addingTimeInterval(timeoutSeconds)
      while process.isRunning && !Task.isCancelled && Date() < deadline {
        // Cancellation must flow through the termination path below. Letting
        // sleep throw here abandons a live subprocess, and the pipe readers
        // then keep the cancelled task (and registry deletion) suspended.
        try? await Task.sleep(for: .milliseconds(20))
      }
      let wasCancelled = Task.isCancelled
      if process.isRunning {
        signalProcess(processID, signal: SIGTERM, processGroup: ownsProcessGroup)
        let terminationDeadline = Date().addingTimeInterval(0.25)
        while process.isRunning && Date() < terminationDeadline {
          try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
          signalProcess(processID, signal: SIGKILL, processGroup: ownsProcessGroup)
        }
        process.waitUntilExit()
        _ = await outData
        _ = await errData
        if wasCancelled { throw CancellationError() }
        throw ProcessExecutionFailure.timedOut
      }
      if wasCancelled { throw CancellationError() }
      return ProcessResult(
        stdout: await outData,
        stderr: await errData,
        exitStatus: process.terminationStatus,
        terminationReason: process.terminationReason == .uncaughtSignal ? .uncaughtSignal : .exit
      )
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  private func readPipe(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: handle.readDataToEndOfFile())
      }
    }
  }

  private func signalProcess(
    _ processID: Int32,
    signal: Int32,
    processGroup: Bool
  ) {
    if processGroup {
      _ = kill(-processID, signal)
    }
    _ = kill(processID, signal)
  }
}

public protocol CCUsageCommandRunner: Sendable {
  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult
}

public protocol CCUsageSourceCommandRunner: CCUsageCommandRunner {
  func run(
    arguments: [String],
    source: MachineSessionSource,
    timeoutSeconds: TimeInterval
  ) async throws -> ProcessResult
}

public protocol MachineSessionSourcePlanResolving: Sendable {
  func resolveSessionSourcePlan(
    descriptor: MachineDescriptor,
    timeoutSeconds: TimeInterval
  ) async throws -> MachineSessionSourcePlan
}

public struct RetryingCCUsageCommandRunner:
  CCUsageSourceCommandRunner,
  MachineSessionSourcePlanResolving,
  Sendable {
  private let runner: any CCUsageCommandRunner
  public let retryCount: Int
  public let timeoutSeconds: TimeInterval

  public init(
    runner: any CCUsageCommandRunner,
    retryCount: Int = AppConfiguration.defaultRemoteRetryCount,
    timeoutSeconds: TimeInterval = TimeInterval(AppConfiguration.defaultRemoteTimeoutSeconds)
  ) {
    self.runner = runner
    self.retryCount = max(0, retryCount)
    self.timeoutSeconds = max(1, timeoutSeconds)
  }

  public func run(arguments: [String], timeoutSeconds _: TimeInterval) async throws -> ProcessResult {
    try await retry {
      try await runner.run(arguments: arguments, timeoutSeconds: timeoutSeconds)
    }
  }

  public func run(
    arguments: [String],
    source: MachineSessionSource,
    timeoutSeconds _: TimeInterval
  ) async throws -> ProcessResult {
    guard let sourceRunner = runner as? any CCUsageSourceCommandRunner else {
      // A sourceless fallback would run against default dirs once per plan
      // source and multiply merged usage; fail loudly instead.
      throw CCUsageCommandFailure(runnerKind: .ssh, phase: .spawnFailed)
    }
    return try await retry {
      try await sourceRunner.run(arguments: arguments, source: source, timeoutSeconds: timeoutSeconds)
    }
  }

  public func resolveSessionSourcePlan(
    descriptor: MachineDescriptor,
    timeoutSeconds _: TimeInterval
  ) async throws -> MachineSessionSourcePlan {
    guard let resolver = runner as? any MachineSessionSourcePlanResolving else {
      throw CCUsageCommandFailure(runnerKind: .ssh, phase: .spawnFailed)
    }
    var remainingRetries = retryCount
    while true {
      try Task.checkCancellation()
      do {
        return try await resolver.resolveSessionSourcePlan(
          descriptor: descriptor,
          timeoutSeconds: timeoutSeconds
        )
      } catch {
        if error is CancellationError || remainingRetries == 0 { throw error }
        remainingRetries -= 1
      }
    }
  }

  private func retry(
    operation: @escaping @Sendable () async throws -> ProcessResult
  ) async throws -> ProcessResult {
    var remainingRetries = retryCount
    while true {
      try Task.checkCancellation()
      do {
        return try await operation()
      } catch {
        if error is CancellationError || remainingRetries == 0 { throw error }
        remainingRetries -= 1
      }
    }
  }
}

public struct LocalCCUsageCommandRunner: CCUsageSourceCommandRunner, Sendable {
  public let executable: URL
  private let processRunner: any CCUsageProcessRunning

  public init(executable: URL, processRunner: any CCUsageProcessRunning = CCUsageProcessRunner()) {
    self.executable = executable
    self.processRunner = processRunner
  }

  public func run(arguments: [String], timeoutSeconds: TimeInterval = 30) async throws -> ProcessResult {
    do {
      let result = try await processRunner.run(
        executable: executable,
        arguments: arguments,
        timeoutSeconds: timeoutSeconds
      )
      try classify(result)
      return result
    } catch ProcessExecutionFailure.spawnFailed {
      throw CCUsageCommandFailure(runnerKind: .local, phase: .spawnFailed)
    } catch ProcessExecutionFailure.timedOut {
      throw CCUsageCommandFailure(runnerKind: .local, phase: .timedOut)
    }
  }

  private static func disabledAgentRoot(_ agent: MachineSessionAgent) -> String {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ccusage-gauge-disabled-\(agent.rawValue)", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: root.appendingPathComponent(agent.scanDirectoryName, isDirectory: true),
      withIntermediateDirectories: true
    )
    return root.path
  }

  public func run(
    arguments: [String],
    source: MachineSessionSource,
    timeoutSeconds: TimeInterval = 30
  ) async throws -> ProcessResult {
    guard case .value(let value) = source.execution,
          let environmentRunner = processRunner as? any CCUsageEnvironmentProcessRunning else {
      throw CCUsageCommandFailure(runnerKind: .local, phase: .spawnFailed)
    }
    var environment = ProcessInfo.processInfo.environment
    // ccusage hard-errors on a nonexistent agent dir, so the agent not covered
    // by this source is pointed at an empty directory with the expected
    // structure, which yields empty data instead of a CLI error.
    environment["CODEX_HOME"] = source.agent == .codex ? value : Self.disabledAgentRoot(.codex)
    environment["CLAUDE_CONFIG_DIR"] = source.agent == .claude ? value : Self.disabledAgentRoot(.claude)
    do {
      let result = try await environmentRunner.run(
        executable: executable,
        arguments: arguments,
        environment: environment,
        timeoutSeconds: timeoutSeconds
      )
      try classify(result)
      return result
    } catch ProcessExecutionFailure.spawnFailed {
      throw CCUsageCommandFailure(runnerKind: .local, phase: .spawnFailed)
    } catch ProcessExecutionFailure.timedOut {
      throw CCUsageCommandFailure(runnerKind: .local, phase: .timedOut)
    }
  }

  private func classify(_ result: ProcessResult) throws {
    let stderr = String(decoding: result.stderr, as: UTF8.self)
    if result.terminationReason == .uncaughtSignal {
      throw CCUsageCommandFailure(
        runnerKind: .local,
        phase: .signalled,
        exitStatus: result.exitStatus,
        stderr: stderr
      )
    }
    if result.exitStatus != 0 {
      throw CCUsageCommandFailure(
        runnerKind: .local,
        phase: .commandExited,
        exitStatus: result.exitStatus,
        stderr: stderr
      )
    }
  }
}

public struct SSHCCUsageCommandRunner:
  CCUsageSourceCommandRunner,
  MachineSessionSourcePlanResolving,
  Sendable {
  public let connection: SSHConnection
  public let sshExecutable: URL
  private let processRunner: any CCUsageProcessRunning

  public init(
    connection: SSHConnection,
    sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
    processRunner: any CCUsageProcessRunning = CCUsageProcessRunner()
  ) throws {
    try MachineValidation.validate(connection: connection, requireReadableIdentity: false)
    self.connection = connection
    self.sshExecutable = sshExecutable
    self.processRunner = processRunner
  }

  public func run(arguments: [String], timeoutSeconds: TimeInterval = 30) async throws -> ProcessResult {
    try MachineValidation.validate(connection: connection, requireReadableIdentity: true)
    let arguments = try sshArguments(ccusageArguments: arguments, timeoutSeconds: timeoutSeconds)
    do {
      let result = try await processRunner.run(
        executable: sshExecutable,
        arguments: arguments,
        timeoutSeconds: timeoutSeconds
      )
      try classify(result)
      return result
    } catch ProcessExecutionFailure.spawnFailed {
      throw CCUsageCommandFailure(runnerKind: .ssh, phase: .spawnFailed)
    } catch ProcessExecutionFailure.timedOut {
      throw CCUsageCommandFailure(runnerKind: .ssh, phase: .timedOut)
    }
  }

  public func run(
    arguments: [String],
    source: MachineSessionSource,
    timeoutSeconds: TimeInterval = 30
  ) async throws -> ProcessResult {
    try MachineValidation.validate(connection: connection, requireReadableIdentity: true)
    let arguments = try sourceSSHArguments(
      ccusageArguments: arguments,
      source: source,
      timeoutSeconds: timeoutSeconds
    )
    do {
      let result = try await processRunner.run(
        executable: sshExecutable,
        arguments: arguments,
        timeoutSeconds: timeoutSeconds
      )
      try classify(result)
      return result
    } catch ProcessExecutionFailure.spawnFailed {
      throw CCUsageCommandFailure(runnerKind: .ssh, phase: .spawnFailed)
    } catch ProcessExecutionFailure.timedOut {
      throw CCUsageCommandFailure(runnerKind: .ssh, phase: .timedOut)
    }
  }

  public func resolveSessionSourcePlan(
    descriptor: MachineDescriptor,
    timeoutSeconds: TimeInterval = 30
  ) async throws -> MachineSessionSourcePlan {
    try MachineValidation.validate(descriptor: descriptor)
    guard descriptor.kind == .ssh, descriptor.ssh == connection else {
      throw MachineValidationError(fieldErrors: ["ssh": "must match the source-plan connection"])
    }
    let hasConfiguredSources = !descriptor.codexSessionDirs.isEmpty || !descriptor.claudeConfigDirs.isEmpty
    guard descriptor.includeDefaultCodexDir || descriptor.includeDefaultClaudeDir || hasConfiguredSources else {
      return MachineSessionSourcePlan(descriptor: descriptor, remote: true)
    }
    try MachineValidation.validate(connection: connection, requireReadableIdentity: true)
    let arguments = sourceProbeSSHArguments(descriptor: descriptor, timeoutSeconds: timeoutSeconds)
    do {
      let result = try await processRunner.run(
        executable: sshExecutable,
        arguments: arguments,
        timeoutSeconds: timeoutSeconds
      )
      try classify(result)
      return try Self.decodeSourceProbe(result.stdout, descriptor: descriptor)
    } catch ProcessExecutionFailure.spawnFailed {
      throw CCUsageCommandFailure(runnerKind: .ssh, phase: .spawnFailed)
    } catch ProcessExecutionFailure.timedOut {
      throw CCUsageCommandFailure(runnerKind: .ssh, phase: .timedOut)
    }
  }

  public func sshArguments(
    ccusageArguments: [String],
    timeoutSeconds: TimeInterval = TimeInterval(AppConfiguration.defaultRemoteTimeoutSeconds)
  ) throws -> [String] {
    try MachineValidation.validate(connection: connection, requireReadableIdentity: false)
    var result = transportArguments(timeoutSeconds: timeoutSeconds)
    result += ["--", MachineValidation.destination(connection)]
    result.append(Self.quoteRemoteToken(connection.remoteCcusagePath))
    result += ccusageArguments.map(Self.quoteRemoteToken)
    return result
  }

  public func sourceSSHArguments(
    ccusageArguments: [String],
    source: MachineSessionSource,
    timeoutSeconds: TimeInterval = TimeInterval(AppConfiguration.defaultRemoteTimeoutSeconds)
  ) throws -> [String] {
    try MachineValidation.validate(connection: connection, requireReadableIdentity: false)
    var result = transportArguments(timeoutSeconds: timeoutSeconds)
    result += ["--", MachineValidation.destination(connection)]
    let sourceKind: String
    let sourceValue: String
    switch source.execution {
    case .remoteDefault:
      sourceKind = "default"
      sourceValue = ""
    case .value(let value):
      sourceKind = source.isDefault ? "captured-default" : "explicit"
      sourceValue = value
    }
    let remoteTokens = [
      "sh",
      "-c",
      Self.sourceAdapter,
      "ccusage-gauge-source",
      source.agent.rawValue,
      sourceKind,
      sourceValue,
      connection.remoteCcusagePath
    ] + ccusageArguments
    result += remoteTokens.map(Self.quoteRemoteToken)
    return result
  }

  private func sourceProbeSSHArguments(
    descriptor: MachineDescriptor,
    timeoutSeconds: TimeInterval
  ) -> [String] {
    var result = transportArguments(timeoutSeconds: timeoutSeconds)
    result += ["--", MachineValidation.destination(connection)]
    let remoteTokens = [
      "sh",
      "-c",
      Self.sourceProbeAdapter,
      "ccusage-gauge-source-probe",
      descriptor.includeDefaultCodexDir ? "1" : "0",
      descriptor.includeDefaultClaudeDir ? "1" : "0",
      String(descriptor.codexSessionDirs.count),
      String(descriptor.claudeConfigDirs.count)
    ] + descriptor.codexSessionDirs + descriptor.claudeConfigDirs
    result += remoteTokens.map(Self.quoteRemoteToken)
    return result
  }

  private func transportArguments(timeoutSeconds: TimeInterval) -> [String] {
    var result = ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes"]
    if let identityFile = connection.identityFile {
      result += ["-i", identityFile]
    }
    result += ["-p", String(connection.port)]
    for option in connection.extraOptions {
      if option == "-4" || option == "-6" {
        result.append(option)
      } else {
        result += ["-o", String(option.dropFirst(3))]
      }
    }
    if !connection.extraOptions.contains(where: { $0.hasPrefix("-o ConnectTimeout=") }) {
      let connectTimeout = max(1, min(600, Int(ceil(timeoutSeconds))))
      result += ["-o", "ConnectTimeout=\(connectTimeout)"]
    }
    result += proxyArguments()
    return result
  }

  private static let sourceAdapter = """
    agent=$1
    source_kind=$2
    source_value=$3
    executable=$4
    shift 4
    if [ "$source_kind" = default ]; then
      if [ "$agent" = codex ]; then
        source_value=${CODEX_HOME-"$HOME/.codex"}
      else
        source_value=${CLAUDE_CONFIG_DIR-"$HOME/.claude"}
      fi
    elif [ "$source_kind" = captured-default ]; then
      :
    elif [ "$source_value" = "~" ]; then
      source_value=$HOME
    elif [ "${source_value#~/}" != "$source_value" ]; then
      source_value=$HOME/${source_value#~/}
    fi
    if [ "$agent" = codex ]; then
      scan=$source_value/sessions
    else
      scan=$source_value/projects
    fi
    if [ ! -d "$scan" ]; then
      case "$1" in
        blocks) printf '{"blocks":[]}' ;;
        session) printf '{"session":[]}' ;;
        daily)
          case " $* " in
            *" --sections "*) printf '{"daily":[],"session":[]}' ;;
            *) printf '{"daily":[]}' ;;
          esac
          ;;
        *) printf '{}' ;;
      esac
      exit 0
    fi
    disabled_root=${TMPDIR:-/tmp}/ccusage-gauge-disabled
    mkdir -p "$disabled_root/codex/sessions" "$disabled_root/claude/projects"
    if [ "$agent" = codex ]; then
      CODEX_HOME=$source_value CLAUDE_CONFIG_DIR=$disabled_root/claude "$executable" "$@"
    else
      CODEX_HOME=$disabled_root/codex CLAUDE_CONFIG_DIR=$source_value "$executable" "$@"
    fi
    """

  private static let sourceProbeAdapter = """
    include_codex=$1
    include_claude=$2
    codex_count=$3
    claude_count=$4
    shift 4
    probe_base=$(pwd -P)

    emit_source() {
      printf '%s\\0%s\\0%s\\0%s\\0%s\\0%s\\0%s\\0' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
    }

    probe_source() {
      agent=$1
      is_default=$2
      source_value=$3
      if [ "$is_default" = 0 ]; then
        if [ "$source_value" = "~" ]; then
          source_value=$HOME
        elif [ "${source_value#~/}" != "$source_value" ]; then
          source_value=$HOME/${source_value#~/}
        fi
      fi
      if [ "$agent" = codex ]; then
        scan_name=sessions
      else
        scan_name=projects
      fi
      resolved_root=$source_value
      root_for_cd=$source_value
      case "$root_for_cd" in
        /*) ;;
        *) root_for_cd=./$root_for_cd ;;
      esac
      if [ -d "$root_for_cd" ]; then
        resolved_root=$(cd -P "$root_for_cd" && pwd -P)
      else
        case "$resolved_root" in
          /*) ;;
          *) resolved_root=$probe_base/$resolved_root ;;
        esac
      fi
      scan=$resolved_root/$scan_name
      scan_for_cd=$scan
      case "$scan_for_cd" in
        /*) ;;
        *) scan_for_cd=./$scan_for_cd ;;
      esac
      if [ -d "$scan_for_cd" ]; then
        resolved_scan=$(cd -P "$scan_for_cd" && pwd -P)
        emit_source "$agent" "$is_default" "$source_value" "$resolved_root" "$resolved_scan" 1 1
      elif [ -e "$scan_for_cd" ] || [ -L "$scan_for_cd" ]; then
        emit_source "$agent" "$is_default" "$source_value" "$resolved_root" "$scan" 1 0
      else
        emit_source "$agent" "$is_default" "$source_value" "$resolved_root" "$scan" 0 0
      fi
    }

    if [ "$include_codex" = 1 ]; then
      probe_source codex 1 "${CODEX_HOME-"$HOME/.codex"}"
    fi
    codex_index=0
    while [ "$codex_index" -lt "$codex_count" ]; do
      probe_source codex 0 "$1"
      shift
      codex_index=$((codex_index + 1))
    done
    if [ "$include_claude" = 1 ]; then
      probe_source claude 1 "${CLAUDE_CONFIG_DIR-"$HOME/.claude"}"
    fi
    claude_index=0
    while [ "$claude_index" -lt "$claude_count" ]; do
      probe_source claude 0 "$1"
      shift
      claude_index=$((claude_index + 1))
    done
    """

  private static func decodeSourceProbe(
    _ data: Data,
    descriptor: MachineDescriptor
  ) throws -> MachineSessionSourcePlan {
    var fields = data.split(separator: 0, omittingEmptySubsequences: false)
    if fields.last?.isEmpty == true { fields.removeLast() }
    guard fields.count.isMultiple(of: 7) else { throw CCUsageError.invalidJSON }
    var codex: [MachineSessionSource] = []
    var claude: [MachineSessionSource] = []
    for index in stride(from: 0, to: fields.count, by: 7) {
      guard let agentText = probeString(fields[index]),
            let executionValue = probeString(fields[index + 2]),
            let resolvedRoot = probeString(fields[index + 3]),
            let scanScope = probeString(fields[index + 4]),
            let agent = MachineSessionAgent(rawValue: agentText),
            let isDefault = Self.probeBoolean(fields[index + 1]),
            let exists = Self.probeBoolean(fields[index + 5]),
            let isDirectory = Self.probeBoolean(fields[index + 6]) else {
        throw CCUsageError.invalidJSON
      }
      let source = MachineSessionSource(
        agent: agent,
        execution: .value(executionValue),
        resolvedRoot: MachineSessionSourcePlan.normalizeRemotePath(resolvedRoot),
        scanScope: MachineSessionSourcePlan.normalizeRemotePath(scanScope),
        exists: exists,
        isDirectory: isDirectory,
        isDefault: isDefault
      )
      switch agent {
      case .codex: codex.append(source)
      case .claude: claude.append(source)
      }
    }
    let expectedCodex = descriptor.codexSessionDirs.count + (descriptor.includeDefaultCodexDir ? 1 : 0)
    let expectedClaude = descriptor.claudeConfigDirs.count + (descriptor.includeDefaultClaudeDir ? 1 : 0)
    guard codex.count == expectedCodex, claude.count == expectedClaude else {
      throw CCUsageError.invalidJSON
    }
    return MachineSessionSourcePlan(descriptor: descriptor, codex: codex, claude: claude)
  }

  private static func probeBoolean(_ data: Data.SubSequence) -> Bool? {
    switch probeString(data) {
    case "0": false
    case "1": true
    default: nil
    }
  }

  private static func probeString(_ data: Data.SubSequence) -> String? {
    String(data: Data(data), encoding: .utf8)
  }

  private func proxyArguments() -> [String] {
    guard let proxy = connection.proxy else { return [] }
    switch proxy {
    case .direct:
      return []
    case .jump(let jump):
      var tokens = [
        "/usr/bin/ssh", "-F", "/dev/null",
        "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes"
      ]
      if let identityFile = jump.identityFile {
        tokens += ["-i", identityFile]
      }
      if let knownHostsFile = jump.knownHostsFile {
        tokens += ["-o", "UserKnownHostsFile=\(knownHostsFile)"]
      }
      tokens += [
        "-o", "StrictHostKeyChecking=yes",
        "-p", String(jump.port),
        "-W", "%h:%p",
        MachineValidation.destination(SSHConnection(
          host: jump.host,
          port: jump.port,
          user: jump.user
        ))
      ]
      return ["-o", "ProxyCommand=\(tokens.map(Self.quoteRemoteToken).joined(separator: " "))"]
    case .command(let executable):
      let tokens = [
        executable,
        "connect",
        "--host", connection.host,
        "--port", String(connection.port)
      ]
      return ["-o", "ProxyCommand=\(tokens.map(Self.quoteRemoteToken).joined(separator: " "))"]
    }
  }

  public static func quoteRemoteToken(_ token: String) -> String {
    "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func classify(_ result: ProcessResult) throws {
    let stderr = String(decoding: result.stderr, as: UTF8.self)
    if result.terminationReason == .uncaughtSignal {
      throw CCUsageCommandFailure(
        runnerKind: .ssh,
        phase: .signalled,
        exitStatus: result.exitStatus,
        stderr: stderr
      )
    }
    guard result.exitStatus != 0 else { return }
    throw CCUsageCommandFailure(
      runnerKind: .ssh,
      phase: result.exitStatus == 255 ? .transportExited : .commandExited,
      exitStatus: result.exitStatus,
      stderr: stderr
    )
  }
}
