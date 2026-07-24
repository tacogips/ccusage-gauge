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

public struct CCUsageProcessRunner: CCUsageProcessRunning, Sendable {
  public init() {}

  public func run(
    executable: URL,
    arguments: [String],
    timeoutSeconds: TimeInterval = 30
  ) async throws -> ProcessResult {
    try await Task.detached(priority: .utility) {
      let process = Process()
      let stdout = Pipe()
      let stderr = Pipe()
      process.executableURL = executable
      process.arguments = arguments
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
      while process.isRunning && Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
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
        throw ProcessExecutionFailure.timedOut
      }
      return ProcessResult(
        stdout: await outData,
        stderr: await errData,
        exitStatus: process.terminationStatus,
        terminationReason: process.terminationReason == .uncaughtSignal ? .uncaughtSignal : .exit
      )
    }.value
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

public struct RetryingCCUsageCommandRunner: CCUsageCommandRunner, Sendable {
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
    var remainingRetries = retryCount
    while true {
      try Task.checkCancellation()
      do {
        return try await runner.run(arguments: arguments, timeoutSeconds: timeoutSeconds)
      } catch {
        if error is CancellationError || remainingRetries == 0 { throw error }
        remainingRetries -= 1
      }
    }
  }
}

public struct LocalCCUsageCommandRunner: CCUsageCommandRunner, Sendable {
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

public struct SSHCCUsageCommandRunner: CCUsageCommandRunner, Sendable {
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
    let arguments = try sshArguments(ccusageArguments: arguments)
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

  public func sshArguments(ccusageArguments: [String]) throws -> [String] {
    try MachineValidation.validate(connection: connection, requireReadableIdentity: false)
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
    result += proxyArguments()
    result += ["--", MachineValidation.destination(connection)]
    result.append(Self.quoteRemoteToken(connection.remoteCcusagePath))
    result += ccusageArguments.map(Self.quoteRemoteToken)
    return result
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
