import AppCore
import Foundation

/// Renders machine descriptors and machine-status responses as compact text.
/// The renderer only reports the identity-file path already returned by the
/// server; it never opens or reads identity-file contents.
enum MachineRenderer {
  static func list(_ response: MachinesResponse) -> String {
    guard !response.machines.isEmpty else { return "No machines registered." }
    return response.machines.map(descriptorLine).joined(separator: "\n")
  }

  static func show(_ descriptor: MachineDescriptor) -> String {
    detail(descriptor)
  }

  static func added(_ descriptor: MachineDescriptor) -> String {
    "Created machine \(descriptor.id)\n" + detail(descriptor)
  }

  static func status(_ response: MachineStatusResponse) -> String {
    var lines = ["requested: \(response.requested)"]
    for item in response.machines {
      var fields = [
        "\(item.id) [\(item.collectionState.rawValue)]",
        "\(item.displayName)",
        item.enabled ? "enabled" : "disabled",
        "snapshot=\(item.snapshotAvailable ? "yes" : "no")"
      ]
      if item.stale { fields.append("stale") }
      if item.collectionInProgress { fields.append("collecting") }
      if let coverage = item.coverageStart { fields.append("coverage=\(coverage)") }
      if let error = item.lastError { fields.append("error=\(error.code)") }
      lines.append(fields.joined(separator: "  "))
    }
    return lines.joined(separator: "\n")
  }

  static func loadStatus(_ response: MachineLoadStatusResponse) -> String {
    var lines = [
      "requested: \(response.requested)",
      "phase: \(response.phase.rawValue) (\(response.completed)/\(response.total)) loading=\(response.isLoading)"
    ]
    for item in response.machines {
      var fields = [
        "\(item.id) [\(item.phase.rawValue)]",
        "\(item.completed)/\(item.total)",
        "loading=\(item.isLoading)"
      ]
      if let coverage = item.coverageStart { fields.append("coverage=\(coverage)") }
      lines.append(fields.joined(separator: "  "))
    }
    return lines.joined(separator: "\n")
  }

  private static func descriptorLine(_ descriptor: MachineDescriptor) -> String {
    var fields = [
      descriptor.id,
      descriptor.displayName,
      descriptor.kind.rawValue,
      descriptor.enabled ? "enabled" : "disabled"
    ]
    if let ssh = descriptor.ssh {
      fields.append("\(ssh.user)@\(ssh.host):\(ssh.port)")
    } else {
      fields.append("-")
    }
    return fields.joined(separator: "  ")
  }

  private static func detail(_ descriptor: MachineDescriptor) -> String {
    var lines = [
      "id: \(descriptor.id)",
      "displayName: \(descriptor.displayName)",
      "kind: \(descriptor.kind.rawValue)",
      "enabled: \(descriptor.enabled)"
    ]
    if let ssh = descriptor.ssh {
      lines.append("ssh.host: \(ssh.host)")
      lines.append("ssh.port: \(ssh.port)")
      lines.append("ssh.user: \(ssh.user)")
      lines.append("ssh.identityFile: \(ssh.identityFile ?? "-")")
      lines.append("ssh.remoteCcusagePath: \(ssh.remoteCcusagePath)")
      lines.append("ssh.extraOptions: \(ssh.extraOptions.isEmpty ? "-" : ssh.extraOptions.joined(separator: " "))")
    }
    return lines.joined(separator: "\n")
  }
}
