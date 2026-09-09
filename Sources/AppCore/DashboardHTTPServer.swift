import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class DashboardHTTPServer: @unchecked Sendable {
  private let router: DashboardRouter
  private let acceptQueue = DispatchQueue(label: "ccusage-gauge.http.accept")
  private let clientQueue = DispatchQueue(label: "ccusage-gauge.http.client", attributes: .concurrent)
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var listenerGeneration: UInt64 = 0
  private var boundPort: Int = 0

  public init(router: DashboardRouter) { self.router = router }

  public func start(port: UInt16) throws {
    lock.lock()
    defer { lock.unlock() }
    guard listener < 0 else { return }
    guard port > 0 else { throw HTTPServerError.invalidPort }

    let descriptor = socket(AF_INET, Self.streamSocketType, 0)
    guard descriptor >= 0 else { throw HTTPServerError.socketFailure(errno) }
    var reuseAddress: Int32 = 1
    guard setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_REUSEADDR,
      &reuseAddress,
      socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
      Self.closeSocket(descriptor)
      throw HTTPServerError.socketFailure(errno)
    }

    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0, listen(descriptor, SOMAXCONN) == 0 else {
      let code = errno
      Self.closeSocket(descriptor)
      throw HTTPServerError.socketFailure(code)
    }

    listenerGeneration &+= 1
    let generation = listenerGeneration
    listener = descriptor
    boundPort = Int(port)
    acceptQueue.async { [weak self] in self?.acceptConnections(from: descriptor, generation: generation) }
    Task { await router.preloadSnapshot() }
  }

  public func stop() {
    lock.lock()
    let descriptor = listener
    listener = -1
    boundPort = 0
    listenerGeneration &+= 1
    lock.unlock()
    guard descriptor >= 0 else { return }
    Self.closeSocket(descriptor)
  }

  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return listener >= 0
  }

  private func acceptConnections(from descriptor: Int32, generation: UInt64) {
    while true {
      guard isCurrentListener(descriptor, generation: generation) else { return }
      let client = accept(descriptor, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        clearListener(descriptor, generation: generation)
        return
      }
      Self.configureClient(client)
      clientQueue.async { [weak self] in
        guard let self else {
          Self.closeSocket(client)
          return
        }
        self.receiveRequest(from: client)
      }
    }
  }

  private func isCurrentListener(_ descriptor: Int32, generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return listener == descriptor && listenerGeneration == generation
  }

  private func clearListener(_ descriptor: Int32, generation: UInt64) {
    lock.lock()
    let ownsListener = listener == descriptor && listenerGeneration == generation
    if ownsListener {
      listener = -1
      listenerGeneration &+= 1
    }
    lock.unlock()
    if ownsListener { Self.closeSocket(descriptor) }
  }

  private func receiveRequest(from descriptor: Int32) {
    guard let request = Self.readRequest(from: descriptor) else {
      Self.closeSocket(descriptor)
      return
    }
    let router = router
    let port = currentBoundPort()
    Task {
      let response = await router.route(
        target: request.target,
        method: request.method,
        headers: request.headers,
        body: request.body,
        listenerPort: port
      )
      Self.send(response, through: descriptor)
      Self.closeSocket(descriptor)
    }
  }

  private static func readRequest(from descriptor: Int32) -> ParsedHTTPRequest? {
    let headerTerminator = Data("\r\n\r\n".utf8)
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    var headerEnd: Range<Data.Index>?
    var expectedLength = 0
    while received.count < 81_920 {
      let count = buffer.withUnsafeMutableBytes { bytes in
        recv(descriptor, bytes.baseAddress, bytes.count, 0)
      }
      if count > 0 {
        received.append(contentsOf: buffer.prefix(count))
        if headerEnd == nil, let range = received.range(of: headerTerminator) {
          headerEnd = range
          guard range.lowerBound <= 16_384,
                let head = String(data: received[..<range.lowerBound], encoding: .utf8) else { return nil }
          expectedLength = contentLength(head)
          guard (0...65_536).contains(expectedLength) else { return nil }
        }
        if let headerEnd, received.count >= headerEnd.upperBound + expectedLength { break }
      } else if count == 0 {
        return nil
      } else if errno != EINTR {
        return nil
      }
    }
    guard let headerEnd,
          let head = String(data: received[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
    let lines = head.components(separatedBy: "\r\n")
    guard let first = lines.first else { return nil }
    let parts = first.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      headers[String(parts[0]).lowercased()] = String(parts[1]).trimmingCharacters(in: .whitespaces)
    }
    let bodyStart = headerEnd.upperBound
    let bodyEnd = min(received.count, bodyStart + expectedLength)
    return ParsedHTTPRequest(
      method: String(parts[0]),
      target: String(parts[1]),
      headers: headers,
      body: received.subdata(in: bodyStart..<bodyEnd)
    )
  }

  private static func contentLength(_ headers: String) -> Int {
    for line in headers.components(separatedBy: "\r\n").dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count == 2, parts[0].lowercased() == "content-length" {
        return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
      }
    }
    return 0
  }

  private static func send(_ response: HTTPResponse, through descriptor: Int32) {
    let reason: String = switch response.status {
    case 200: "OK"
    case 201: "Created"
    case 204: "No Content"
    case 207: "Multi-Status"
    case 400: "Bad Request"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 409: "Conflict"
    case 415: "Unsupported Media Type"
    case 422: "Unprocessable Content"
    case 503: "Service Unavailable"
    default: "Internal Server Error"
    }
    let extraHeaders = response.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
    let header = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\(extraHeaders)\r\n"
    var data = Data(header.utf8)
    data.append(response.body)
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = systemSend(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
        } else if count < 0, errno == EINTR {
          continue
        } else {
          return
        }
      }
    }
  }

  private static func configureClient(_ descriptor: Int32) {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size)
    )
    _ = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_SNDTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size)
    )
    #if canImport(Darwin)
    var noSigPipe: Int32 = 1
    _ = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSigPipe,
      socklen_t(MemoryLayout<Int32>.size)
    )
    #endif
  }

  private static func closeSocket(_ descriptor: Int32) {
    guard descriptor >= 0 else { return }
    _ = systemShutdown(descriptor)
    systemClose(descriptor)
  }

  private func currentBoundPort() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return boundPort
  }

  private static var streamSocketType: Int32 {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
  }
}

private struct ParsedHTTPRequest {
  let method: String
  let target: String
  let headers: [String: String]
  let body: Data
}

public enum HTTPServerError: Error, Sendable {
  case invalidPort
  case socketFailure(Int32)
}

private var shutdownBoth: Int32 {
  #if canImport(Glibc)
  Int32(SHUT_RDWR)
  #else
  SHUT_RDWR
  #endif
}

private func systemSend(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
  #if canImport(Glibc)
  Glibc.send(descriptor, buffer, count, Int32(MSG_NOSIGNAL))
  #else
  Darwin.send(descriptor, buffer, count, 0)
  #endif
}

private func systemShutdown(_ descriptor: Int32) -> Int32 {
  #if canImport(Glibc)
  Glibc.shutdown(descriptor, shutdownBoth)
  #else
  Darwin.shutdown(descriptor, shutdownBoth)
  #endif
}

private func systemClose(_ descriptor: Int32) {
  #if canImport(Glibc)
  _ = Glibc.close(descriptor)
  #else
  _ = Darwin.close(descriptor)
  #endif
}
