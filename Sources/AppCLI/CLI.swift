import AppCore
import Darwin
import Foundation

@main
struct CCUsageGaugeCLI {
  static func main() async {
    let command = AppCommand(arguments: Array(CommandLine.arguments.dropFirst()))
    do {
      switch try command.parse() {
      case .help: print(command.usage)
      case .version: print(Version.current)
      case .configCheck: try await configCheck()
      case .usageSnapshot(let json): try await usageSnapshot(json: json)
      case .dashboard(let port, let assets): try await dashboard(port: port, assets: assets)
      }
    } catch AppCommand.Error.unknownArgument(let value) {
      fail("Unknown argument: \(value)", code: 2)
    } catch AppCommand.Error.invalidValue(let value) {
      fail(value, code: 2)
    } catch {
      fail(String(describing: error), code: 1)
    }
  }

  static func configCheck() async throws {
    let paths = AppPaths.production()
    let config = try ConfigStore(fileURL: paths.configFile).loadOrCreate()
    _ = try await StateStore(fileURL: paths.stateFile).load(defaultCycle: try ResetCycle(term: config.defaultResetTerm))
    let executable = try CCUsageExecutableResolver().resolve(configuredPath: config.ccusagePath)
    print("Configuration valid; ccusage executable: \(executable.path); dashboard port: \(config.dashboardPort)")
  }

  static func usageSnapshot(json: Bool) async throws {
    let service = try makeSnapshotService()
    do {
      let snapshot = try await service.snapshot()
      if json {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        print(String(data: data, encoding: .utf8) ?? "{}")
      } else {
        print("Cost in selected period: $\(snapshot.costSinceResetUSD) (from \(snapshot.activeBoundaryAt.ISO8601Format()))")
      }
    } catch {
      if json {
        let payload = ["error": ["code": "snapshot_failed", "message": String(describing: error)]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        FileHandle.standardError.write(data + Data("\n".utf8))
      }
      throw error
    }
  }

  static func dashboard(port: Int?, assets: String?) async throws {
    let paths = AppPaths.production()
    let config = try ConfigStore(fileURL: paths.configFile).loadOrCreate()
    let service = try makeSnapshotService(configuration: config, paths: paths)
    let resolver = StaticAssetResolver(explicitRoot: assets.map { URL(fileURLWithPath: $0, isDirectory: true) })
    let router = DashboardRouter(snapshotProvider: { try await service.snapshot() }, assetResolver: resolver)
    let server = DashboardHTTPServer(router: router)
    let selectedPort = port ?? config.dashboardPort
    try server.start(port: UInt16(selectedPort))
    print("Dashboard listening on http://127.0.0.1:\(selectedPort)")
    await waitForTerminationSignal()
    server.stop()
  }

  static func makeSnapshotService(configuration: AppConfiguration? = nil, paths: AppPaths? = nil) throws -> SnapshotService {
    let resolvedPaths = paths ?? AppPaths.production()
    let config = try configuration ?? ConfigStore(fileURL: resolvedPaths.configFile).loadOrCreate()
    let executable = try CCUsageExecutableResolver().resolve(configuredPath: config.ccusagePath)
    return SnapshotService(
      stateStore: StateStore(fileURL: resolvedPaths.stateFile),
      client: CCUsageClient(executable: executable),
      defaultRefreshIntervalSeconds: config.pollIntervalSeconds,
      aggregationCache: UsageAggregationCache(
        fileURL: resolvedPaths.aggregationCacheFile,
        retentionDays: config.cacheRetentionDays
      ),
      claudeUsageEventLoader: .production(),
      codexUsageEventLoader: .production()
    )
  }

  static func waitForTerminationSignal() async {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let stream = AsyncStream<Int32> { continuation in
      let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
      let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
      interrupt.setEventHandler { continuation.yield(SIGINT) }
      terminate.setEventHandler { continuation.yield(SIGTERM) }
      continuation.onTermination = { _ in interrupt.cancel(); terminate.cancel() }
      interrupt.resume()
      terminate.resume()
    }
    for await _ in stream { break }
  }

  static func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(code)
  }
}
