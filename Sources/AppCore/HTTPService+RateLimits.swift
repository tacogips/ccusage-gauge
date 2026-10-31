import Foundation

func rateLimitsHTTPResponse(service: RateLimitUsageService?, method: String) async -> HTTPResponse {
  func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
    let body = (try? JSONSerialization.data(
      withJSONObject: ["error": ["code": code, "message": message]], options: [.sortedKeys]
    )) ?? Data()
    return HTTPResponse(status: status, contentType: "application/json", body: body)
  }
  guard method == "GET" else { return error(405, "method_not_allowed", "Method is not supported for this route") }
  guard let service else { return error(503, "rate_limits_unavailable", "Rate limit data is not available") }
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.outputFormatting = [.sortedKeys]
  guard let body = try? encoder.encode(await service.current()) else {
    return error(500, "encoding_failed", "Response encoding failed")
  }
  return HTTPResponse(status: 200, contentType: "application/json", body: body)
}
