import AppCore
import ArgumentParser
import Foundation

/// A rendered command result: the exact server bytes for `--json` output and a
/// compact human-readable summary for text output.
struct RenderedResponse {
  let raw: Data
  let text: String
}

/// Builds the loopback client and runs a command, translating structured client
/// failures into the documented exit statuses.
enum ClientRuntime {
  /// Resolves the loopback port from `--api-port` or the configured
  /// `dashboardPort` (default `18081`).
  static func resolvePort(_ apiPort: Int?) throws -> Int {
    if let apiPort { return apiPort }
    let paths = AppPaths.production()
    let config = try ConfigStore(fileURL: paths.configFile).loadOrCreate()
    return config.dashboardPort
  }

  /// Executes a client operation and emits either the raw JSON body or the text
  /// summary. Throws `ExitCode` on any failure so the entry point exits with the
  /// documented status.
  static func run(
    options: ClientOptions,
    render: (DashboardAPIClient) async throws -> RenderedResponse
  ) async throws {
    do {
      let port = try resolvePort(options.apiPort)
      let client = DashboardAPIClient(port: port)
      let rendered = try await render(client)
      if options.json {
        var data = rendered.raw
        if data.last != 0x0A { data.append(0x0A) }
        FileHandle.standardOutput.write(data)
      } else {
        print(rendered.text)
      }
    } catch let error as DashboardClientError {
      try emit(error, json: options.json)
    } catch let exit as ExitCode {
      throw exit
    } catch {
      FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
      throw ExitCode(1)
    }
  }

  /// Maps a structured client failure to the documented CLI exit status.
  static func exitStatus(for error: DashboardClientError) -> Int32 {
    switch error {
    case .unreachable: 3
    case .decoding: 1
    case .api(let apiError): apiError.isServerError ? 5 : 4
    }
  }

  private static func emit(_ error: DashboardClientError, json: Bool) throws -> Never {
    switch error {
    case .unreachable(let detail):
      writeError(json: json, code: "api_unreachable", message: "Dashboard API is unreachable (\(detail))")
    case .decoding(let detail):
      writeError(json: json, code: "decoding_failed", message: "Could not decode the dashboard response (\(detail))")
    case .api(let apiError):
      if json {
        var body = apiError.rawBody
        if body.isEmpty {
          body = synthesizedJSON(code: apiError.code, message: apiError.message)
        }
        if body.last != 0x0A { body.append(0x0A) }
        FileHandle.standardError.write(body)
      } else {
        FileHandle.standardError.write(Data((textError(apiError) + "\n").utf8))
      }
    }
    throw ExitCode(exitStatus(for: error))
  }

  private static func textError(_ error: DashboardAPIError) -> String {
    var lines = ["Error [\(error.code)]: \(error.message)"]
    for (field, message) in error.fieldErrors.sorted(by: { $0.key < $1.key }) {
      lines.append("  \(field): \(message)")
    }
    if let retry = error.retryAfterSeconds {
      lines.append("  retry after: \(retry)s")
    }
    return lines.joined(separator: "\n")
  }

  private static func writeError(json: Bool, code: String, message: String) {
    if json {
      var data = synthesizedJSON(code: code, message: message)
      data.append(0x0A)
      FileHandle.standardError.write(data)
    } else {
      FileHandle.standardError.write(Data("Error [\(code)]: \(message)\n".utf8))
    }
  }

  private static func synthesizedJSON(code: String, message: String) -> Data {
    let payload = ["error": ["code": code, "message": message]]
    return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
  }
}
