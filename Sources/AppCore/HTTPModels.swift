import Foundation

public struct StaticAssetResolver: Sendable {
  public let explicitRoot: URL?
  public let executableURL: URL

  public init(explicitRoot: URL? = nil, executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0])) {
    self.explicitRoot = explicitRoot
    self.executableURL = executableURL
  }

  public func roots() -> [URL] {
    if let explicitRoot { return [explicitRoot] }
    var candidates: [URL] = []
    let executableDirectory = executableURL.deletingLastPathComponent()
    if let entries = try? FileManager.default.contentsOfDirectory(at: executableDirectory, includingPropertiesForKeys: nil) {
      candidates.append(
        contentsOf: entries.filter { $0.pathExtension == "bundle" }
          .map { $0.appendingPathComponent("Web", isDirectory: true) }
      )
    }
    if let mainResources = Bundle.main.resourceURL {
      candidates.append(mainResources.appendingPathComponent("Web", isDirectory: true))
    }
    candidates.append(
      executableDirectory.appendingPathComponent("../share/ccusage-gauge/web", isDirectory: true).standardizedFileURL
    )
    candidates.append(
      executableDirectory.appendingPathComponent("../Resources/Web", isDirectory: true).standardizedFileURL
    )
    return candidates
  }

  public func resolve(path: String) -> URL? {
    let requested = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
    guard !requested.contains("..") else { return nil }
    for root in roots() {
      let candidate = root.appendingPathComponent(requested)
      if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
      let index = root.appendingPathComponent("index.html")
      if !path.hasPrefix("/api/"), FileManager.default.isReadableFile(atPath: index.path) { return index }
    }
    return nil
  }
}

public struct HTTPResponse: Sendable {
  public let status: Int
  public let contentType: String
  public let body: Data
  public let headers: [String: String]

  public init(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) {
    self.status = status
    self.contentType = contentType
    self.body = body
    self.headers = headers
  }
}

public enum DashboardLoadPhase: String, Codable, Equatable, Sendable {
  case idle
  case loadingWeek
  case loadingHistory
  case loadingRange
  case refreshing
  case ready
  case failed
}

public struct DashboardLoadStatus: Codable, Equatable, Sendable {
  public let phase: DashboardLoadPhase
  public let message: String
  public let completed: Int
  public let total: Int
  public let isLoading: Bool
}
