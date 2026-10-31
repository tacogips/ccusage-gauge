import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class RefuseRateLimitRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
public struct URLSessionRateLimitTransport: RateLimitHTTPTransport {
  public init() {}
  public func get(url: URL, headers: [String: String], timeoutSeconds: TimeInterval) async throws -> RateLimitHTTPResponse {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration, delegate: RefuseRateLimitRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
    request.httpMethod = "GET"
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    do {
      let (body, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else { throw RateLimitErrorCode.networkError }
      return RateLimitHTTPResponse(status: response.statusCode, body: body)
    } catch let error as URLError where error.code == .timedOut {
      throw RateLimitErrorCode.timeout
    } catch { throw RateLimitErrorCode.networkError }
  }
}
