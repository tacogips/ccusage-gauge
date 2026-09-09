import Foundation
@testable import AppCore

struct StubCCUsageRunner: CCUsageCommandRunner {
  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    let payload: String
    switch arguments.first {
    case "blocks": payload = #"{"blocks":[]}"#
    case "daily": payload = #"{"daily":[]}"#
    case "session": payload = #"{"session":[]}"#
    case "--version": payload = "ccusage 1.0"
    default: throw CCUsageCommandFailure(runnerKind: .local, phase: .commandExited, exitStatus: 2)
    }
    return ProcessResult(stdout: Data(payload.utf8), stderr: Data(), exitStatus: 0)
  }
}

func machineTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
