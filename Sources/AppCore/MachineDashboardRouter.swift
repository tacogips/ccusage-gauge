import Foundation

public struct MachineDashboardRouter: Sendable {
  private let store: MachineSnapshotStore
  private let collector: MachineCollector
  private let mutationOwner: MachineRegistryMutationOwner
  private let cacheCoordinator: MachineCacheClearCoordinator
  private let paths: AppPaths
  private let queryService: DashboardQueryService
  private let dashboardStateStore: DashboardStateStore
  private let chartColors: ChartColorConfiguration

  public init(
    store: MachineSnapshotStore,
    collector: MachineCollector,
    mutationOwner: MachineRegistryMutationOwner,
    paths: AppPaths,
    queryService: DashboardQueryService = DashboardQueryService(),
    cacheCoordinator: MachineCacheClearCoordinator = MachineCacheClearCoordinator(),
    dashboardStateStore: DashboardStateStore? = nil,
    chartColors: ChartColorConfiguration = ChartColorConfiguration()
  ) {
    self.store = store
    self.collector = collector
    self.mutationOwner = mutationOwner
    self.paths = paths
    self.queryService = queryService
    self.cacheCoordinator = cacheCoordinator
    self.dashboardStateStore = dashboardStateStore ?? DashboardStateStore(fileURL: paths.dashboardStateFile)
    self.chartColors = chartColors
  }

  public func route(
    target: String,
    method: String,
    headers: [String: String],
    body: Data,
    listenerPort: Int
  ) async -> HTTPResponse {
    guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
      return error(status: 400, code: "invalid_request", message: "Invalid request target")
    }
    let path = components.path
    if path == "/api/health", method == "GET" {
      return HTTPResponse(status: 200, contentType: "application/json", body: Data("{\"status\":\"ok\"}".utf8))
    }
    if path == "/api/chart-colors" {
      guard method == "GET" else { return methodNotAllowed("GET") }
      return json(chartColors)
    }
    if method == "OPTIONS", path == "/api/refresh" || path == "/api/cache" || path == "/api/machines" || path.hasPrefix("/api/machines/") {
      return originRejected()
    }
    if path == "/api/machines" || path.hasPrefix("/api/machines/") {
      return await machineRoute(path: path, components: components, method: method, headers: headers, body: body, listenerPort: listenerPort)
    }
    if path == "/api/machine-status" {
      guard method == "GET" else { return methodNotAllowed("GET") }
      return await statusRoute(components)
    }
    if path == "/api/load-status" {
      guard method == "GET" else { return methodNotAllowed("GET") }
      return await loadStatusRoute(components)
    }
    if path == "/api/refresh" {
      guard method == "GET" else { return methodNotAllowed("GET") }
      guard mutationAllowed(headers: headers, listenerPort: listenerPort) else { return originRejected() }
      return await refreshRoute(components)
    }
    if path == "/api/cache" {
      guard method == "DELETE" else { return methodNotAllowed("DELETE") }
      guard mutationAllowed(headers: headers, listenerPort: listenerPort) else { return originRejected() }
      return await cacheRoute(components)
    }
    if path == "/api/dashboard-state" {
      return await dashboardStateResponse(method: method, body: body)
    }
    guard method == "GET" else { return methodNotAllowed("GET") }
    return await queryRoute(path: path, components: components)
  }

  private func dashboardStateResponse(method: String, body: Data) async -> HTTPResponse {
    guard method == "GET" || method == "PUT" else { return methodNotAllowed("GET, PUT") }
    do {
      if method == "PUT" {
        let state = try JSONDecoder().decode(DashboardUIState.self, from: body)
        try await dashboardStateStore.save(state)
        return jsonObject(["status": "ok"], status: 200)
      }
      return json(DashboardUIStateResponse(state: try await dashboardStateStore.load()), status: 200)
    } catch DashboardStateError.invalidState {
      return self.error(status: 400, code: "invalid_dashboard_state", message: "Dashboard state is invalid")
    } catch is DecodingError {
      return self.error(status: 400, code: "invalid_dashboard_state", message: "Dashboard state is invalid")
    } catch {
      return self.error(status: 503, code: "state_unavailable", message: "Dashboard state storage is unavailable")
    }
  }

  private func queryRoute(path: String, components: URLComponents) async -> HTTPResponse {
    let requested: String
    do { requested = try machineSelection(components) }
    catch { return selectionError(error) }
    let coverage = requestedCoverageStart(path: path, components: components)
    if let coverage { await collector.expand(machine: requested, earliestDate: coverage) }
    let evaluatedAt = Date()
    let disposition = dataDisposition(path: path, components: components, now: evaluatedAt)
    let selection: MachineSnapshotSelection
    do {
      selection = try await store.selection(
        machine: requested,
        now: evaluatedAt,
        requiredCoverageStart: coverage,
        dataDisposition: disposition
      )
    } catch {
      return await querySelectionError(
        error,
        path: path,
        requested: requested,
        evaluatedAt: evaluatedAt,
        requiredCoverageStart: coverage,
        dataDisposition: disposition
      )
    }
    guard let snapshot = selection.snapshot else { return error(status: 503, code: "snapshot_unavailable", message: "Usage data is temporarily unavailable") }
    do {
      switch path {
      case "/api/recent":
        let limit = components.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 48
        guard (1...500).contains(limit) else { return error(status: 400, code: "invalid_limit", message: "limit must be 1...500") }
        return jsonWithScope(queryService.recent(snapshot: snapshot, limit: limit), scope: selection.scope)
      case "/api/day":
        guard let text = components.queryItems?.first(where: { $0.name == "date" })?.value,
              let date = queryService.parseDay(text) else {
          return error(status: 400, code: "invalid_date", message: "date must use YYYY-MM-DD")
        }
        return jsonWithScope(queryService.day(snapshot: snapshot, date: date), scope: selection.scope)
      case "/api/period":
        let range = queryValue("range", components) ?? "today"
        if range == "custom" {
          guard let start = queryValue("start", components).flatMap(queryService.parseDay),
                let end = queryValue("end", components).flatMap(queryService.parseDay) else {
            return error(status: 400, code: "invalid_custom_range", message: "custom range requires start and end dates in YYYY-MM-DD format")
          }
          return jsonWithScope(try queryService.period(snapshot: snapshot, startDate: start, endDate: end), scope: selection.scope)
        }
        return jsonWithScope(try queryService.period(snapshot: snapshot, range: range), scope: selection.scope)
      case "/api/metrics":
        let range = queryValue("range", components) ?? "today"
        return try metricsResponse(snapshot: snapshot, range: range, components: components, scope: selection.scope)
      case "/api/cost-series":
        let range = queryValue("range", components) ?? "today"
        let granularity = queryValue("granularity", components) ?? "hourly"
        return try costResponse(
          snapshot: snapshot,
          range: range,
          granularity: granularity,
          components: components,
          scope: selection.scope,
          machineLatestEvents: selection.machineLatestEvents
        )
      case "/api/budget":
        return jsonWithScope(queryService.budget(snapshot: snapshot), scope: selection.scope)
      default:
        return error(status: 404, code: "not_found", message: "API route not found")
      }
    } catch DashboardQueryError.invalidRange {
      return error(status: 400, code: "invalid_range", message: "Invalid range")
    } catch DashboardQueryError.invalidCustomRange {
      return error(status: 400, code: "invalid_custom_range", message: "Invalid custom range")
    } catch DashboardQueryError.invalidGranularity {
      return error(status: 400, code: "invalid_granularity", message: "Invalid granularity")
    } catch {
      return self.error(status: 500, code: "internal_error", message: "Request failed")
    }
  }

  private func metricsResponse(
    snapshot: CostSnapshot,
    range: String,
    components: URLComponents,
    scope: DashboardScope
  ) throws -> HTTPResponse {
    if range == "custom" {
      guard let start = queryValue("start", components).flatMap(queryService.parseDay),
            let end = queryValue("end", components).flatMap(queryService.parseDay) else {
        return error(status: 400, code: "invalid_custom_range", message: "Invalid custom range")
      }
      return jsonWithScope(try queryService.metrics(snapshot: snapshot, range: range, startDate: start, endDate: end), scope: scope)
    }
    return jsonWithScope(try queryService.metrics(snapshot: snapshot, range: range), scope: scope)
  }

  private func costResponse(
    snapshot: CostSnapshot,
    range: String,
    granularity: String,
    components: URLComponents,
    scope: DashboardScope,
    machineLatestEvents: [MachineLatestEvent]
  ) throws -> HTTPResponse {
    var response: DashboardCostResponse
    if range == "custom" {
      guard let start = queryValue("start", components).flatMap(queryService.parseDay),
            let end = queryValue("end", components).flatMap(queryService.parseDay) else {
        return error(status: 400, code: "invalid_custom_range", message: "Invalid custom range")
      }
      response = try queryService.costSeries(
        snapshot: snapshot,
        granularity: granularity,
        range: range,
        startDate: start,
        endDate: end
      )
    } else {
      response = try queryService.costSeries(snapshot: snapshot, granularity: granularity, range: range)
    }
    response.scope = scope
    response.machineLatestEvents = machineLatestEvents
    return json(response, dateMilliseconds: true)
  }

  private func statusRoute(_ components: URLComponents) async -> HTTPResponse {
    guard Set((components.queryItems ?? []).map(\.name)).isSubset(of: ["machine"]) else {
      return invalidMachineSelection()
    }
    do {
      let requested = try machineSelection(components)
      return json(try await store.status(machine: requested), dateMilliseconds: true)
    } catch { return statusSelectionError(error) }
  }

  private func loadStatusRoute(_ components: URLComponents) async -> HTTPResponse {
    do {
      let requested = try machineSelection(components)
      let statuses = try await store.loadStatuses(machine: requested)
      let items = statuses.map { id, status, coverage in
        MachineLoadStatusItem(
          id: id,
          phase: status.phase,
          message: status.message,
          completed: status.completed,
          total: status.total,
          isLoading: status.isLoading,
          coverageStart: coverage.map(formatDay),
          requestedCoverageStart: nil
        )
      }
      let phase = aggregatePhase(items.map(\.phase))
      return json(MachineLoadStatusResponse(
        phase: phase,
        message: loadMessage(phase, count: items.count),
        completed: items.reduce(0) { $0 + $1.completed },
        total: items.reduce(0) { $0 + $1.total },
        isLoading: items.contains(where: \.isLoading),
        requested: requested,
        machines: items
      ))
    } catch { return selectionError(error) }
  }

  private func refreshRoute(_ components: URLComponents) async -> HTTPResponse {
    do {
      let requested = try machineSelection(components)
      if requested != "all" {
        let requestedIDs = requested.split(separator: ",").map(String.init)
        let descriptors = await store.descriptors()
        guard requestedIDs.allSatisfy({ id in descriptors.contains(where: { $0.id == id }) }) else {
          return selectionError(MachineSelectionError.notFound(
            requestedIDs.first { id in !descriptors.contains(where: { $0.id == id }) } ?? requested
          ))
        }
        if let disabled = descriptors.first(where: { requestedIDs.contains($0.id) && !$0.enabled }) {
          return selectionError(MachineSelectionError.disabled(disabled.id))
        }
      }
      let result = await collector.refresh(machine: requested)
      guard !result.succeeded.isEmpty else {
        return error(status: 503, code: "refresh_failed", message: "Refresh failed")
      }
      return json(RefreshResponse(
        status: result.failed.isEmpty ? "ok" : "partial",
        requested: requested,
        refreshedMachineIds: result.succeeded,
        failedMachineIds: result.failed,
        generatedAt: Date()
      ))
    } catch { return selectionError(error) }
  }

  private func cacheRoute(_ components: URLComponents) async -> HTTPResponse {
    do {
      let requested = try machineSelection(components)
      let descriptors = await store.descriptors()
      let targets: [MachineDescriptor]
      if requested == "all" { targets = descriptors }
      else {
        let requestedIDs = requested.split(separator: ",").map(String.init)
        let requestedSet = Set(requestedIDs)
        targets = descriptors.filter { requestedSet.contains($0.id) }
        guard targets.count == requestedIDs.count else {
          return selectionError(MachineSelectionError.notFound(
            requestedIDs.first { id in !descriptors.contains(where: { $0.id == id }) } ?? requested
          ))
        }
      }
      var cleared: [String] = []
      var failed: [CacheClearFailureItem] = []
      for descriptor in targets {
        await collector.pause(machineID: descriptor.id)
        do {
          try await cacheCoordinator.clear(
            machineID: descriptor.id,
            cacheURL: paths.aggregationCacheFile(forMachine: descriptor.id),
            legacyLocalURL: descriptor.id == "local" ? paths.aggregationCacheFile : nil
          )
          await store.clear(machineID: descriptor.id)
          cleared.append(descriptor.id)
          await collector.resume(machineID: descriptor.id)
        } catch {
          failed.append(CacheClearFailureItem(
            id: descriptor.id,
            code: "cache_failed",
            message: "Usage cache could not be cleared",
            reconciliationRequired: false
          ))
          await collector.resume(machineID: descriptor.id)
        }
      }
      let outcome = failed.isEmpty ? "complete" : cleared.isEmpty ? "failed" : "partial"
      return json(CacheClearResponse(
        requested: requested,
        outcome: outcome,
        clearedMachineIds: cleared,
        failedMachines: failed
      ), status: failed.isEmpty ? 200 : cleared.isEmpty ? 500 : 207)
    } catch { return selectionError(error) }
  }

  private func machineRoute(
    path: String,
    components: URLComponents,
    method: String,
    headers: [String: String],
    body: Data,
    listenerPort: Int
  ) async -> HTTPResponse {
    let collection = path == "/api/machines"
    let id: String?
    let action: String?
    if collection {
      id = nil
      action = nil
    } else {
      let prefix = "/api/machines/"
      let suffix = String(path.dropFirst(prefix.count))
      let parts = suffix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard (1...2).contains(parts.count),
            let value = parts.first,
            !value.isEmpty,
            !components.percentEncodedPath.contains("%"),
            MachineValidation.isCanonicalMachineID(value),
            parts.count == 1 || ["test-connection", "refresh"].contains(parts[1]) else {
        return error(status: 400, code: "invalid_machine_id", message: "Invalid machine id", fieldErrors: ["id": "must use a canonical machine id"])
      }
      id = value
      action = parts.count == 2 ? parts[1] : nil
    }
    if let action, let id {
      return await machineAction(
        action,
        id: id,
        components: components,
        method: method,
        headers: headers,
        body: body,
        listenerPort: listenerPort
      )
    }
    if method == "GET" {
      let registry = await mutationOwner.current()
      if collection { return json(MachinesResponse(machines: registry.machines)) }
      guard let descriptor = id.flatMap({ registry.machine(id: $0) }) else {
        return error(status: 404, code: "machine_not_found", message: "Machine not found")
      }
      return json(descriptor)
    }
    guard ["POST", "PUT", "PATCH", "DELETE"].contains(method),
          (collection ? method == "POST" : method != "POST") else {
      return methodNotAllowed(collection ? "GET, POST" : "GET, PUT, PATCH, DELETE")
    }
    guard mutationAllowed(headers: headers, listenerPort: listenerPort) else { return originRejected() }
    if method != "DELETE" {
      let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased()
      guard contentType?.split(separator: ";", maxSplits: 1).first == "application/json" else {
        return error(status: 415, code: "unsupported_media_type", message: "Content-Type must be application/json")
      }
    }
    do {
      let result: (MachineRegistry, MachineDescriptor?)
      switch method {
      case "POST":
        let request: MachineCreateRequest = try decodeBody(body, keys: ["id", "displayName", "kind", "enabled", "ssh"])
        let created = try await mutationOwner.create(MachineDescriptor(
          id: request.id,
          displayName: request.displayName,
          kind: request.kind,
          enabled: request.enabled,
          ssh: request.ssh.connection
        ))
        result = (created.0, created.1)
      case "PUT":
        let request: MachineReplaceRequest = try decodeBody(body, keys: ["displayName", "kind", "enabled", "ssh"])
        let replaced = try await mutationOwner.replace(id: id!, with: MachineDescriptor(
          id: id!,
          displayName: request.displayName,
          kind: request.kind,
          enabled: request.enabled,
          ssh: request.ssh.connection
        ))
        result = (replaced.0, replaced.1)
      case "PATCH":
        let request: MachinePatchRequest = try decodeBody(body, keys: ["displayName", "enabled", "ssh"], exact: false)
        guard !request.isEmpty else { throw MachineBodyError.invalid }
        let patched = try await mutationOwner.patch(
          id: id!,
          displayName: request.displayName,
          enabled: request.enabled,
          ssh: request.ssh?.connection
        )
        result = (patched.0, patched.1)
      case "DELETE":
        result = (try await mutationOwner.delete(id: id!), nil)
      default:
        throw MachineBodyError.invalid
      }
      if method == "DELETE" { return HTTPResponse(status: 204, contentType: "application/json", body: Data()) }
      return json(result.1!, status: method == "POST" ? 201 : 200, headers: method == "POST" ? ["Location": "/api/machines/\(result.1!.id)"] : [:])
    } catch let validation as MachineValidationError {
      return error(status: 422, code: "invalid_machine", message: "Machine validation failed", fieldErrors: validation.fieldErrors)
    } catch MachineRegistryMutationError.conflict {
      return error(status: 409, code: "machine_conflict", message: "Machine conflict")
    } catch MachineRegistryMutationError.notFound {
      return error(status: 404, code: "machine_not_found", message: "Machine not found")
    } catch MachineRegistryTransactionError.reconciliationRequired {
      return error(
        status: 503,
        code: "registry_reconciliation_required",
        message: "Machine registry reconciliation is required",
        extra: ["reconciliationRequired": true]
      )
    } catch MachineRegistryTransactionError.reconciliationFailed(let required) {
      return error(
        status: 500,
        code: "registry_reconciliation_failed",
        message: "Machine registry runtime reconciliation failed",
        extra: ["reconciliationRequired": required]
      )
    } catch is MachineBodyError {
      return error(status: 400, code: "invalid_machine", message: "Invalid machine request")
    } catch is DecodingError {
      return error(status: 400, code: "invalid_machine", message: "Invalid machine request")
    } catch {
      return self.error(status: 500, code: "registry_persistence_failed", message: "Machine registry could not be persisted")
    }
  }

  private func machineAction(
    _ action: String,
    id: String,
    components: URLComponents,
    method: String,
    headers: [String: String],
    body: Data,
    listenerPort: Int
  ) async -> HTTPResponse {
    guard method == "POST" else { return methodNotAllowed("POST") }
    guard mutationAllowed(headers: headers, listenerPort: listenerPort) else { return originRejected() }
    guard (components.queryItems ?? []).isEmpty,
          body.isEmpty || String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "{}" else {
      return error(status: 400, code: "invalid_machine_action", message: "Machine action request is invalid")
    }
    do {
      _ = try await mutationOwner.reload()
    } catch {
      return self.error(
        status: 409,
        code: "registry_reload_failed",
        message: "Machine registry could not be reloaded"
      )
    }
    let registry = await mutationOwner.current()
    guard let descriptor = registry.machine(id: id) else {
      return error(status: 404, code: "machine_not_found", message: "Machine not found")
    }
    guard descriptor.enabled else {
      return error(status: 409, code: "machine_disabled", message: "Machine is disabled")
    }
    if action == "test-connection" {
      let testedAt = Date()
      do {
        try await collector.testConnection(machineID: id)
        return json(MachineConnectionTestResponse(
          machine: id,
          status: "reachable",
          testedAt: testedAt,
          diagnostic: nil
        ), dateMilliseconds: true)
      } catch let error as CCUsageCommandFailure {
        return json(MachineConnectionTestResponse(
          machine: id,
          status: "failed",
          testedAt: testedAt,
          diagnostic: MachineDiagnosticClassifier.classify(error)
        ), dateMilliseconds: true)
      } catch let error as CCUsageError {
        return json(MachineConnectionTestResponse(
          machine: id,
          status: "failed",
          testedAt: testedAt,
          diagnostic: MachineDiagnosticClassifier.classify(error)
        ), dateMilliseconds: true)
      } catch {
        return self.error(
          status: 503,
          code: "connection_test_unavailable",
          message: "Connection test is unavailable"
        )
      }
    }
    let result = await collector.refresh(machine: id)
    let diagnostic = try? await store.status(machine: id).machines.first?.lastError
    return json(RefreshResponse(
      status: result.failed.isEmpty ? "ok" : "failed",
      requested: id,
      refreshedMachineIds: result.succeeded,
      failedMachineIds: result.failed,
      generatedAt: Date(),
      diagnostic: result.failed.isEmpty ? nil : diagnostic ?? MachineDiagnosticClassifier.diagnostic(for: "internal_error")
    ), dateMilliseconds: true)
  }

  private func machineSelection(_ components: URLComponents) throws -> String {
    let values = (components.queryItems ?? []).filter { $0.name == "machine" }
    let requestedIDs = values.compactMap(\.value)
    guard requestedIDs.count == values.count else { throw MachineSelectionError.invalid }
    if let query = components.percentEncodedQuery,
       query.split(separator: "&").contains(where: { item in
         item.hasPrefix("machine=") && item.dropFirst("machine=".count).contains("%")
       }) { throw MachineSelectionError.invalid }
    if requestedIDs.isEmpty { return "all" }
    if requestedIDs == ["all"] { return "all" }
    guard !requestedIDs.contains("all"),
          requestedIDs.allSatisfy(MachineValidation.isCanonicalMachineID),
          Set(requestedIDs).count == requestedIDs.count else {
      throw MachineSelectionError.invalid
    }
    return requestedIDs.joined(separator: ",")
  }

  private func selectionError(_ value: Error) -> HTTPResponse {
    switch value {
    case MachineSelectionError.invalid:
      return error(status: 400, code: "invalid_machine", message: "Invalid machine selection")
    case MachineSelectionError.notFound(let id):
      return jsonObject(["error": "machine_not_found", "machine": id], status: 404)
    case MachineSelectionError.disabled(let id):
      return jsonObject(["error": "machine_disabled", "machine": id, "collectionState": "disabled"], status: 409)
    case MachineSelectionError.unavailable(let id, let state, let interval):
      return jsonObject([
        "error": "snapshot_unavailable",
        "machine": id,
        "collectionState": state.rawValue,
        "refreshIntervalSeconds": interval
      ], status: 503, headers: ["Retry-After": String(interval)])
    case MachineSelectionError.aggregateUnavailable(let interval):
      return jsonObject(["error": "snapshot_unavailable", "refreshIntervalSeconds": interval], status: 503, headers: ["Retry-After": String(interval)])
    default:
      return error(status: 500, code: "internal_error", message: "Request failed")
    }
  }

  private func querySelectionError(
    _ value: Error,
    path: String,
    requested: String,
    evaluatedAt: Date,
    requiredCoverageStart: Date?,
    dataDisposition: DashboardDataDisposition
  ) async -> HTTPResponse {
    let markers = path == "/api/cost-series"
      ? (try? await store.latestEvents(machine: requested, now: evaluatedAt))
      : nil
    let resolvedScope = try? await store.observabilityScope(
      machine: requested,
      now: evaluatedAt,
      requiredCoverageStart: requiredCoverageStart,
      dataDisposition: dataDisposition
    )
    switch value {
    case MachineSelectionError.disabled(let id):
      var body: [String: Any] = [
        "error": "machine_disabled",
        "machine": id,
        "collectionState": "disabled",
        "scope": resolvedScope.map(jsonValue) ?? scopeObject(
          requested: id,
          included: [],
          stale: [],
          unavailable: [],
          disposition: dataDisposition,
          evaluatedAt: evaluatedAt
        )
      ]
      if let markers { body["machineLatestEvents"] = jsonValue(markers) }
      return jsonObject(body, status: 409)
    case MachineSelectionError.unavailable(let id, let state, let interval):
      var body: [String: Any] = [
        "error": "snapshot_unavailable",
        "machine": id,
        "collectionState": state.rawValue,
        "refreshIntervalSeconds": interval,
        "scope": resolvedScope.map(jsonValue) ?? scopeObject(
          requested: id,
          included: [],
          stale: [],
          unavailable: [id],
          disposition: dataDisposition,
          evaluatedAt: evaluatedAt
        )
      ]
      if let markers { body["machineLatestEvents"] = jsonValue(markers) }
      return jsonObject(body, status: 503, headers: ["Retry-After": String(interval)])
    case MachineSelectionError.currentDataUnavailable(let id, let state, let interval, let scope):
      var body: [String: Any] = [
        "error": [
          "code": "current_data_unavailable",
          "message": "Current usage data is unavailable"
        ],
        "machine": id,
        "collectionState": state.rawValue,
        "refreshIntervalSeconds": interval,
        "scope": jsonValue(scope)
      ]
      if let markers { body["machineLatestEvents"] = jsonValue(markers) }
      return jsonObject(body, status: 503, headers: ["Retry-After": String(interval)])
    case MachineSelectionError.aggregateCurrentDataUnavailable(let interval, let scope):
      var body: [String: Any] = [
        "error": [
          "code": "current_data_unavailable",
          "message": "Current usage data is unavailable"
        ],
        "refreshIntervalSeconds": interval,
        "scope": jsonValue(scope)
      ]
      if let markers { body["machineLatestEvents"] = jsonValue(markers) }
      return jsonObject(body, status: 503, headers: ["Retry-After": String(interval)])
    case MachineSelectionError.rangeUnavailable(let id, let requested, let available, let interval):
      var body: [String: Any] = [
        "error": "range_unavailable",
        "machine": id,
        "requestedCoverageStart": formatDay(requested),
        "availableCoverageStart": available.map { formatDay($0) } as Any? ?? NSNull(),
        "refreshIntervalSeconds": interval,
        "scope": resolvedScope.map(jsonValue) ?? scopeObject(
          requested: id,
          included: [],
          stale: [],
          unavailable: [id],
          disposition: dataDisposition,
          evaluatedAt: evaluatedAt
        )
      ]
      if let markers { body["machineLatestEvents"] = jsonValue(markers) }
      return jsonObject(body, status: 503, headers: ["Retry-After": String(interval)])
    case MachineSelectionError.aggregateRangeUnavailable(let requested, let interval):
      let unavailable = await store.descriptors().filter(\.enabled).map(\.id)
      var body: [String: Any] = [
        "error": "range_unavailable",
        "requestedCoverageStart": formatDay(requested),
        "refreshIntervalSeconds": interval,
        "scope": resolvedScope.map(jsonValue) ?? scopeObject(
          requested: "all",
          included: [],
          stale: [],
          unavailable: unavailable,
          disposition: dataDisposition,
          evaluatedAt: evaluatedAt
        )
      ]
      if let markers { body["machineLatestEvents"] = jsonValue(markers) }
      return jsonObject(body, status: 503, headers: ["Retry-After": String(interval)])
    case MachineSelectionError.aggregateUnavailable(let interval):
      let unavailable = await store.descriptors().filter(\.enabled).map(\.id)
      var body: [String: Any] = [
        "error": "snapshot_unavailable",
        "refreshIntervalSeconds": interval,
        "scope": resolvedScope.map(jsonValue) ?? scopeObject(
          requested: "all",
          included: [],
          stale: [],
          unavailable: unavailable,
          disposition: dataDisposition,
          evaluatedAt: evaluatedAt
        )
      ]
      if let markers { body["machineLatestEvents"] = jsonValue(markers) }
      return jsonObject(body, status: 503, headers: ["Retry-After": String(interval)])
    default:
      return selectionError(value)
    }
  }

  private func scopeObject(
    requested: String,
    included: [String],
    stale: [String],
    unavailable: [String],
    disposition: DashboardDataDisposition = .historical,
    evaluatedAt: Date = Date()
  ) -> [String: Any] {
    [
      "requested": requested,
      "dataDisposition": disposition.rawValue,
      "includedMachineIds": included,
      "staleMachineIds": stale,
      "unavailableMachineIds": unavailable,
      "excludedFromCurrentTotalsMachineIds": disposition == .current ? Array(Set(stale + unavailable)).sorted() : [],
      "machineAvailability": [],
      "lastHourDataGaps": [],
      "evaluatedAt": millisecondsTimestamp(evaluatedAt),
      "generatedAt": NSNull()
    ]
  }

  private func jsonValue<T: Encodable>(_ value: T) -> Any {
    guard let data = try? encoder(milliseconds: true).encode(value),
          let object = try? JSONSerialization.jsonObject(with: data) else {
      return NSNull()
    }
    return object
  }

  private func statusSelectionError(_ value: Error) -> HTTPResponse {
    switch value {
    case MachineSelectionError.invalid: return invalidMachineSelection()
    case MachineSelectionError.notFound:
      return error(status: 404, code: "machine_not_found", message: "Machine not found", fieldErrors: ["machine": "was not found"])
    default: return error(status: 500, code: "machine_status_unavailable", message: "Machine status unavailable")
    }
  }

  private func mutationAllowed(headers: [String: String], listenerPort: Int) -> Bool {
    let normalized = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    guard normalized["x-ccusage-gauge-mutation"] == "1" else { return false }
    let acceptedHosts = ["127.0.0.1:\(listenerPort)", "localhost:\(listenerPort)"]
    guard let host = normalized["host"], acceptedHosts.contains(host.lowercased()) else { return false }
    let fetchSite = normalized["sec-fetch-site"]?.lowercased()
    if fetchSite == "cross-site" || fetchSite == "same-site" || fetchSite == "none" { return false }
    if let origin = normalized["origin"] {
      guard origin != "null", acceptedHosts.map({ "http://\($0)" }).contains(origin.lowercased()),
            fetchSite == nil || fetchSite == "same-origin" else { return false }
    } else if fetchSite != nil, fetchSite != "same-origin" {
      return false
    }
    return true
  }

  private func requestedCoverageStart(path: String, components: URLComponents) -> Date? {
    if path == "/api/day" { return queryValue("date", components).flatMap(queryService.parseDay) }
    guard ["/api/period", "/api/metrics", "/api/cost-series"].contains(path) else { return nil }
    let range = queryValue("range", components) ?? "today"
    if range == "custom" { return queryValue("start", components).flatMap(queryService.parseDay) }
    let now = Date()
    switch range {
    case "recent12h": return now.addingTimeInterval(-43_200)
    case "today": return queryService.calendar.startOfDay(for: now)
    case "yesterday": return queryService.calendar.date(byAdding: .day, value: -1, to: queryService.calendar.startOfDay(for: now))
    case "week": return queryService.calendar.dateInterval(of: .weekOfYear, for: now)?.start
    case "month": return queryService.calendar.dateInterval(of: .month, for: now)?.start
    default: return nil
    }
  }

  private func dataDisposition(
    path: String,
    components: URLComponents,
    now: Date
  ) -> DashboardDataDisposition {
    if path == "/api/recent" || path == "/api/budget" { return .current }
    let today = queryService.calendar.startOfDay(for: now)
    if path == "/api/day" {
      guard let day = queryValue("date", components).flatMap(queryService.parseDay) else { return .current }
      return day >= today ? .current : .historical
    }
    let range = queryValue("range", components) ?? "today"
    if range == "yesterday" { return .historical }
    if range == "custom" {
      guard let end = queryValue("end", components).flatMap(queryService.parseDay) else { return .current }
      return end >= today ? .current : .historical
    }
    return .current
  }

  private func queryValue(_ name: String, _ components: URLComponents) -> String? {
    components.queryItems?.first(where: { $0.name == name })?.value
  }

  private func decodeBody<T: Decodable>(
    _ body: Data,
    keys: Set<String>,
    exact: Bool = true
  ) throws -> T {
    guard body.count <= 65_536,
          let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
          Set(object.keys).isSubset(of: keys), !exact || Set(object.keys) == keys else {
      throw MachineBodyError.invalid
    }
    if let ssh = object["ssh"] as? [String: Any] {
      let allowed = Set(["host", "port", "user", "identityFile", "extraOptions", "proxy", "remoteCcusagePath"])
      let required = Set(["host", "port", "user"])
      guard Set(ssh.keys).isSubset(of: allowed), required.isSubset(of: Set(ssh.keys)),
            ssh["identityFile"] is NSNull == false,
            ssh["proxy"] is NSNull == false else {
        throw MachineBodyError.invalid
      }
      if let proxy = ssh["proxy"] as? [String: Any] {
        guard let kind = proxy["kind"] as? String else { throw MachineBodyError.invalid }
        let proxyKeys = Set(proxy.keys)
        switch kind {
        case "direct":
          guard proxyKeys == ["kind"] else { throw MachineBodyError.invalid }
        case "jump":
          let required = Set(["kind", "host", "port", "user"])
          guard required.isSubset(of: proxyKeys),
                proxyKeys.isSubset(of: required.union(["identityFile", "knownHostsFile"])),
                proxy["identityFile"] is NSNull == false,
                proxy["knownHostsFile"] is NSNull == false else {
            throw MachineBodyError.invalid
          }
        case "command":
          guard proxyKeys == ["kind", "executable"] else { throw MachineBodyError.invalid }
        default:
          throw MachineBodyError.invalid
        }
      } else if ssh.keys.contains("proxy") {
        throw MachineBodyError.invalid
      }
    }
    return try JSONDecoder().decode(T.self, from: body)
  }

  private func jsonWithScope<T: Encodable & ScopedDashboardResponse>(_ value: T, scope: DashboardScope) -> HTTPResponse {
    // Single-pass encoding: attach `scope` to the DTO and let `JSONEncoder` emit it as a sibling
    // key, avoiding the earlier encode -> JSONSerialization -> re-serialize round-trip.
    var value = value
    value.scope = scope
    return json(value)
  }

  private func json<T: Encodable>(
    _ value: T,
    status: Int = 200,
    headers: [String: String] = [:],
    dateMilliseconds: Bool = false
  ) -> HTTPResponse {
    let encoder = encoder(milliseconds: dateMilliseconds)
    guard let body = try? encoder.encode(value) else { return error(status: 500, code: "encoding_failed", message: "Response encoding failed") }
    return HTTPResponse(status: status, contentType: "application/json", body: body, headers: headers)
  }

  private func jsonObject(_ value: [String: Any], status: Int, headers: [String: String] = [:]) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    return HTTPResponse(status: status, contentType: "application/json", body: body, headers: headers)
  }

  private func error(
    status: Int,
    code: String,
    message: String,
    fieldErrors: [String: String]? = nil,
    extra: [String: Any] = [:]
  ) -> HTTPResponse {
    var detail: [String: Any] = ["code": code, "message": message]
    if let fieldErrors { detail["fieldErrors"] = fieldErrors }
    var body: [String: Any] = ["error": detail]
    body.merge(extra) { current, _ in current }
    return jsonObject(body, status: status)
  }

  private func invalidMachineSelection() -> HTTPResponse {
    error(
      status: 400,
      code: "invalid_machine_selection",
      message: "Invalid machine selection",
      fieldErrors: ["machine": "must use one or more unique canonical machine ids, or all"]
    )
  }

  private func originRejected() -> HTTPResponse {
    error(status: 403, code: "origin_rejected", message: "State-changing request rejected")
  }

  private func methodNotAllowed(_ allow: String) -> HTTPResponse {
    HTTPResponse(
      status: 405,
      contentType: "application/json",
      body: error(status: 405, code: "method_not_allowed", message: "Method not allowed").body,
      headers: ["Allow": allow]
    )
  }

  private func encoder(milliseconds: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    if milliseconds {
      encoder.dateEncodingStrategy = .custom { date, encoder in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var container = encoder.singleValueContainer()
        try container.encode(formatter.string(from: date))
      }
    } else {
      encoder.dateEncodingStrategy = .iso8601
    }
    return encoder
  }

  private func millisecondsTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func aggregatePhase(_ values: [DashboardLoadPhase]) -> DashboardLoadPhase {
    for phase in [DashboardLoadPhase.loadingHistory, .loadingWeek, .refreshing, .failed, .ready, .idle]
    where values.contains(phase) { return phase }
    return .idle
  }

  private func loadMessage(_ phase: DashboardLoadPhase, count: Int) -> String {
    switch phase {
    case .loadingHistory: "Loading historical usage for \(count) machine\(count == 1 ? "" : "s")"
    case .loadingRange: "Loading usage range for \(count) machine\(count == 1 ? "" : "s")"
    case .loadingWeek: "Loading current usage for \(count) machine\(count == 1 ? "" : "s")"
    case .refreshing: "Refreshing \(count) machine\(count == 1 ? "" : "s")"
    case .failed: "Usage loading failed"
    case .ready: "Usage data is ready"
    case .idle: "Waiting to load usage data"
    }
  }

  private func formatDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = queryService.calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = queryService.calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}

private enum MachineBodyError: Error { case invalid }
