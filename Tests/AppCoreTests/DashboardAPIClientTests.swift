import Foundation
import Testing
@testable import AppCore

private final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DashboardHTTPRequest] = []

  func record(_ request: DashboardHTTPRequest) {
    lock.lock(); defer { lock.unlock() }
    storage.append(request)
  }

  var requests: [DashboardHTTPRequest] {
    lock.lock(); defer { lock.unlock() }
    return storage
  }
}

private struct StubTransport: DashboardHTTPTransport {
  let recorder: RequestRecorder
  let outcome: Result<DashboardHTTPResponse, StubTransportError>

  func send(_ request: DashboardHTTPRequest) async throws -> DashboardHTTPResponse {
    recorder.record(request)
    return try outcome.get()
  }
}

private enum StubTransportError: Error { case failed }

private func client(
  recorder: RequestRecorder,
  status: Int = 200,
  headers: [String: String] = [:],
  body: String
) -> DashboardAPIClient {
  let response = DashboardHTTPResponse(status: status, headers: headers, body: Data(body.utf8))
  return DashboardAPIClient(port: 18_081, transport: StubTransport(recorder: recorder, outcome: .success(response)))
}

@Suite("DashboardAPIClientTests")
struct DashboardAPIClientTests {
  @Test func readsTargetLoopbackWithQueryAndNoMutationHeader() async throws {
    let recorder = RequestRecorder()
    let api = client(recorder: recorder, body: #"{"series":[],"totalUSD":0,"scope":{"requested":"local","includedMachineIds":["local"],"staleMachineIds":[],"unavailableMachineIds":[],"generatedAt":null}}"#)
    _ = try await api.recent(machine: .local, limit: 10)
    let request = try #require(recorder.requests.first)
    #expect(request.method == "GET")
    #expect(request.url.scheme == "http")
    #expect(request.url.host == "127.0.0.1")
    #expect(request.url.port == 18_081)
    #expect(request.url.path == "/api/recent")
    let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "machine", value: "local")))
    #expect(query.contains(URLQueryItem(name: "limit", value: "10")))
    #expect(request.headers["X-CCUsage-Gauge-Mutation"] == nil)
    #expect(request.body == nil)
  }

  @Test func machineAddSendsExactClosedShapeAndMutationHeaders() async throws {
    let recorder = RequestRecorder()
    let responseBody = #"""
    {"id":"remote","displayName":"Remote","kind":"ssh","enabled":true,
     "ssh":{"host":"example.com","port":22,"user":"ccusage","extraOptions":[],"remoteCcusagePath":"ccusage"}}
    """#
    let api = client(recorder: recorder, status: 201, body: responseBody)
    let payload = MachineCreatePayload(
      id: "remote",
      displayName: "Remote",
      enabled: true,
      ssh: MachineCreatePayload.SSHPayload(
        host: "example.com",
        port: 22,
        user: "ccusage",
        identityFile: nil,
        extraOptions: [],
        remoteCcusagePath: "ccusage"
      )
    )
    _ = try await api.machineAdd(payload)
    let request = try #require(recorder.requests.first)
    #expect(request.method == "POST")
    #expect(request.url.path == "/api/machines")
    #expect(request.headers["Content-Type"] == "application/json")
    #expect(request.headers["X-CCUsage-Gauge-Mutation"] == "1")
    let body = try #require(request.body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(object.keys) == ["id", "displayName", "kind", "enabled", "ssh"])
    #expect(object["kind"] as? String == "ssh")
    let ssh = try #require(object["ssh"] as? [String: Any])
    // identityFile is omitted (never null) when no identity file is provided.
    #expect(Set(ssh.keys) == ["host", "port", "user", "extraOptions", "remoteCcusagePath"])
  }

  @Test func machineAddEncodesIdentityFilePathWhenPresent() async throws {
    let recorder = RequestRecorder()
    let body = #"""
    {"id":"remote","displayName":"Remote","kind":"ssh","enabled":true,
     "ssh":{"host":"example.com","port":2200,"user":"ccusage",
            "identityFile":"/tmp/ccusage-gauge-test-id","extraOptions":["-4"],
            "remoteCcusagePath":"/usr/local/bin/ccusage"}}
    """#
    let api = client(recorder: recorder, status: 201, body: body)
    let payload = MachineCreatePayload(
      id: "remote",
      displayName: "Remote",
      enabled: true,
      ssh: MachineCreatePayload.SSHPayload(
        host: "example.com",
        port: 2200,
        user: "ccusage",
        identityFile: "/tmp/ccusage-gauge-test-id",
        extraOptions: ["-4"],
        remoteCcusagePath: "/usr/local/bin/ccusage"
      )
    )
    _ = try await api.machineAdd(payload)
    let request = try #require(recorder.requests.first)
    let object = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: Any]
    let ssh = object?["ssh"] as? [String: Any]
    #expect(ssh?["identityFile"] as? String == "/tmp/ccusage-gauge-test-id")
    #expect(ssh?["port"] as? Int == 2200)
  }

  @Test func preservesRawBodyAndDecodesScope() async throws {
    let recorder = RequestRecorder()
    let body = #"""
    {"activeBoundaryAt":"2026-07-21T00:00:00Z","budgetUSD":100,"overageUSD":0,
     "refreshIntervalSeconds":20,"remainingUSD":40,"resetCycle":"daily","spentUSD":60,
     "usagePercentage":60,"visualFraction":0.6,
     "scope":{"generatedAt":"2026-07-21T01:00:00Z","includedMachineIds":["local"],
              "requested":"all","staleMachineIds":["remote"],"unavailableMachineIds":[]}}
    """#
    let api = client(recorder: recorder, body: body)
    let response = try await api.budget(machine: .all)
    #expect(response.raw == Data(body.utf8))
    #expect(response.value.body.spentUSD == Decimal(60))
    #expect(response.value.scope.requested == "all")
    #expect(response.value.scope.includedMachineIds == ["local"])
    #expect(response.value.scope.staleMachineIds == ["remote"])
  }

  @Test func decodesFractionalSecondStatusTimestamps() async throws {
    let recorder = RequestRecorder()
    let body = #"""
    {"requested":"local","generatedAt":"2026-07-21T01:02:03.456Z",
     "machines":[{"id":"local","displayName":"Local","kind":"local","enabled":true,
                  "collectionState":"healthy","snapshotAvailable":true,"collectionInProgress":false,
                  "stale":false,"coverageStart":"2026-07-01","snapshotGeneratedAt":"2026-07-21T01:02:03.456Z",
                  "lastAttemptAt":null,"lastSuccessAt":null,"lastErrorAt":null,"lastError":null,
                  "refreshIntervalSeconds":20}]}
    """#
    let api = client(recorder: recorder, body: body)
    let response = try await api.machineStatus(machine: .local)
    #expect(response.value.machines.first?.collectionState == .healthy)
    #expect(response.value.generatedAt.timeIntervalSince1970 > 0)
  }

  @Test func mapsObjectErrorBodyToStructuredError() async throws {
    let recorder = RequestRecorder()
    let body = #"{"error":{"code":"invalid_machine","message":"Machine validation failed","fieldErrors":{"ssh.port":"must be in 1...65535"}}}"#
    let response = DashboardHTTPResponse(status: 422, body: Data(body.utf8))
    let api = DashboardAPIClient(port: 18_081, transport: StubTransport(recorder: recorder, outcome: .success(response)))
    await #expect(throws: DashboardClientError.self) { _ = try await api.machinesList() }
    do {
      _ = try await api.machinesList()
    } catch let DashboardClientError.api(error) {
      #expect(error.httpStatus == 422)
      #expect(error.code == "invalid_machine")
      #expect(error.fieldErrors["ssh.port"] == "must be in 1...65535")
      #expect(error.isServerError == false)
    }
  }

  @Test func mapsStringErrorBodyAndRetryAfterHeader() async throws {
    let recorder = RequestRecorder()
    let body = #"{"error":"snapshot_unavailable","machine":"remote","refreshIntervalSeconds":30}"#
    let response = DashboardHTTPResponse(status: 503, headers: ["retry-after": "30"], body: Data(body.utf8))
    let api = DashboardAPIClient(port: 18_081, transport: StubTransport(recorder: recorder, outcome: .success(response)))
    do {
      _ = try await api.budget(machine: .machine("remote"))
      Issue.record("Expected an API error")
    } catch let DashboardClientError.api(error) {
      #expect(error.code == "snapshot_unavailable")
      #expect(error.retryAfterSeconds == 30)
      #expect(error.isServerError)
    }
  }

  @Test func transportFailureBecomesUnreachable() async throws {
    let recorder = RequestRecorder()
    let api = DashboardAPIClient(
      port: 18_081,
      transport: StubTransport(recorder: recorder, outcome: .failure(.failed))
    )
    do {
      _ = try await api.machinesList()
      Issue.record("Expected an unreachable error")
    } catch let DashboardClientError.unreachable(detail) {
      #expect(!detail.isEmpty)
    }
  }
}
