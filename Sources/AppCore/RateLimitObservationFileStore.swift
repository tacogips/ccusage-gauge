import Foundation

/// JSON file of derived usage numbers (no credentials) keyed by provider.
public struct RateLimitObservationFileStore: RateLimitObservationStoring {
  private let url: URL
  public init(url: URL) { self.url = url }

  public func load(_ provider: RateLimitProvider) -> RateLimitObservation? {
    loadAll()[provider.rawValue]
  }

  public func save(_ observation: RateLimitObservation, for provider: RateLimitProvider) {
    var all = loadAll()
    all[provider.rawValue] = observation
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(all) else { return }
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    guard (try? data.write(to: url, options: .atomic)) != nil else { return }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func loadAll() -> [String: RateLimitObservation] {
    guard let data = try? Data(contentsOf: url) else { return [:] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([String: RateLimitObservation].self, from: data)) ?? [:]
  }
}
