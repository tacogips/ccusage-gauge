import Foundation

public enum MachineDiagnosticClassifier {
  private static let hostKeySignatures = [
    "host key verification failed",
    "remote host identification has changed",
    "offending ecdsa key in",
    "offending ed25519 key in",
    "offending rsa key in",
    "no host key is known for"
  ]

  private static let authenticationSignatures = [
    "permission denied",
    "authentication failed",
    "no supported authentication methods available",
    "too many authentication failures",
    "sign_and_send_pubkey: signing failed"
  ]

  private static let reachabilitySignatures = [
    "connection refused",
    "no route to host",
    "could not resolve hostname",
    "name or service not known",
    "connection reset by peer",
    "connection closed by",
    "kex_exchange_identification",
    "stdio forwarding failed"
  ]

  private static let timeoutSignatures = [
    "connection timed out",
    "operation timed out"
  ]

  public static func classify(_ error: Error) -> SanitizedCollectionError {
    if let ccusage = error as? CCUsageError {
      switch ccusage {
      case .commandFailed(let failure):
        return classify(failure)
      case .invalidJSON:
        return diagnostic(for: "invalid_response")
      case .executableMissing, .invalidConfiguredPath:
        return diagnostic(for: "executable_unavailable")
      default:
        break
      }
    }
    if let failure = error as? CCUsageCommandFailure {
      return classify(failure)
    }
    if error is AggregationCacheError || error is CacheLifecycleError {
      return diagnostic(for: "cache_failed")
    }
    return diagnostic(for: "internal_error")
  }

  public static func classify(_ failure: CCUsageCommandFailure) -> SanitizedCollectionError {
    switch failure.phase {
    case .timedOut:
      return diagnostic(for: "timeout")
    case .commandExited:
      return diagnostic(for: "remote_command_failed")
    case .transportExited where failure.runnerKind == .ssh:
      let normalized = normalizedStderr(failure.stderr)
      if hostKeySignatures.contains(where: normalized.contains) {
        return diagnostic(for: "host_key_verification_failed")
      }
      if authenticationSignatures.contains(where: normalized.contains) {
        return diagnostic(for: "auth_failed")
      }
      if timeoutSignatures.contains(where: normalized.contains) {
        return diagnostic(for: "timeout")
      }
      if reachabilitySignatures.contains(where: normalized.contains) {
        return diagnostic(for: "tunnel_unreachable")
      }
      return diagnostic(for: "transport_failed")
    case .spawnFailed, .signalled, .transportExited:
      return diagnostic(for: "transport_failed")
    }
  }

  public static func diagnostic(for code: String) -> SanitizedCollectionError {
    let values: (String, String, String)
    switch code {
    case "host_key_verification_failed":
      values = (
        "SSH host-key verification failed",
        "The SSH server identity could not be verified.",
        "Verify the server fingerprint with the machine administrator, then update the configured known-hosts file."
      )
    case "auth_failed":
      values = (
        "SSH authentication failed",
        "The SSH server rejected the configured credentials.",
        "Verify the configured user, identity-file reference and permissions, and server-side authorization."
      )
    case "tunnel_unreachable":
      values = (
        "SSH tunnel is unreachable",
        "The configured SSH endpoint did not accept a connection.",
        "Verify that the configured proxy or tunnel is running and that its host and port match the active endpoint."
      )
    case "timeout":
      values = (
        "Connection timed out",
        "The command did not complete before the configured timeout.",
        "Verify endpoint responsiveness and the configured connection timeout, then retry."
      )
    case "remote_command_failed":
      values = (
        "ccusage command failed",
        "The configured ccusage executable rejected the requested operation.",
        "Verify the remote ccusage installation and supported version."
      )
    case "transport_failed":
      values = (
        "Command transport failed",
        "The command could not be started or completed.",
        "Verify the executable and connection configuration, then retry."
      )
    case "invalid_response":
      values = (
        "ccusage response was invalid",
        "ccusage returned an incompatible response.",
        "Verify the installed ccusage version and retry."
      )
    case "executable_unavailable":
      values = (
        "ccusage executable is unavailable",
        "The configured ccusage executable was not found or is not executable.",
        "Install ccusage or correct ccusagePath in ccusage-config.json."
      )
    case "cache_failed":
      values = (
        "Usage cache operation failed",
        "The host usage cache could not be used.",
        "Inspect the persistent log and verify state and cache directory ownership."
      )
    default:
      values = (
        "Collection failed",
        "Collection failed without a safe specific diagnostic.",
        "Inspect the persistent log and retry."
      )
    }
    return SanitizedCollectionError(
      code: code == "internal_error" || [
        "host_key_verification_failed", "auth_failed", "tunnel_unreachable",
        "timeout", "remote_command_failed", "transport_failed",
        "invalid_response", "cache_failed", "executable_unavailable"
      ].contains(code) ? code : "internal_error",
      message: values.0,
      detail: values.1,
      remediation: values.2
    )
  }

  private static func normalizedStderr(_ value: String) -> String {
    let bytes = Data(value.utf8.prefix(4_096))
    let decoded = String(decoding: bytes, as: UTF8.self)
    let folded = decoded.lowercased(with: Locale(identifier: "en_US_POSIX"))
    return folded.unicodeScalars.reduce(into: "") { result, scalar in
      if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.value < 0x20 || scalar.value == 0x7F {
        if result.last != " " { result.append(" ") }
      } else {
        result.unicodeScalars.append(scalar)
      }
    }.trimmingCharacters(in: .whitespaces)
  }
}
