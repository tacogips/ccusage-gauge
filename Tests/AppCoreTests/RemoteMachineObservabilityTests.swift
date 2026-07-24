import Foundation
import Testing
@testable import AppCore

@Suite("RemoteMachineTransportTests")
struct RemoteMachineTransportTests {
  @Test func serializesJumpProxyAsOneCanonicalProxyCommand() throws {
    let connection = SSHConnection(
      host: "target.example",
      port: 2222,
      user: "target",
      proxy: .jump(SSHJumpProxy(
        host: "jump.example",
        port: 2200,
        user: "jumper",
        identityFile: "/tmp/jump-key",
        knownHostsFile: "/tmp/jump-known-hosts"
      ))
    )

    let arguments = try SSHCCUsageCommandRunner(connection: connection)
      .sshArguments(ccusageArguments: ["--version"])
    let proxyIndex = try #require(arguments.indices.first { index in
      arguments[index].hasPrefix("ProxyCommand=")
    })
    let proxy = arguments[proxyIndex]

    #expect(proxy.contains("'/usr/bin/ssh'"))
    #expect(proxy.contains("'jumper@jump.example'"))
    #expect(proxy.contains("'-W' '%h:%p'"))
    #expect(proxy.contains("'UserKnownHostsFile=/tmp/jump-known-hosts'"))
    #expect(arguments.suffix(4) == ["--", "target@target.example", "'ccusage'", "'--version'"])
  }

  @Test func commandProxyHasFixedArgumentsAndRejectsRelativeExecutable() throws {
    let connection = SSHConnection(
      host: "target.example",
      port: 22,
      user: "target",
      proxy: .command(executable: "/usr/local/bin/tunnel")
    )
    let arguments = try SSHCCUsageCommandRunner(connection: connection)
      .sshArguments(ccusageArguments: ["--version"])
    #expect(arguments.contains(
      "ProxyCommand='/usr/local/bin/tunnel' 'connect' '--host' 'target.example' '--port' '22'"
    ))
    #expect(throws: MachineValidationError.self) {
      try MachineValidation.validate(
        connection: SSHConnection(
          host: "target.example",
          port: 22,
          user: "target",
          proxy: .command(executable: "tunnel --unsafe")
        ),
        requireReadableIdentity: false
      )
    }
  }

  @Test func proxyPayloadRoundTripsWithoutProviderSpecificFields() throws {
    let descriptor = MachineDescriptor(
      id: "remote",
      displayName: "Remote",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(
        host: "target.example",
        port: 22,
        user: "target",
        proxy: .jump(SSHJumpProxy(host: "jump.example", user: "jump"))
      )
    )
    let data = try JSONEncoder().encode(descriptor)
    let text = String(decoding: data, as: UTF8.self)

    #expect(try JSONDecoder().decode(MachineDescriptor.self, from: data) == descriptor)
    #expect(text.contains(#""kind":"jump""#))
    #expect(!text.lowercased().contains("gce"))
    #expect(!text.lowercased().contains("iap"))
  }
}

@Suite("MachineDiagnosticClassifierTests")
struct MachineDiagnosticClassifierTests {
  @Test(arguments: [
    ("REMOTE HOST IDENTIFICATION HAS CHANGED", "host_key_verification_failed"),
    ("Permission denied (publickey)", "auth_failed"),
    ("proxy connect failed: connection refused", "tunnel_unreachable"),
    ("operation timed out", "timeout")
  ])
  func classifiesSanitizedTransportSignatures(stderr: String, expected: String) {
    let error = CCUsageCommandFailure(
      runnerKind: .ssh,
      phase: .transportExited,
      exitStatus: 255,
      stderr: stderr
    )
    let diagnostic = MachineDiagnosticClassifier.classify(error)

    #expect(diagnostic.code == expected)
    #expect(diagnostic.detail?.contains(stderr) == false)
    #expect(diagnostic.message.count < 100)
  }

  @Test func classifierNeverReturnsRawStderrOrUnsafeHostKeyAdvice() {
    let secret = "private-token-123"
    let error = CCUsageCommandFailure(
      runnerKind: .ssh,
      phase: .transportExited,
      exitStatus: 255,
      stderr: "unknown failure \(secret)"
    )
    let diagnostic = MachineDiagnosticClassifier.classify(error)
    let rendered = [diagnostic.message, diagnostic.detail, diagnostic.remediation].compactMap { $0 }.joined(separator: " ")

    #expect(!rendered.contains(secret))
    #expect(!rendered.lowercased().contains("stricthostkeychecking=no"))
    #expect(diagnostic.code == "transport_failed")
  }
}

@Suite("BootstrapLoggerTests")
struct BootstrapLoggerTests {
  @Test func activationIsSideEffectFreeUntilFirstRecord() throws {
    let directory = try temporaryLogDirectory().appendingPathComponent("logs", isDirectory: true)
    let logger = BootstrapLogger(primaryDirectory: directory, runtime: .serve)

    logger.activate()
    #expect(FileManager.default.fileExists(atPath: directory.path))
    #expect(!FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(BootstrapLogger.activeFileName).path
    ))

    logger.append(phase: "configuration", code: "configuration_invalid", message: "Configuration is invalid")
    let active = directory.appendingPathComponent(BootstrapLogger.activeFileName)
    let line = try #require(String(data: Data(contentsOf: active), encoding: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
    #expect(object["runtime"] == "serve")
    #expect(object["code"] == "configuration_invalid")
    #expect(!line.contains("\n\n"))
    #expect((try FileManager.default.attributesOfItem(atPath: active.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test func rotatesBeforeLimitAndPurgesOnlyExpiredRotatedLogs() throws {
    let root = try temporaryLogDirectory()
    let directory = root.appendingPathComponent("logs", isDirectory: true)
    let reference = Date(timeIntervalSince1970: 200_000)
    let logger = BootstrapLogger(
      primaryDirectory: directory,
      runtime: .menuBar,
      now: { reference },
      maximumFileBytes: 220,
      retentionSeconds: 100
    )
    logger.append(phase: "startup", code: "startup_failed", message: String(repeating: "x", count: 90))
    logger.append(phase: "startup", code: "startup_failed", message: String(repeating: "y", count: 90))

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.contains(BootstrapLogger.activeFileName))
    #expect(names.contains { $0.hasPrefix("ccusage-gauge-") && $0.hasSuffix(".jsonl") })

    let expired = directory.appendingPathComponent("ccusage-gauge-legacy-0.jsonl")
    try Data("{}\n".utf8).write(to: expired)
    try FileManager.default.setAttributes([
      .posixPermissions: 0o600,
      .modificationDate: reference.addingTimeInterval(-101)
    ], ofItemAtPath: expired.path)
    let retainedAtBoundary = directory.appendingPathComponent("ccusage-gauge-boundary-0.jsonl")
    try Data("{}\n".utf8).write(to: retainedAtBoundary)
    try FileManager.default.setAttributes([
      .posixPermissions: 0o600,
      .modificationDate: reference.addingTimeInterval(-100)
    ], ofItemAtPath: retainedAtBoundary.path)
    BootstrapLogger(
      primaryDirectory: directory,
      runtime: .menuBar,
      now: { reference },
      retentionSeconds: 100
    ).activate()
    #expect(!FileManager.default.fileExists(atPath: expired.path))
    #expect(FileManager.default.fileExists(atPath: retainedAtBoundary.path))
  }

  @Test func fallbackRecordsSanitizedPrimaryLocationWarning() throws {
    let root = try temporaryLogDirectory()
    let primary = root.appendingPathComponent("not-a-directory")
    let fallback = root.appendingPathComponent("fallback", isDirectory: true)
    try Data("occupied".utf8).write(to: primary)
    let logger = BootstrapLogger(
      primaryDirectory: primary,
      fallbackDirectory: fallback,
      runtime: .configCheck
    )

    logger.activate()

    let active = fallback.appendingPathComponent(BootstrapLogger.activeFileName)
    let line = try String(decoding: Data(contentsOf: active), as: UTF8.self)
    let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
    #expect(object["severity"] == "warning")
    #expect(object["code"] == "log_primary_unavailable")
    #expect(!line.contains(primary.path))
    #expect(!line.contains(fallback.path))
  }

  @Test func concurrentAppendsProduceCompleteJSONLines() throws {
    let directory = try temporaryLogDirectory().appendingPathComponent("logs", isDirectory: true)
    let logger = BootstrapLogger(primaryDirectory: directory, runtime: .client)
    DispatchQueue.concurrentPerform(iterations: 20) { index in
      logger.append(phase: "client", code: "request_failed", message: "Request \(index) failed")
    }
    let data = try Data(contentsOf: directory.appendingPathComponent(BootstrapLogger.activeFileName))
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")

    #expect(lines.count == 20)
    for line in lines {
      #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
    }
  }

  @Test func separateLoggerInstancesCoordinateAppends() throws {
    let directory = try temporaryLogDirectory().appendingPathComponent("logs", isDirectory: true)
    let first = BootstrapLogger(primaryDirectory: directory, runtime: .client)
    let second = BootstrapLogger(primaryDirectory: directory, runtime: .serve)
    DispatchQueue.concurrentPerform(iterations: 20) { index in
      let logger = index.isMultiple(of: 2) ? first : second
      logger.append(phase: "runtime", code: "request_failed", message: "Request failed")
    }

    let data = try Data(contentsOf: directory.appendingPathComponent(BootstrapLogger.activeFileName))
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    #expect(lines.count == 20)
    for line in lines {
      #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
    }
  }

  private func temporaryLogDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ccusage-bootstrap-logger-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
