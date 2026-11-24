import Foundation
import Synchronization

// ollama-swift 1.9.2 omits done_reason and remote model metadata from its responses.
nonisolated final class OllamaTransport: URLProtocol, @unchecked Sendable {
    static let host = URL(string: "http://127.0.0.1:11434")!

    private enum LoadState {
        case waiting
        case running(Task<Void, Never>)
        case stopped
    }

    private static let upstreamSession = URLSession(
        configuration: configuration(), delegate: OllamaRedirectDelegate(), delegateQueue: nil
    )
    private let loadState = Mutex<LoadState>(.waiting)

    static func makeSession() -> URLSession {
        let configuration = configuration()
        configuration.protocolClasses = [OllamaTransport.self]
        return URLSession(configuration: configuration)
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 120
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.scheme == host.scheme && url.host == host.host && url.port == host.port
            && (url.path == "/api/chat" || url.path == "/api/tags")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        loadState.withLock { state in
            guard case .waiting = state else { return }
            state = .running(Task { @Sendable [weak self] in await self?.load() })
        }
    }

    override func stopLoading() {
        let task = loadState.withLock { state -> Task<Void, Never>? in
            defer { state = .stopped }
            guard case .running(let task) = state else { return nil }
            return task
        }
        task?.cancel()
    }

    private func load() async {
        guard let client, !Task.isCancelled else { return }
        var request = self.request
        do {
            if request.url?.path == "/api/tags" {
                request.timeoutInterval = 5
                let (data, response) = try await Self.upstreamSession.data(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                let body = response.statusCode == 200 ? Self.filterLocalTextModels(data) : data
                client.urlProtocol(self, didLoad: body)
            } else {
                let (bytes, response) = try await Self.upstreamSession.bytes(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    let data = Data((line + "\n").utf8)
                    if Self.isTruncated(data, statusCode: response.statusCode) {
                        throw URLError(.cannotDecodeContentData)
                    }
                    client.urlProtocol(self, didLoad: data)
                }
            }
            try Task.checkCancellation()
            client.urlProtocolDidFinishLoading(self)
        } catch {
            guard !Task.isCancelled else { return }
            client.urlProtocol(self, didFailWithError: error)
        }
    }

    static func isTruncated(_ data: Data, statusCode: Int) -> Bool {
        guard (200..<300).contains(statusCode),
              let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return response["done_reason"] as? String == "length"
    }

    static func filterLocalTextModels(_ data: Data) -> Data {
        guard var response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = response["models"] as? [[String: Any]] else { return data }
        let localModels = models.filter { model in
            if let host = model["remote_host"] as? String, !host.isEmpty { return false }
            if let remote = model["remote_model"] as? String, !remote.isEmpty { return false }
            guard let name = model["name"] as? String else { return false }
            let identifier = name.lowercased()
            if identifier.hasSuffix(":cloud") || identifier.hasSuffix("-cloud") { return false }
            if let capabilities = model["capabilities"] as? [String], !capabilities.isEmpty {
                return capabilities.contains("completion")
            }
            return true
        }
        guard localModels.count != models.count else { return data }
        response["models"] = localModels
        return (try? JSONSerialization.data(withJSONObject: response)) ?? data
    }
}

private nonisolated final class OllamaRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
