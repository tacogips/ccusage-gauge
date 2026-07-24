import AppCore
@preconcurrency import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Shared runtime helpers for the local commands (`config-check`,
/// `usage-snapshot`, and `serve`). These preserve the behavior of the previous
/// hand-written entry point.
enum CommandRuntime {
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
        let diagnostic = MachineDiagnosticClassifier.classify(error)
        let payload = ["error": ["code": diagnostic.code, "message": diagnostic.message]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        FileHandle.standardError.write(data + Data("\n".utf8))
      }
      throw error
    }
  }

  static func serve(port: Int?, assets: String?) async throws {
    let paths = AppPaths.production()
    let config = try ConfigStore(fileURL: paths.configFile).loadOrCreate()
    let registryStore = MachineRegistryStore(fileURL: paths.machinesFile)
    let registry = try registryStore.load()
    try LocalCacheMigrator(
      legacyURL: paths.aggregationCacheFile,
      destinationURL: paths.aggregationCacheFile(forMachine: "local")
    ).migrateIfNeeded()
    for descriptor in registry.machines {
      try MachineCacheRecovery.reconcile(
        machineID: descriptor.id,
        cacheURL: paths.aggregationCacheFile(forMachine: descriptor.id)
      )
    }
    let executable = try CCUsageExecutableResolver().resolve(configuredPath: config.ccusagePath)
    let stateStore = StateStore(fileURL: paths.stateFile)
    let snapshotStore = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: config.pollIntervalSeconds)
    let collector = try MachineCollector(
      registry: registry,
      store: snapshotStore,
      connectionTester: { descriptor in
        let runner: any CCUsageCommandRunner
        if descriptor.kind == .local {
          runner = LocalCCUsageCommandRunner(executable: executable)
        } else {
          guard let connection = descriptor.ssh else {
            throw MachineValidationError(fieldErrors: ["ssh": "is required"])
          }
          runner = try SSHCCUsageCommandRunner(connection: connection)
        }
        _ = try await runner.run(arguments: ["--version"], timeoutSeconds: 30)
      }
    ) { descriptor in
      let client: CCUsageClient
      if descriptor.kind == .local {
        client = CCUsageClient(executable: executable, machine: descriptor.id)
      } else {
        guard let connection = descriptor.ssh else { throw MachineValidationError(fieldErrors: ["ssh": "is required"]) }
        client = CCUsageClient(commandRunner: try SSHCCUsageCommandRunner(connection: connection), machine: descriptor.id)
      }
      return SnapshotService(
        stateStore: stateStore,
        client: client,
        defaultRefreshIntervalSeconds: config.pollIntervalSeconds,
        aggregationCache: UsageAggregationCache(
          fileURL: paths.aggregationCacheFile(forMachine: descriptor.id),
          retentionDays: config.cacheRetentionDays,
          machineID: descriptor.id
        ),
        claudeUsageEventLoader: descriptor.kind == .local ? .production() : nil,
        codexUsageEventLoader: descriptor.kind == .local ? .production() : nil
      )
    }
    let mutationOwner = MachineRegistryMutationOwner(store: registryStore, registry: registry, runtime: collector)
    let resolver = StaticAssetResolver(explicitRoot: assets.map { URL(fileURLWithPath: $0, isDirectory: true) })
    let machineRouter = MachineDashboardRouter(
      store: snapshotStore,
      collector: collector,
      mutationOwner: mutationOwner,
      paths: paths,
      dashboardStateStore: DashboardStateStore(fileURL: paths.dashboardStateFile),
      chartColors: config.chartColors
    )
    let router = DashboardRouter(machineRouter: machineRouter, assetResolver: resolver)
    let server = DashboardHTTPServer(router: router)
    let selectedPort = port ?? config.dashboardPort
    await collector.start()
    try server.start(port: UInt16(selectedPort))
    print("Dashboard listening on http://127.0.0.1:\(selectedPort)")
    await waitForTerminationSignal()
    server.stop()
    await collector.stop()
  }

  static func makeSnapshotService(configuration: AppConfiguration? = nil, paths: AppPaths? = nil) throws -> SnapshotService {
    let resolvedPaths = paths ?? AppPaths.production()
    let config = try configuration ?? ConfigStore(fileURL: resolvedPaths.configFile).loadOrCreate()
    let executable = try CCUsageExecutableResolver().resolve(configuredPath: config.ccusagePath)
    try LocalCacheMigrator(
      legacyURL: resolvedPaths.aggregationCacheFile,
      destinationURL: resolvedPaths.aggregationCacheFile(forMachine: "local")
    ).migrateIfNeeded()
    return SnapshotService(
      stateStore: StateStore(fileURL: resolvedPaths.stateFile),
      client: CCUsageClient(executable: executable),
      defaultRefreshIntervalSeconds: config.pollIntervalSeconds,
      aggregationCache: UsageAggregationCache(
        fileURL: resolvedPaths.aggregationCacheFile(forMachine: "local"),
        retentionDays: config.cacheRetentionDays,
        machineID: "local"
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
}
