import Foundation

extension MachineDashboardRouter {
  func machineRoute(
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
      if collection {
        let pendingMetadataCleanupMachineIDs = await mutationOwner.retryPendingMetadataCleanup()
        let registry = await mutationOwner.current()
        return json(MachinesResponse(
          machines: registry.machines,
          metadataCleanupPendingMachineIds: pendingMetadataCleanupMachineIDs
        ))
      }
      let registry = await mutationOwner.current()
      guard let descriptor = id.flatMap({ registry.machine(id: $0) }) else {
        return error(status: 404, code: "machine_not_found", message: "Machine not found")
      }
      return json(descriptor)
    }
    guard ["POST", "PUT", "PATCH", "DELETE"].contains(method),
          collection ? method == "POST" : method != "POST" else {
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
        let request: MachineCreateRequest = try MachineRequestDecoder.decode(
          body,
          allowedKeys: Self.machineCreateKeys,
          requiredKeys: ["id", "displayName", "kind", "enabled", "ssh"]
        )
        let created = try await mutationOwner.create(MachineDescriptor(
          id: request.id,
          displayName: request.displayName,
          kind: request.kind,
          enabled: request.enabled,
          ssh: request.ssh.connection,
          codexSessionDirs: request.codexSessionDirs,
          claudeConfigDirs: request.claudeConfigDirs,
          includeDefaultCodexDir: request.includeDefaultCodexDir,
          includeDefaultClaudeDir: request.includeDefaultClaudeDir
        ))
        result = (created.0, created.1)
      case "PUT":
        let request: MachineReplaceRequest = try MachineRequestDecoder.decode(
          body,
          allowedKeys: Self.machineReplaceKeys,
          requiredKeys: ["displayName", "kind", "enabled", "ssh"]
        )
        let replaced = try await mutationOwner.replace(id: id!, with: MachineDescriptor(
          id: id!,
          displayName: request.displayName,
          kind: request.kind,
          enabled: request.enabled,
          ssh: request.ssh.connection,
          codexSessionDirs: request.codexSessionDirs,
          claudeConfigDirs: request.claudeConfigDirs,
          includeDefaultCodexDir: request.includeDefaultCodexDir,
          includeDefaultClaudeDir: request.includeDefaultClaudeDir
        ))
        result = (replaced.0, replaced.1)
      case "PATCH":
        let request: MachinePatchRequest = try MachineRequestDecoder.decode(
          body,
          allowedKeys: Self.machinePatchKeys
        )
        guard !request.isEmpty else { throw MachineBodyError.invalid }
        let patched = if id == "local" {
          try await patchLocal(request)
        } else {
          try await mutationOwner.patch(
            id: id!,
            displayName: request.displayName,
            enabled: request.enabled,
            ssh: request.ssh?.connection,
            codexSessionDirs: request.codexSessionDirs,
            claudeConfigDirs: request.claudeConfigDirs,
            includeDefaultCodexDir: request.includeDefaultCodexDir,
            includeDefaultClaudeDir: request.includeDefaultClaudeDir
          )
        }
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
    } catch DashboardDirectoryNameError.databaseUnavailable {
      return error(
        status: 503,
        code: "directory_name_unavailable",
        message: "Directory name storage is unavailable"
      )
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
          body.isEmpty || Self.isEmptyJSONObjectBody(body) else {
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

  /// Matches the previous `String(decoding:as:)` behavior: invalid UTF-8 never
  /// matches, and a leading UTF-8 BOM (which the failable initializer strips)
  /// is rejected because the lossy decoder preserved it as U+FEFF.
  private static func isEmptyJSONObjectBody(_ body: Data) -> Bool {
    guard !body.starts(with: [0xEF, 0xBB, 0xBF]) else { return false }
    return String(bytes: body, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) == "{}"
  }
}
