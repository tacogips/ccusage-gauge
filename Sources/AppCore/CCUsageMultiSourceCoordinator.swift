import Foundation

public struct MultiSourceCCUsageCommandRunner: CCUsageCommandRunner, Sendable {
  private let runner: any CCUsageSourceCommandRunner
  private let planProvider: @Sendable () async throws -> MachineSessionSourcePlan

  public init(
    runner: any CCUsageSourceCommandRunner,
    planProvider: @escaping @Sendable () async throws -> MachineSessionSourcePlan
  ) {
    self.runner = runner
    self.planProvider = planProvider
  }

  public func run(
    arguments: [String],
    timeoutSeconds: TimeInterval
  ) async throws -> ProcessResult {
    let plan: MachineSessionSourcePlan
    if let attemptPlan = MachineSessionSourceAttempt.plan {
      plan = attemptPlan
    } else {
      plan = try await planProvider()
    }
    let sources = MachineSessionAgent.allCases.flatMap { plan.commandSources(for: $0) }
    guard !sources.isEmpty else {
      return ProcessResult(stdout: Self.emptyResponse(arguments: arguments), stderr: Data(), exitStatus: 0)
    }
    let runner = self.runner
    var outputs = [Data?](repeating: nil, count: sources.count)
    try await withThrowingTaskGroup(of: (Int, Data).self) { group in
      for (index, source) in sources.enumerated() {
        group.addTask {
          try Task.checkCancellation()
          let result = try await runner.run(
            arguments: arguments,
            source: source,
            timeoutSeconds: timeoutSeconds
          )
          return (index, result.stdout)
        }
      }
      for try await (index, stdout) in group {
        outputs[index] = stdout
      }
    }
    return ProcessResult(
      stdout: try Self.merge(outputs.compactMap { $0 }),
      stderr: Data(),
      exitStatus: 0
    )
  }

  private static func merge(_ outputs: [Data]) throws -> Data {
    var merged: [String: Any] = [:]
    for data in outputs {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CCUsageError.invalidJSON
      }
      for (key, value) in object {
        if let rows = value as? [Any] {
          merged[key] = (merged[key] as? [Any] ?? []) + rows
        } else if merged[key] == nil {
          merged[key] = value
        }
      }
    }
    return try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
  }

  private static func emptyResponse(arguments: [String]) -> Data {
    let value: String
    switch arguments.first {
    case "blocks":
      value = #"{"blocks":[]}"#
    case "session":
      value = #"{"session":[]}"#
    case "daily" where arguments.contains("--sections"):
      value = #"{"daily":[],"session":[]}"#
    case "daily":
      value = #"{"daily":[]}"#
    default:
      value = "{}"
    }
    return Data(value.utf8)
  }
}
