import Foundation

nonisolated struct LanSRHTTPResponse: Sendable {
    let status: Int
    let data: Data
}

/// One bounded LAN transfer per instance. Does not inherit the comic-source
/// proxy, cookies or credentials. The local server uses plain HTTP, without TLS
/// certificates or authentication challenges.
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
        else if let failure { completion?.resume(throwing: failure) }
        else if let error { completion?.resume(throwing: Self.connectionError(error, address: server.address)) }
        else if let response { completion?.resume(returning: LanSRHTTPResponse(status: response.statusCode, data: data)) }
        else { completion?.resume(throwing: LanSRError.message("电脑没有返回 HTTP 响应。")) }
    }
    static func connectionError(_ error: Error, address: String) -> Error {
        guard let error = error as? URLError else { return error }
        let reason: String
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost:
            reason = "无法连接，请确认电脑服务已启动、地址正确，并允许局域网访问该端口。"
        case .timedOut:
            reason = "连接超时，请确认手机和电脑在同一局域网，且未被 VPN 或防火墙拦截。"
        case .notConnectedToInternet, .dataNotAllowed:
            reason = "局域网不可用，请连接 Wi-Fi 并允许 PicaX 的本地网络权限。"
        case .cancelled:
            reason = "连接已中断，请重试。"
        default:
            reason = error.localizedDescription
        }
        return LanSRError.message("电脑 \(address)：\(reason)")
    }
}

/// Only an address and a nonsecret job-grouping ID are saved, not credentials.
nonisolated enum LanSRConnectionStore {
    private static let key = "moye.PicaX.lan-super-resolution.connection"
    static func load() throws -> LanSRConnection? {
        if let data = UserDefaults.standard.data(forKey: key) {
            return try JSONDecoder().decode(LanSRConnection.self, from: data)
        }
        // Old installs can keep their job-grouping ID. Token/pin fields are
        // ignored, and an unavailable old Keychain never blocks a new connection.
        if !UserDefaults.standard.bool(forKey: key + ".ignoreLegacy"),
           let legacy = try? SecureCodableStore.load(LanSRConnection.self,
            service: "moye.PicaX.lan-super-resolution", account: "paired-server") {
            try save(legacy)
            return legacy
        }
        return nil
    }
    static func save(_ value: LanSRConnection) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
    }
    static func delete() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.set(true, forKey: key + ".ignoreLegacy")
    }
}

nonisolated struct LanSRClient: Sendable {
    let connection: LanSRConnection

    static func connect(_ address: LanSRConnectionAddress, clientID: String) async throws -> (LanSRConnection, LanSRCapabilities) {
        let initial = LanSRConnection(server: LanSRServer(host: address.host, port: address.port, serverID: ""), clientID: clientID)
        let capabilities = try await Self(connection: initial).capabilities()
        let server = LanSRServer(host: address.host, port: address.port, serverID: capabilities.serverID)
        return (LanSRConnection(server: server, clientID: clientID), capabilities)
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
        var request = URLRequest(url: try connection.server.url(path: path))
        request.httpMethod = method
        request.setValue(connection.clientID, forHTTPHeaderField: "X-PicaX-Client-ID")
        request.setValue(upload == nil ? "application/json" : "image/png", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let response = try await LanSRHTTPTransfer(server: connection.server, maximum: maximum, destination: destination).perform(request, upload: upload)
        try Self.check(response)
        return response.data
    }

    func capabilities() async throws -> LanSRCapabilities {
        let value = try JSONDecoder().decode(LanSRCapabilities.self, from: await send(path: "/v1/capabilities"))
        guard value.version == 1, LanSRContract.isUUID(value.serverID),
              (connection.server.serverID.isEmpty || value.serverID == connection.server.serverID),
              value.defaultDeliveryScale == 2,
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
