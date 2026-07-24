import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single HTTP request issued by ``DashboardAPIClient``.
public struct DashboardHTTPRequest: Sendable {
  public let method: String
  public let url: URL
  public let headers: [String: String]
  public let body: Data?
  /// Overrides the transport's default request timeout. Synchronous
  /// server-side operations (machine refresh) can outlive the 60-second
  /// URLSession default.
  public let timeoutSeconds: TimeInterval?

  public init(method: String, url: URL, headers: [String: String], body: Data?, timeoutSeconds: TimeInterval? = nil) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeoutSeconds = timeoutSeconds
  }
}

/// The raw HTTP response observed by ``DashboardAPIClient``.
public struct DashboardHTTPResponse: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

/// An injectable HTTP transport. Production uses ``URLSessionDashboardTransport``;
/// tests provide deterministic stubs.
public protocol DashboardHTTPTransport: Sendable {
  func send(_ request: DashboardHTTPRequest) async throws -> DashboardHTTPResponse
}

/// The default `URLSession`-backed transport. Uses the async `data(for:)` API so
/// it compiles against both Foundation and Linux `FoundationNetworking`. The
/// default session is ephemeral: dashboard responses and cookies never touch the
/// shared on-disk cache, and every request observes live server state.
public struct URLSessionDashboardTransport: DashboardHTTPTransport {
  private let session: URLSession

  public init(session: URLSession = URLSession(configuration: .ephemeral)) {
    self.session = session
  }

  public func send(_ request: DashboardHTTPRequest) async throws -> DashboardHTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    if let timeout = request.timeoutSeconds { urlRequest.timeoutInterval = timeout }
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    urlRequest.httpBody = request.body
    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      if let name = key as? String, let text = value as? String {
        headers[name.lowercased()] = text
      }
    }
    return DashboardHTTPResponse(status: http.statusCode, headers: headers, body: data)
  }
}

/// A typed, loopback-only client for the running dashboard API. The host is
/// fixed to `127.0.0.1`; only the port is configurable. Reads never send the
/// mutation header, and machine creation sends the exact closed request shape
/// plus the required `Content-Type` and mutation headers.
public struct DashboardAPIClient: Sendable {
  /// The fixed loopback host. The client never targets a remote host.
  public static let host = "127.0.0.1"

  private let port: Int
  private let transport: DashboardHTTPTransport

  public init(port: Int, transport: DashboardHTTPTransport = URLSessionDashboardTransport()) {
    self.port = port
    self.transport = transport
  }

  // MARK: - Machines

  public func machinesList() async throws -> DashboardAPIResponse<MachinesResponse> {
    try await get(path: "/api/machines", query: [])
  }

  public func machineShow(id: String) async throws -> DashboardAPIResponse<MachineDescriptor> {
    try await get(path: "/api/machines/\(id)", query: [])
  }

  public func machineAdd(_ payload: MachineCreatePayload) async throws -> DashboardAPIResponse<MachineDescriptor> {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let body: Data
    do {
      body = try encoder.encode(payload)
    } catch {
      throw DashboardClientError.decoding(String(describing: error))
    }
    let response = try await perform(method: "POST", path: "/api/machines", query: [], body: body, mutation: true)
    return try decode(response)
  }

  public func machineTestConnection(id: String) async throws -> DashboardAPIResponse<MachineConnectionTestResponse> {
    let response = try await perform(
      method: "POST",
      path: "/api/machines/\(id)/test-connection",
      query: [],
      body: Data("{}".utf8),
      mutation: true
    )
    return try decode(response)
  }

  public func machineRefresh(id: String) async throws -> DashboardAPIResponse<RefreshResponse> {
    // The server collects synchronously before responding; a slow remote
    // host can legitimately exceed the 60-second URLSession default.
    let response = try await perform(
      method: "POST",
      path: "/api/machines/\(id)/refresh",
      query: [],
      body: Data("{}".utf8),
      mutation: true,
      timeoutSeconds: 300
    )
    return try decode(response)
  }

  // MARK: - Dashboard reads

  public func budget(machine: MachineSelector) async throws -> DashboardAPIResponse<ScopedResponse<BudgetResponse>> {
    try await get(path: "/api/budget", query: [machineItem(machine)])
  }

  public func recent(machine: MachineSelector, limit: Int) async throws -> DashboardAPIResponse<ScopedResponse<RecentResponse>> {
    try await get(path: "/api/recent", query: [machineItem(machine), URLQueryItem(name: "limit", value: String(limit))])
  }

  public func day(machine: MachineSelector, date: String) async throws -> DashboardAPIResponse<ScopedResponse<DayResponse>> {
    try await get(path: "/api/day", query: [machineItem(machine), URLQueryItem(name: "date", value: date)])
  }

  public func period(
    machine: MachineSelector,
    range: DashboardPeriodRange,
    start: String?,
    end: String?
  ) async throws -> DashboardAPIResponse<ScopedResponse<PeriodResponse>> {
    try await get(path: "/api/period", query: rangeQuery(machine: machine, range: range.rawValue, start: start, end: end))
  }

  public func metrics(
    machine: MachineSelector,
    range: DashboardAnalyticsRange,
    start: String?,
    end: String?
  ) async throws -> DashboardAPIResponse<ScopedResponse<DashboardMetricsResponse>> {
    try await get(path: "/api/metrics", query: rangeQuery(machine: machine, range: range.rawValue, start: start, end: end))
  }

  public func costSeries(
    machine: MachineSelector,
    range: DashboardAnalyticsRange,
    granularity: DashboardGranularity,
    start: String?,
    end: String?
  ) async throws -> DashboardAPIResponse<ScopedResponse<DashboardCostResponse>> {
    var query = rangeQuery(machine: machine, range: range.rawValue, start: start, end: end)
    query.append(URLQueryItem(name: "granularity", value: granularity.rawValue))
    return try await get(path: "/api/cost-series", query: query)
  }

  public func machineStatus(machine: MachineSelector) async throws -> DashboardAPIResponse<MachineStatusResponse> {
    try await get(path: "/api/machine-status", query: [machineItem(machine)])
  }

  public func loadStatus(machine: MachineSelector) async throws -> DashboardAPIResponse<MachineLoadStatusResponse> {
    try await get(path: "/api/load-status", query: [machineItem(machine)])
  }

  // MARK: - Request construction

  private func machineItem(_ machine: MachineSelector) -> URLQueryItem {
    URLQueryItem(name: "machine", value: machine.wireValue)
  }

  private func rangeQuery(machine: MachineSelector, range: String, start: String?, end: String?) -> [URLQueryItem] {
    var query = [machineItem(machine), URLQueryItem(name: "range", value: range)]
    if let start { query.append(URLQueryItem(name: "start", value: start)) }
    if let end { query.append(URLQueryItem(name: "end", value: end)) }
    return query
  }

  private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
    var components = URLComponents()
    components.scheme = "http"
    components.host = Self.host
    components.port = port
    components.path = path
    if !query.isEmpty { components.queryItems = query }
    guard let url = components.url else {
      throw DashboardClientError.decoding("Could not construct request URL for \(path)")
    }
    return url
  }

  private func get<Value: Decodable>(path: String, query: [URLQueryItem]) async throws -> DashboardAPIResponse<Value> {
    let response = try await perform(method: "GET", path: path, query: query, body: nil, mutation: false)
    return try decode(response)
  }

  private func perform(
    method: String,
    path: String,
    query: [URLQueryItem],
    body: Data?,
    mutation: Bool,
    timeoutSeconds: TimeInterval? = nil
  ) async throws -> DashboardHTTPResponse {
    let url = try makeURL(path: path, query: query)
    var headers: [String: String] = [:]
    if body != nil { headers["Content-Type"] = "application/json" }
    if mutation { headers["X-CCUsage-Gauge-Mutation"] = "1" }
    let request = DashboardHTTPRequest(method: method, url: url, headers: headers, body: body, timeoutSeconds: timeoutSeconds)
    let response: DashboardHTTPResponse
    do {
      response = try await transport.send(request)
    } catch let error as DashboardClientError {
      throw error
    } catch {
      throw DashboardClientError.unreachable(Self.sanitize(error))
    }
    guard (200...299).contains(response.status) else {
      throw DashboardClientError.api(Self.parseError(response))
    }
    return response
  }

  private func decode<Value: Decodable>(_ response: DashboardHTTPResponse) throws -> DashboardAPIResponse<Value> {
    do {
      let value = try Self.makeDecoder().decode(Value.self, from: response.body)
      return DashboardAPIResponse(raw: response.body, value: value)
    } catch {
      throw DashboardClientError.decoding(String(describing: error))
    }
  }

  static func parseError(_ response: DashboardHTTPResponse) -> DashboardAPIError {
    let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
    var code = "error"
    var message = "The dashboard API rejected the request"
    var fieldErrors: [String: String] = [:]
    if let detail = object?["error"] as? [String: Any] {
      code = detail["code"] as? String ?? code
      message = detail["message"] as? String ?? message
      if let fields = detail["fieldErrors"] as? [String: String] { fieldErrors = fields }
    } else if let errorCode = object?["error"] as? String {
      code = errorCode
      message = (object?["message"] as? String) ?? errorCode
    }
    let retry = (object?["refreshIntervalSeconds"] as? Int)
      ?? response.headers["retry-after"].flatMap { Int($0) }
    return DashboardAPIError(
      httpStatus: response.status,
      code: code,
      message: message,
      fieldErrors: fieldErrors,
      retryAfterSeconds: retry,
      rawBody: response.body
    )
  }

  /// A decoder that accepts both fractional-second and second-precision ISO 8601
  /// timestamps, covering the millisecond-precision status endpoints and the
  /// second-precision query endpoints.
  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: value) { return date }
      let plain = ISO8601DateFormatter()
      plain.formatOptions = [.withInternetDateTime]
      if let date = plain.date(from: value) { return date }
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(),
        debugDescription: "Invalid ISO 8601 date: \(value)"
      )
    }
    return decoder
  }

  private static func sanitize(_ error: Error) -> String {
    guard let urlError = error as? URLError else {
      return String(describing: type(of: error))
    }
    switch urlError.code {
    case .cannotConnectToHost: return "connection refused"
    case .timedOut: return "connection timed out"
    case .networkConnectionLost: return "connection lost"
    case .cannotFindHost: return "host not found"
    default: return "URLError \(urlError.code.rawValue)"
    }
  }
}
