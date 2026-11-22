// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// Answers requests to a test's own host, so tests can run in parallel. Records what was sent.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Sent: Sendable {
        let request: URLRequest
        let body: Data
    }

    enum Reply: Sendable {
        case status(Int, headers: [String: String] = [:], body: String = #"{"received":true,"verified":false}"#)
        case failure
        case waitForCancellation
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: @Sendable (Sent) -> Reply] = [:]
    nonisolated(unsafe) private static var sent: [String: [Sent]] = [:]
    nonisolated(unsafe) private static var cancelled: Set<String> = []

    /// A fresh host whose requests `reply` answers.
    static func host(_ reply: @escaping @Sendable (Sent) -> Reply) -> String {
        let host = "\(UUID().uuidString.lowercased()).test"
        lock.withLock { replies[host] = reply }
        return host
    }

    static func setReply(_ host: String, _ reply: @escaping @Sendable (Sent) -> Reply) {
        lock.withLock { replies[host] = reply }
    }

    static func requests(to host: String) -> [Sent] { lock.withLock { sent[host] ?? [] } }
    static func wasCancelled(_ host: String) -> Bool { lock.withLock { cancelled.contains(host) } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let host = request.url?.host() ?? ""
        let item = Sent(request: request, body: body)
        let reply = Self.lock.withLock { () -> (@Sendable (Sent) -> Reply)? in
            Self.sent[host, default: []].append(item)
            return Self.replies[host]
        }
        switch reply?(item) ?? .failure {
        case .waitForCancellation:
            break
        case .failure:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .status(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        if let host = request.url?.host() { _ = Self.lock.withLock { Self.cancelled.insert(host) } }
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
