import Combine
import Foundation

/// Owns remote work independently of any sheet. No background URLSession or
/// iOS background-time promise: only the PC keeps working after submission.
@MainActor
final class LanSuperResolutionCoordinator: ObservableObject {
    static let shared = LanSuperResolutionCoordinator(downloads: .shared)
    @Published private(set) var jobs: [LanSRLocalJob] = []
    @Published private(set) var server: LanSRServer?
    @Published private(set) var capabilities: LanSRCapabilities?
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?
    private let downloads: DownloadService
    private var runTask: Task<Void, Never>?
    private var foreground = true
    private var resumeAgain = false
    private var journalAvailable = true
    private var verifiedResults = Set<String>()
    private var retryAfter: [String: Date] = [:]

    init(downloads: DownloadService) {
        self.downloads = downloads
        do { jobs = try LanSRJournal.load() }
        catch { journalAvailable = false; errorMessage = error.localizedDescription }
        downloads.restoreLanReservations(Set(jobs.filter { !$0.finished }.map(\.sourceRecordID)))
        reloadConnection()
    }

    private func reloadConnection() {
        do { server = try LanSRConnectionStore.load()?.server }
        catch { errorMessage = "无法读取电脑地址：\(error.localizedDescription)" }
    }

    func connect(text: String) async throws {
        let address = try LanSRConnectionAddress.parse(text)
        let previous = try? LanSRConnectionStore.load()
        let (connection, capabilities) = try await LanSRClient.connect(address,
            clientID: previous?.clientID ?? UUID().uuidString.lowercased())
        guard !jobs.contains(where: { !$0.finished && $0.serverID != connection.server.serverID }) else {
            throw LanSRError.message("现有任务属于另一台电脑，请先完成或放弃跟踪；同一电脑换 IP 可以直接重连。")
        }
        try LanSRConnectionStore.save(connection)
        server = connection.server
        self.capabilities = capabilities
        errorMessage = nil
        runTask?.cancel()
        resumeAgain = runTask != nil
        resume()
    }
    func disconnect() throws {
        guard !jobs.contains(where: { !$0.finished }) else {
            throw LanSRError.message("断开前需完成或放弃现有电脑任务。")
        }
        LanSRConnectionStore.delete()
        server = nil
        capabilities = nil
    }
    func refreshCapabilities() async throws {
        guard let connection = try LanSRConnectionStore.load() else { throw LanSRError.message("请先输入电脑地址或扫码连接。") }
        server = connection.server
        capabilities = try await LanSRClient(connection: connection).capabilities()
        errorMessage = nil
    }

    func enqueue(records: [DownloadRecord], model: LanSRModelCapability, scale: Int, precision: String) throws {
        guard journalAvailable else { throw LanSRError.message("任务日志无法恢复，未创建新任务。请先保留日志并排查。") }
        guard let server, !records.isEmpty, model.ready, model.deliveryScales.contains(scale) else {
            throw LanSRError.message("请先连接电脑并选择已就绪的模型。")
        }
        try model.validate()
        guard model.selectablePrecisions.contains(precision) else {
            throw LanSRError.message("当前电脑模型不支持所选推理精度。")
        }
        // Older servers reject unknown spec keys, so retain their legacy wire shape.
        let requestedPrecision = model.supportedPrecisions == nil ? nil : precision
        let before = jobs
        var reserved: [String] = []
        do {
            for record in records {
                try downloads.reserveLanSource(record)
                reserved.append(record.id)
                let chapters = record.chapters.sorted { $0.index < $1.index }
                guard !chapters.isEmpty, chapters.count <= 4096,
                      Set(chapters.map(\.index)).count == chapters.count,
                      chapters.allSatisfy({ (0...9999).contains($0.index) && (1...4096).contains($0.pageCount) }),
                      chapters.reduce(0, { $0 + $1.pageCount }) <= 4096 else {
                    throw LanSRError.message("下载页数无效或超过单任务 4096 页限制。")
                }
                jobs.append(LanSRLocalJob(id: UUID().uuidString.lowercased(), serverID: server.serverID,
                    sourceRecordID: record.id, title: record.item.title, chapters: chapters.map(\.chapter),
                    sourceChapterIndexes: chapters.map(\.index), pageCounts: chapters.map(\.pageCount),
                    model: model, deliveryScale: scale, precision: requestedPrecision))
            }
            try LanSRJournal.save(jobs)
        } catch {
            jobs = before
            reserved.forEach { downloads.releaseLanSource($0) }
            throw error
        }
        resume()
    }

    func applicationDidBecomeActive() {
        foreground = true
        verifiedResults.removeAll()
        retryAfter.removeAll()
        reloadConnection()
        resume()
    }
    func applicationDidEnterBackground() {
        foreground = false
        runTask?.cancel()  // Deliberately no server-side cancel command.
    }
    func retry(jobID: String) {
        retryAfter.removeValue(forKey: jobID)
        do {
            try change(jobID) { job in
                job.retryRequested = true
                job.message = ""
            }
            resume()
        } catch { errorMessage = error.localizedDescription }
    }
    func cancel(jobID: String) {
        do {
            try change(jobID) { job in job.cancelRequested = true; job.phase = "等待取消确认" }
            // Interrupt a long upload now; the next loop sends the explicit
            // cancellation, including after a foreground/reconnect transition.
            runTask?.cancel()
            resumeAgain = true
            resume()
        } catch { errorMessage = error.localizedDescription }
    }
    /// Explicit recovery for an expired/lost PC. This does not claim remote
    /// cancellation and deliberately keeps every already imported download.
    func abandon(jobID: String) throws {
        runTask?.cancel()
        try finish(jobID, phase: "已放弃本机跟踪（未取消电脑）")
        resumeAgain = true
        resume()
    }
    func removeFinished(jobID: String) throws {
        guard jobs.first(where: { $0.id == jobID })?.finished == true else { return }
        let next = jobs.filter { $0.id != jobID }
        try LanSRJournal.save(next)
        jobs = next
    }
    private func job(_ id: String) throws -> LanSRLocalJob {
        guard let value = jobs.first(where: { $0.id == id }) else { throw LanSRError.message("本地任务已不存在。") }
        return value
    }
    private func change(_ id: String, _ update: (inout LanSRLocalJob) -> Void) throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { throw LanSRError.message("本地任务已不存在。") }
        var next = jobs
        update(&next[index])
        try LanSRJournal.save(next)
        jobs = next
    }

    func resume() {
        guard foreground, journalAvailable, jobs.contains(where: { !$0.finished }) else { return }
        guard runTask == nil else { resumeAgain = true; return }
        isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.runTask = nil
                self.isRunning = false
                if self.resumeAgain { self.resumeAgain = false; self.resume() }
            }
            do {
                guard let connection = try LanSRConnectionStore.load() else {
                    self.errorMessage = "等待连接电脑。"
                    return
                }
                let client = LanSRClient(connection: connection)
                while !Task.isCancelled, self.foreground {
                    let unfinished = self.jobs.filter { !$0.finished && ($0.phase != "部分失败" || $0.retryRequested || $0.cancelRequested) }
                    if unfinished.isEmpty { break }
                    let ids = unfinished.filter { (self.retryAfter[$0.id] ?? .distantPast) <= Date() || $0.cancelRequested }.map(\.id)
                    for id in ids {
                        try Task.checkCancellation()
                        do { try await self.synchronize(id, client: client) }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            try Task.checkCancellation()
                            self.retryAfter[id] = Date().addingTimeInterval(30)
                            try self.change(id) { job in job.phase = "等待重试"; job.message = error.localizedDescription }
                        }
                    }
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            } catch is CancellationError { /* A background transition pauses networking only. */ }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    private func prepare(_ id: String) async throws {
        var current = try job(id)
        guard let source = downloads.records.first(where: { $0.id == current.sourceRecordID }),
              downloads.task(for: source.item) == nil else {
            throw LanSRError.message("原下载已删除或正在修改，停止准备。")
        }
        for chapterIndex in current.chapters.indices {
            let images = await downloads.localChapterImages(for: source, chapterIndex: current.sourceChapterIndexes[chapterIndex])
            guard images.count == current.pageCounts[chapterIndex] else {
                throw LanSRError.message("原下载页数已改变；未发送新的或缺失的页面。")
            }
            for pageIndex in images.indices {
                try Task.checkCancellation()
                current = try job(id)
                if current.cancelRequested { throw CancellationError() }
                let pageID = LanSRContract.pageID(chapter: chapterIndex, page: pageIndex)
                if current.prepared.contains(where: { $0.id == pageID }) { continue }
                guard let sourceURL = images[pageIndex].url, sourceURL.picaxLocalFileURL != nil else {
                    throw LanSRError.message("原下载包含不可读取的本地页面。")
                }
                let temporary = try LanSRFiles.staging(jobID: id, pageID: pageID)
                defer { LanSRFiles.discard(temporary) }
                let page = try await LanSRFiles.export(sourceURL: sourceURL, destination: temporary,
                    chapter: chapterIndex, chapterTitle: current.chapters[chapterIndex].title, page: pageIndex,
                    model: current.model, scale: current.deliveryScale)
                try change(id) { job in
                    job.prepared.append(page)
                    job.sourceURLs[pageID] = sourceURL.picaxPortableDownloadURLString
                    job.phase = "准备原图"
                    job.message = "已校验 \(job.prepared.count)/\(job.pageCounts.reduce(0, +)) 页"
                }
            }
        }
        current = try job(id)
        let spec = LanSRJobSpec(version: 1, jobID: id, sourceRecordID: current.sourceRecordID, title: current.title,
            modelID: current.model.id, modelSHA256: current.model.sha256, nativeScale: current.model.nativeScale,
            deliveryScale: current.deliveryScale, mode: "fullPage", pages: current.prepared.sorted { $0.id < $1.id },
            precision: current.precision)
        guard try JSONEncoder().encode(spec).count <= 2 * 1024 * 1024 else { throw LanSRError.message("任务清单超过 2 MiB。") }
        try change(id) { $0.spec = spec }
    }

    private func synchronize(_ id: String, client: LanSRClient) async throws {
        var current = try job(id)
        guard current.serverID == client.connection.server.serverID else {
            throw LanSRError.message("等待连接此任务原先使用的电脑。")
        }
        if current.cancelRequested {
            if current.spec != nil {
                do { try await client.command(jobID: id, action: "cancel") }
                catch LanSRError.http(let status, _) where status == 404 { /* No remote job remains. */ }
            }
            try finish(id, phase: "已取消（保留已收取页）")
            return
        }
        if current.spec == nil { try await prepare(id); current = try job(id) }
        guard let spec = current.spec else { return }
        if current.targetCreated, !downloads.records.contains(where: { $0.superResolution?.jobID == id }) {
            throw LanSRError.message("此任务的超分下载记录已被删除；不会自动重建，请取消任务。")
        }
        _ = try downloads.ensureLanSuperResolutionTarget(job: current)
        if !current.targetCreated { try change(id) { $0.targetCreated = true }; current = try job(id) }
        var status: LanSRJobStatus
        do { status = try await client.status(jobID: id) }
        catch LanSRError.http(let code, _) where code == 404 && !current.submitted {
            let data = try await client.send(path: "/v1/jobs", method: "POST", body: JSONEncoder().encode(spec))
            status = try JSONDecoder().decode(LanSRJobStatus.self, from: data)
        }
        try status.validate(spec: spec)
        if status.state == "cancelled" { try finish(id, phase: "电脑任务已取消（保留已收取页）"); return }
        if current.retryRequested {
            if status.state == "partial" { try await client.command(jobID: id, action: "retry"); status = try await client.status(jobID: id) }
            try change(id) { $0.retryRequested = false }
        }
        try status.validate(spec: spec)
        let states = Dictionary(uniqueKeysWithValues: status.pages.map { ($0.id, $0) })
        if status.state == "uploading" {
            for page in spec.pages where states[page.id]?.state == "missing" {
                try Task.checkCancellation()
                current = try job(id)
                if current.cancelRequested { throw CancellationError() }
                guard let raw = current.sourceURLs[page.id], let sourceURL = URL.picaxResolved(from: raw) else {
                    throw LanSRError.message("上传来源映射丢失。")
                }
                let temporary = try LanSRFiles.staging(jobID: id, pageID: page.id)
                defer { LanSRFiles.discard(temporary) }
                let regenerated = try await LanSRFiles.export(sourceURL: sourceURL, destination: temporary,
                    chapter: page.chapterIndex, chapterTitle: page.chapterTitle, page: page.pageIndex,
                    model: current.model, scale: current.deliveryScale)
                guard regenerated.sha256 == page.sha256, regenerated.bytes == page.bytes,
                      regenerated.width == page.width, regenerated.height == page.height else {
                    throw LanSRError.message("原图或规范化结果已改变；未覆盖电脑上的任务输入，请取消并重新提交。")
                }
                try change(id) { $0.phase = "上传中"; $0.message = "第 \(page.chapterIndex + 1) 章 · 第 \(page.pageIndex + 1) 页" }
                _ = try await client.send(path: "/v1/jobs/\(id)/pages/\(page.id)", method: "PUT", upload: temporary)
            }
            try await client.command(jobID: id, action: "commit")
            try change(id) { $0.submitted = true; $0.phase = "电脑排队/处理"; $0.message = "输入已完整提交；手机可离开此页面。" }
            status = try await client.status(jobID: id)
        } else if !current.submitted { try change(id) { $0.submitted = true } }
        try status.validate(spec: spec)
        for remote in status.pages where remote.state == "succeeded" {
            try Task.checkCancellation()
            guard let page = spec.pages.first(where: { $0.id == remote.id }), let result = remote.result else {
                throw LanSRError.message("成功页面缺少结果元数据。")
            }
            try result.validate(spec: spec, page: page)
            current = try job(id)
            if current.cancelRequested { throw CancellationError() }
            let key = id + "/" + page.id + "/" + result.sha256
            if remote.acknowledged, verifiedResults.contains(key), current.imported[page.id] == result.sha256 { continue }
            let exists = try downloads.lanResultExists(job: current, page: page, result: result)
            if !exists {
                let temporary = try LanSRFiles.staging(jobID: id, pageID: page.id, result: true)
                LanSRFiles.discard(temporary)
                defer { LanSRFiles.discard(temporary) }
                try LanSRFiles.checkSpace(at: temporary.deletingLastPathComponent(), required: Int64(result.bytes) * 2)
                _ = try await client.send(path: "/v1/jobs/\(id)/pages/\(page.id)/result", destination: temporary, maximum: result.bytes)
                try downloads.importLanResult(job: current, page: page, result: result, file: temporary)
            } else {
                // Repairs SQLite counts after a file-write / database-write crash.
                try downloads.importLanResult(job: current, page: page, result: result, file: nil)
            }
            try change(id) { job in
                job.imported[page.id] = result.sha256
                job.results[page.id] = result
                job.phase = "收取中"
                job.message = "已安全保存 \(job.imported.count)/\(spec.pages.count) 页"
            }
            verifiedResults.insert(key)
            if !remote.acknowledged {
                _ = try await client.send(path: "/v1/jobs/\(id)/pages/\(page.id)/ack", method: "POST",
                    body: JSONSerialization.data(withJSONObject: ["sha256": result.sha256]))
            }
        }
        current = try job(id)
        if current.imported.count == spec.pages.count {
            try downloads.completeLanResult(job: current)
            try finish(id, phase: "完成")
        } else {
            let failed = status.pages.filter { $0.state == "failed" }
            try change(id) { job in
                // A single failed page must not stop collecting the remaining
                // pages while the PC is still processing this job.
                job.phase = status.state == "partial" ? "部分失败" : "电脑排队/处理"
                job.message = failed.first?.error ?? "电脑状态：\(status.state)；已收取 \(job.imported.count)/\(spec.pages.count) 页。"
            }
        }
    }
    private func finish(_ id: String, phase: String) throws {
        let sourceID = try job(id).sourceRecordID
        try change(id) { $0.finished = true; $0.phase = phase; $0.message = "" }
        downloads.releaseLanSource(sourceID)
    }
}
