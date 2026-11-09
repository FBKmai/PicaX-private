import Foundation
import CryptoKit
import Security

nonisolated struct LanSRHTTPResponse: Sendable {
    let status: Int
    let data: Data
}

/// One bounded transfer per instance. Session configuration never inherits the
/// comic-source proxy, cookies or credentials; trust is an out-of-band cert pin.
nonisolated final class LanSRHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let server: LanSRServer
    private let maximum: Int
    private let destination: URL?
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<LanSRHTTPResponse, Error>?
    private var cancelled = false
    private var response: HTTPURLResponse?
    private var data = Data()
    private var received = 0
    private var file: FileHandle?
    private var failure: Error?

    init(server: LanSRServer, maximum: Int, destination: URL?) {
        self.server = server
        self.maximum = maximum
        self.destination = destination
    }

    func perform(_ request: URLRequest, upload: URL? = nil) async throws -> LanSRHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    completion.resume(throwing: CancellationError())
                    return
                }
                continuation = completion
                let config = URLSessionConfiguration.ephemeral
                config.allowsCellularAccess = false
                config.waitsForConnectivity = false
                config.connectionProxyDictionary = [:]
                config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 180
                config.tlsMinimumSupportedProtocolVersion = .TLSv12
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                let task: URLSessionTask
                if let upload { task = session.uploadTask(with: request, fromFile: upload) }
                else { task = session.dataTask(with: request) }
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == server.host,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard hash == server.certificateSHA256 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Trust exactly the pinned certificate, while still checking its SAN,
        // validity dates and TLS policy. Bonjour can never update this anchor.
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, server.host as CFString))
        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              http.url?.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == server.host,
              http.expectedContentLength <= Int64(maximum) else {
            failure = LanSRError.message("电脑响应超出允许大小或地址不匹配。")
            completionHandler(.cancel)
            return
        }
        self.response = http
        if let destination, (200...299).contains(http.statusCode) {
            guard http.mimeType == "image/png", !FileManager.default.fileExists(atPath: destination.path),
                  FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                failure = LanSRError.message("无法创建结果临时文件或响应不是 PNG。")
                completionHandler(.cancel)
                return
            }
            do { file = try FileHandle(forWritingTo: destination) }
            catch { failure = error; completionHandler(.cancel); return }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        received += chunk.count
        let limit = response.map { (200...299).contains($0.statusCode) ? maximum : min(maximum, 2048) } ?? 0
        guard received <= limit else {
            failure = LanSRError.message("电脑响应超过大小限制。")
            dataTask.cancel()
            return
        }
        do {
            if let file { try file.write(contentsOf: chunk) }
            else { data.append(chunk) }
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try file?.synchronize(); try file?.close() }
        catch { if failure == nil { failure = error } }
        file = nil
        lock.lock()
        let completion = continuation
        continuation = nil
        let wasCancelled = cancelled
        self.task = nil
        self.session = nil
        lock.unlock()
        defer { session.finishTasksAndInvalidate() }
        if wasCancelled { completion?.resume(throwing: CancellationError()) }
        else if let failure = failure ?? error { completion?.resume(throwing: failure) }
        else if let response { completion?.resume(returning: LanSRHTTPResponse(status: response.statusCode, data: data)) }
        else { completion?.resume(throwing: LanSRError.message("电脑没有返回 HTTP 响应。")) }
    }
}

nonisolated enum LanSRCredentialStore {
    static let service = "moye.PicaX.lan-super-resolution"
    static func load() throws -> LanSRCredential? {
        try SecureCodableStore.load(LanSRCredential.self, service: service, account: "paired-server")
    }
    static func save(_ value: LanSRCredential) throws {
        try SecureCodableStore.save(value, service: service, account: "paired-server")
    }
    static func delete() throws { try SecureCodableStore.delete(service: service, account: "paired-server") }
}

nonisolated struct LanSRClient: Sendable {
    let credential: LanSRCredential

    static func pair(_ payload: LanSRPairingPayload) async throws -> LanSRCredential {
        struct Reply: Decodable { let version: Int; let serverID: String; let token: String }
        let server = LanSRServer(host: payload.host, port: payload.port, serverID: payload.serverID,
                                 certificateSHA256: payload.certificateSHA256)
        let clientID = UUID().uuidString.lowercased()
        var request = URLRequest(url: try server.url(path: "/v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["clientID": clientID, "pairingSecret": payload.pairingSecret])
        let response = try await LanSRHTTPTransfer(server: server, maximum: 4096, destination: nil).perform(request)
        try check(response)
        let reply = try JSONDecoder().decode(Reply.self, from: response.data)
        guard reply.version == 1, reply.serverID == server.serverID, (32...128).contains(reply.token.utf8.count),
              reply.token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw LanSRError.message("电脑返回了无效配对信息。")
        }
        return LanSRCredential(server: server, clientID: clientID, token: reply.token)
    }

    static func check(_ response: LanSRHTTPResponse) throws {
        guard (200...299).contains(response.status) else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: response.data).error) ?? "请求未成功"
            throw LanSRError.http(response.status, String(message.prefix(512)))
        }
    }

    func send(path: String, method: String = "GET", body: Data? = nil, upload: URL? = nil,
              destination: URL? = nil, maximum: Int = LanSRContract.maximumJSON) async throws -> Data {
        guard LanSRContract.isUUID(credential.clientID), !credential.token.contains("\r"), !credential.token.contains("\n") else {
            throw LanSRError.message("配对凭据无效，请重新配对。")
        }
        var request = URLRequest(url: try credential.server.url(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue(upload == nil ? "application/json" : "image/png", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let response = try await LanSRHTTPTransfer(server: credential.server, maximum: maximum, destination: destination).perform(request, upload: upload)
        try Self.check(response)
        return response.data
    }

    func capabilities() async throws -> LanSRCapabilities {
        let value = try JSONDecoder().decode(LanSRCapabilities.self, from: await send(path: "/v1/capabilities"))
        guard value.version == 1, value.serverID == credential.server.serverID, value.defaultDeliveryScale == 2,
              value.models.count <= 4, Set(value.models.map(\.id)).count == value.models.count else {
            throw LanSRError.message("电脑能力响应无效。")
        }
        for model in value.models { try model.validate() }
        return value
    }
    func status(jobID: String) async throws -> LanSRJobStatus {
        try JSONDecoder().decode(LanSRJobStatus.self, from: await send(path: "/v1/jobs/\(jobID)"))
    }
    func command(jobID: String, action: String) async throws {
        guard ["commit", "cancel", "retry"].contains(action) else { throw LanSRError.message("未知任务操作。") }
        _ = try await send(path: "/v1/jobs/\(jobID)/\(action)", method: "POST")
    }
}
