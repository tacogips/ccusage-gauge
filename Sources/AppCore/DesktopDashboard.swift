import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The desktop window owns presentation; the launching Swift process owns all data.
@MainActor
public final class DesktopDashboard {
  private var process: Process?
  private var input: FileHandle?

  public init() {}

  public var isRunning: Bool { process?.isRunning == true }
  public var processIdentifier: Int32? { isRunning ? process?.processIdentifier : nil }

  public static func executableURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    hostURL: URL = URL(fileURLWithPath: CommandLine.arguments[0])
  ) throws -> URL {
    let directory = hostURL.deletingLastPathComponent()
    let candidates: [URL]
    if let explicit = environment["CCUSAGE_GAUGE_DESKTOP_EXECUTABLE"] {
      candidates = [URL(fileURLWithPath: explicit)]
    } else {
      candidates = [
        directory.appendingPathComponent("../Helpers/CCUsageGaugeDashboard.app/Contents/MacOS/ccusage-gauge-dashboard").standardizedFileURL,
        directory.appendingPathComponent("ccusage-gauge-dashboard")
      ]
    }
    guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
      throw DesktopDashboardError.executableMissing
    }
    return executable
  }

  public func start(router: MachineDashboardRouter, executable: URL? = nil) throws {
    guard !isRunning else { return }
    let child = Process()
    child.executableURL = try executable ?? Self.executableURL()
    child.arguments = ["--swift-host"]
    let requests = Pipe()
    let responses = Pipe()
    child.standardOutput = requests
    child.standardInput = responses
    child.standardError = FileHandle.standardError
    // The window can close while a routed request is still completing.
    signal(SIGPIPE, SIG_IGN)
    try child.run()
    process = child
    input = responses.fileHandleForWriting
    let writer = DesktopDashboardWriter(output: responses.fileHandleForWriting)
    Task.detached {
      let reader = requests.fileHandleForReading
      var buffer = Data()
      while true {
        let chunk = reader.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
          let line = Data(buffer[..<newline])
          buffer.removeSubrange(...newline)
          Task {
            do {
              let request = try JSONDecoder().decode(DesktopDashboardRequest.self, from: line)
              let response = await request.route(using: router)
              await writer.send(response)
            } catch {
              // Protocol errors are fatal; do not leave a window waiting forever.
              await writer.close()
            }
          }
        }
        if buffer.count > 2_097_152 { break }
      }
      await writer.close()
      try? reader.close()
    }
  }

  public func stop() {
    try? input?.close()
    input = nil
    if let process, process.isRunning { process.terminate() }
    process = nil
  }
}

public enum DesktopDashboardError: LocalizedError {
  case executableMissing

  public var errorDescription: String? {
    "Tauri dashboard executable missing. Run mise run desktop:build, or set CCUSAGE_GAUGE_DESKTOP_EXECUTABLE."
  }
}

struct DesktopDashboardRequest: Decodable, Sendable {
  let id: UInt64
  let path: String
  let method: String
  let body: String?

  func route(using router: MachineDashboardRouter) async -> DesktopDashboardResponse {
    guard path.hasPrefix("/api/"), !path.contains("\n"), !path.contains("\r"), !path.contains("#"),
          ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method),
          (body?.utf8.count ?? 0) <= 1_048_576 else {
      return DesktopDashboardResponse(id: id, status: 400, contentType: "application/json", body: "{\"error\":\"Invalid desktop request\"}")
    }
    // These headers are created only for our private pipe, never accepted from a web origin.
    let response = await router.route(
      target: path, method: method,
      headers: ["host": "127.0.0.1:0", "x-ccusage-gauge-mutation": "1", "content-type": "application/json"],
      body: Data((body ?? "").utf8), listenerPort: 0
    )
    return DesktopDashboardResponse(
      id: id, status: response.status, contentType: response.contentType,
      body: String(data: response.body, encoding: .utf8) ?? ""
    )
  }
}

struct DesktopDashboardResponse: Codable, Sendable {
  let id: UInt64
  let status: Int
  let contentType: String
  let body: String
}

private actor DesktopDashboardWriter {
  private var output: FileHandle?

  init(output: FileHandle) { self.output = output }

  func send(_ response: DesktopDashboardResponse) {
    guard let output else { return }
    do {
      let data = try JSONEncoder().encode(response)
      try output.write(contentsOf: data + Data([10]))
    } catch { close() }
  }

  func close() {
    try? output?.close()
    output = nil
  }
}
