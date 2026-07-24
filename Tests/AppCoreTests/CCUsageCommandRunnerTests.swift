import Foundation
import Testing
@testable import AppCore

private struct StubProcessRunner: CCUsageProcessRunning {
  let result: Result<ProcessResult, ProcessExecutionFailure>

  func run(executable: URL, arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    try result.get()
  }
}

private actor SequencedCCUsageRunner: CCUsageCommandRunner {
  private var remainingFailures: Int
  private var observedTimeouts: [TimeInterval] = []

  init(failures: Int) {
    remainingFailures = failures
  }

  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    observedTimeouts.append(timeoutSeconds)
    if remainingFailures > 0 {
      remainingFailures -= 1
      throw CCUsageCommandFailure(runnerKind: .ssh, phase: .timedOut)
    }
    return ProcessResult(stdout: Data("ok".utf8), stderr: Data(), exitStatus: 0)
  }

  func observations() -> [TimeInterval] { observedTimeouts }
}

@Suite("SSHCommandRunnerTests") struct SSHCommandRunnerTests {
  @Test func processTimeoutForceKillsCommandsThatIgnoreTermination() async {
    let startedAt = Date()
    do {
      _ = try await CCUsageProcessRunner().run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
        timeoutSeconds: 0.1
      )
      Issue.record("Expected the process to time out")
    } catch let failure as ProcessExecutionFailure {
      #expect(failure == .timedOut)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(Date().timeIntervalSince(startedAt) < 2)
  }

  @Test func concurrentProcessPipeReadsDoNotStarveTimeouts() async {
    let startedAt = Date()
    let outcomes = await withTaskGroup(of: ProcessExecutionFailure?.self) { group in
      for _ in 0..<12 {
        group.addTask {
          do {
            _ = try await CCUsageProcessRunner().run(
              executable: URL(fileURLWithPath: "/bin/sh"),
              arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
              timeoutSeconds: 0.1
            )
            return nil
          } catch let failure as ProcessExecutionFailure {
            return failure
          } catch {
            return nil
          }
        }
      }
      var values: [ProcessExecutionFailure?] = []
      for await value in group { values.append(value) }
      return values
    }

    #expect(outcomes.count == 12)
    #expect(outcomes.allSatisfy { $0 == .timedOut })
    #expect(Date().timeIntervalSince(startedAt) < 3)
  }

  @Test func usesSystemSSHExecutable() throws {
    let runner = try SSHCCUsageCommandRunner(connection: SSHConnection(host: "localhost", port: 22, user: "user"))
    #expect(runner.sshExecutable.path == "/usr/bin/ssh")
  }

  @Test func emitsCanonicalArgumentsAndQuotesEveryRemoteToken() throws {
    let connection = SSHConnection(
      host: "2001:db8::1",
      port: 2222,
      user: "ccusage",
      identityFile: "/tmp/id_ed25519",
      extraOptions: ["-4", "-o ConnectTimeout=10", "-o LogLevel=ERROR"],
      remoteCcusagePath: "/usr/local/bin/ccusage"
    )
    let runner = try SSHCCUsageCommandRunner(connection: connection)
    #expect(try runner.sshArguments(ccusageArguments: ["blocks", "--json", "a'b"]) == [
      "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
      "-i", "/tmp/id_ed25519", "-p", "2222", "-4", "-o", "ConnectTimeout=10",
      "-o", "LogLevel=ERROR", "--", "ccusage@[2001:db8::1]",
      "'/usr/local/bin/ccusage'", "'blocks'", "'--json'", "'a'\\''b'"
    ])
  }

  @Test(arguments: [
    "-J bastion", "-o ProxyCommand=anything", "-o RemoteCommand=sh", "-p 22",
    "-o ConnectTimeout=0", "-o LogLevel=DEBUG", "-o UserKnownHostsFile=relative"
  ])
  func rejectsUnlistedOrAlternateOptions(option: String) {
    #expect(throws: MachineValidationError.self) {
      try SSHCCUsageCommandRunner(connection: SSHConnection(
        host: "localhost", port: 22, user: "user", extraOptions: [option]
      ))
    }
  }

  @Test(arguments: [
    (CCUsageRunnerKind.local, ProcessResult(stdout: Data(), stderr: Data(), exitStatus: 9), CCUsageCommandFailurePhase.commandExited),
    (CCUsageRunnerKind.local, ProcessResult(stdout: Data(), stderr: Data(), exitStatus: 9, terminationReason: .uncaughtSignal), .signalled),
    (CCUsageRunnerKind.ssh, ProcessResult(stdout: Data(), stderr: Data(), exitStatus: 255), .transportExited),
    (CCUsageRunnerKind.ssh, ProcessResult(stdout: Data(), stderr: Data(), exitStatus: 1), .commandExited),
    (CCUsageRunnerKind.ssh, ProcessResult(stdout: Data(), stderr: Data(), exitStatus: 254), .commandExited)
  ])
  func classifiesProcessOutcomes(kind: CCUsageRunnerKind, result: ProcessResult, phase: CCUsageCommandFailurePhase) async throws {
    let process = StubProcessRunner(result: .success(result))
    do {
      if kind == .local {
        _ = try await LocalCCUsageCommandRunner(executable: URL(fileURLWithPath: "/bin/false"), processRunner: process)
          .run(arguments: [], timeoutSeconds: 1)
      } else {
        _ = try await SSHCCUsageCommandRunner(
          connection: SSHConnection(host: "localhost", port: 22, user: "user"),
          processRunner: process
        ).run(arguments: ["daily", "--json"], timeoutSeconds: 1)
      }
      Issue.record("Expected command failure")
    } catch let failure as CCUsageCommandFailure {
      #expect(failure.phase == phase)
      #expect(failure.runnerKind == kind)
    }
  }

  @Test(arguments: [ProcessExecutionFailure.spawnFailed, .timedOut])
  func preservesLaunchAndTimeoutFailures(failure: ProcessExecutionFailure) async throws {
    let runner = LocalCCUsageCommandRunner(
      executable: URL(fileURLWithPath: "/bin/false"),
      processRunner: StubProcessRunner(result: .failure(failure))
    )
    do {
      _ = try await runner.run(arguments: [], timeoutSeconds: 1)
      Issue.record("Expected command failure")
    } catch let command as CCUsageCommandFailure {
      #expect(command.phase == (failure == .spawnFailed ? .spawnFailed : .timedOut))
    }
  }

  @Test func remoteRetryDefaultsUseThreeRetriesAndFifteenSecondAttempts() async throws {
    let underlying = SequencedCCUsageRunner(failures: 3)
    let runner = RetryingCCUsageCommandRunner(runner: underlying)

    _ = try await runner.run(arguments: ["daily"], timeoutSeconds: 30)

    #expect(runner.retryCount == 3)
    #expect(runner.timeoutSeconds == 15)
    #expect(await underlying.observations() == [15, 15, 15, 15])
  }

  @Test func remoteRetryStopsAfterConfiguredRetryCount() async {
    let underlying = SequencedCCUsageRunner(failures: 4)
    let runner = RetryingCCUsageCommandRunner(runner: underlying, retryCount: 3, timeoutSeconds: 15)

    await #expect(throws: CCUsageCommandFailure.self) {
      _ = try await runner.run(arguments: ["daily"], timeoutSeconds: 30)
    }
    #expect(await underlying.observations() == [15, 15, 15, 15])
  }
}
