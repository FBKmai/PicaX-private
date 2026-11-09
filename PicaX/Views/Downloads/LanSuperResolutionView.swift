#if os(iOS)
import SwiftUI

/// Used both from download multi-select and Settings. Closing this view never
/// owns/cancels a submitted job; the shared coordinator owns its lifetime.
struct LanSuperResolutionView: View {
    @ObservedObject private var coordinator = LanSuperResolutionCoordinator.shared
    @StateObject private var discovery = LanSRDiscovery()
    let records: [DownloadRecord]
    var onSubmitted: (() -> Void)?
    @State private var connectionText = ""
    @State private var pairingPreview: LanSRPairingPayload?
    @State private var showsPairConfirmation = false
    @State private var showsScanner = false
    @State private var showsUnpairConfirmation = false
    @State private var cancelJob: LanSRLocalJob?
    @State private var abandonJob: LanSRLocalJob?
    @State private var selectedModelID = ""
    @State private var deliveryScale = 2
    @State private var isConnecting = false
    @State private var didSubmit = false
    @State private var localError: String?

    init(records: [DownloadRecord] = [], onSubmitted: (() -> Void)? = nil) {
        self.records = records
        self.onSubmitted = onSubmitted
    }

    var body: some View {
        List {
            if let message = localError ?? coordinator.errorMessage {
                Section {
                    Text(message).foregroundStyle(.red)
                    Button("关闭提示") { localError = nil; coordinator.errorMessage = nil }
                }
            }
            connectionSection
            if coordinator.server == nil { discoverySection }
            pairingSection
            modelSection
            if !records.isEmpty { submissionSection }
            taskSection
            Section {
                Text("仅发送已下载漫画的规范化原图，不传送漫画源账号或 Cookie。结果另存到“下载 → 超分”，不覆盖原图。")
                Text("关闭页面不会取消电脑任务。手机只有在前台时传输；完整上传并提交后，电脑会独立处理。回到同一局域网并打开 App 后继续收取。")
                Text("电脑默认保留闲置任务 24 小时，可在启动参数中延长。请及时收取结果；电脑关闭、换 IP、撤销配对或任务过期会中断同步。")
            } header: { Text("使用说明") }
        }
        .picaxInsetGroupedListStyle()
        .navigationTitle("局域网电脑超分")
        .picaxNavigationBarTitleDisplayModeInline()
        .picaxHidesTabBar()
        .sheet(isPresented: $showsScanner) {
            LanSRQRCodeScanner { text in connectionText = text; previewPairing() }
        }
        .confirmationDialog("配对此电脑？", isPresented: $showsPairConfirmation, titleVisibility: .visible) {
            Button("确认配对") { connect() }
            Button("取消", role: .cancel) { pairingPreview = nil }
        } message: {
            if let payload = pairingPreview {
                Text("地址：\(payload.host):\(payload.port)\n证书 SHA-256：\(payload.certificateSHA256)\n仅确认来自你信任电脑上的连接信息。")
            }
        }
        .confirmationDialog("断开手机配对？", isPresented: $showsUnpairConfirmation, titleVisibility: .visible) {
            Button("断开配对", role: .destructive) {
                do { try coordinator.unpair() } catch { localError = error.localizedDescription }
            }
        } message: { Text("只删除本机凭据。如需撤销电脑保存的令牌，请使用电脑端 --revoke-client。") }
        .confirmationDialog("取消电脑任务？", isPresented: Binding(get: { cancelJob != nil }, set: { if !$0 { cancelJob = nil } }), titleVisibility: .visible) {
            Button("取消电脑任务", role: .destructive) {
                if let job = cancelJob { coordinator.cancel(jobID: job.id) }
                cancelJob = nil
            }
        } message: { Text("需要重新连接电脑才能确认取消；手机已经收取的页面会保留。") }
        .confirmationDialog("仅放弃手机上的任务跟踪？", isPresented: Binding(get: { abandonJob != nil }, set: { if !$0 { abandonJob = nil } }), titleVisibility: .visible) {
            Button("放弃本机跟踪", role: .destructive) {
                if let job = abandonJob {
                    do { try coordinator.abandon(jobID: job.id) } catch { localError = error.localizedDescription }
                }
                abandonJob = nil
            }
        } message: {
            Text("这不会取消电脑上的处理，也不会删除已收取的页面。仅在电脑丢失、任务过期或配对无法恢复时使用；放弃后无法从此任务继续收取。")
        }
        .onReceive(coordinator.$capabilities) { updateSelection($0) }
        .onChange(of: selectedModelID) { _ in
            if selectedModel?.deliveryScales.contains(deliveryScale) != true { deliveryScale = 2 }
        }
        .task {
            coordinator.resume()
            if coordinator.server != nil { await refresh() }
        }
        .onDisappear { discovery.stop() }
    }

    private var connectionSection: some View {
        Section {
            if let server = coordinator.server {
                LabeledContent("已配对电脑", value: server.address)
                Text("电脑 ID：\(server.serverID)").font(.caption).textSelection(.enabled)
                Text("证书 SHA-256：\(server.certificateSHA256)").font(.caption2).textSelection(.enabled)
                if isConnecting { ProgressView("连接中…") }
                Button("刷新电脑模型 / 重新连接") { Task { await refresh() } }.disabled(isConnecting)
                Button("断开配对", role: .destructive) { showsUnpairConfirmation = true }
                    .disabled(hasUnfinishedJobs || isConnecting)
            } else {
                Text("尚未配对。先在电脑启动 DesktopServer，再扫描或粘贴终端里的连接信息。")
            }
        } header: { Text("电脑连接") }
    }

    private var discoverySection: some View {
        Section {
            Button(discovery.isSearching ? "重新搜索附近电脑" : "搜索附近电脑") { discovery.start() }
            ForEach(discovery.names, id: \.self) { name in Label(name, systemImage: "desktopcomputer") }
            if !discovery.message.isEmpty { Text(discovery.message).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("局域网发现（未经认证）") }
        footer: { Text("发现服务只显示名称，不会自动信任证书或更换配对电脑。找不到时也可以直接扫码。") }
    }

    private var pairingSection: some View {
        Section {
            Button { showsScanner = true } label: { Label("扫描电脑配对二维码", systemImage: "qrcode.viewfinder") }
                .disabled(hasUnfinishedJobs || isConnecting)
            TextEditor(text: $connectionText)
                .frame(height: 90)
                .font(.caption.monospaced())
                .picaxDisablesTextAutocapitalization()
                .autocorrectionDisabled()
                .accessibilityLabel("电脑终端连接信息 JSON")
            Button("检查粘贴的连接信息并配对") { previewPairing() }
                .disabled(connectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasUnfinishedJobs || isConnecting)
        } header: { Text("扫码或粘贴配对") }
        footer: { Text("配对码为一次性，有效期 5 分钟。必须从你自己的电脑获取；不要分享配对码截图。现有任务完成或取消前不能更换电脑。") }
    }

    private var selectedModel: LanSRModelCapability? {
        coordinator.capabilities?.models.first { $0.id == selectedModelID && $0.ready }
    }
    private var hasUnfinishedJobs: Bool { coordinator.jobs.contains { !$0.finished } }

    private var modelSection: some View {
        Section {
            if let capabilities = coordinator.capabilities {
                let ready = capabilities.models.filter(\.ready)
                if ready.isEmpty {
                    Text("电脑尚无已就绪模型。请检查终端中的权重路径、许可确认和 CUDA 启动错误。")
                } else {
                    Picker("电脑模型", selection: $selectedModelID) {
                        ForEach(ready) { model in Text(model.name).tag(model.id) }
                    }
                    if let model = selectedModel {
                        Picker("回传倍率", selection: $deliveryScale) {
                            ForEach(model.deliveryScales, id: \.self) { scale in Text("\(scale)×").tag(scale) }
                        }
                        Text("原生 \(model.nativeScale)× · FP32 · 整页推理\n输入上限 \(model.maximumInputPixels) 像素（含对齐）；实际仍受显存、输出尺寸和超时限制。")
                            .font(.caption).foregroundStyle(.secondary)
                        if deliveryScale < model.nativeScale {
                            Text("先运行原生 \(model.nativeScale)× AI，再以 Lanczos 缩到 \(deliveryScale)× 回传；不是用普通放大代替 AI。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(capabilities.models.filter { !$0.ready }) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(model.name)：尚未就绪")
                        if let error = model.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } else { Text("配对并刷新后显示电脑实际配置的模型。") }
        } header: { Text("模型与回传尺寸") }
        footer: { Text("重模型不保证更好。请先用少量页比较文字、线条和网点。首版不会自动换模型、降低倍率或退回有已知接缝问题的分块模式。模型仅限 CC-BY-NC-4.0 非商业用途。") }
    }

    private var submissionSection: some View {
        Section {
            Text("已选择 \(records.count) 本已下载漫画")
            Button(didSubmit ? "已加入电脑任务" : "发送到电脑超分") {
                guard let model = selectedModel else { return }
                do {
                    try coordinator.enqueue(records: records, model: model, scale: deliveryScale)
                    didSubmit = true
                    onSubmitted?()
                } catch { localError = error.localizedDescription }
            }
            .disabled(didSubmit || selectedModel == nil || isConnecting)
        } header: { Text("手动提交") }
        footer: { Text("仅处理本次所选下载，不改变“下载后自动超分”的手机本地处理设置。准备和上传时请保持 App 在前台，直到任务显示“输入已完整提交”。") }
    }

    private var taskSection: some View {
        Section {
            if coordinator.jobs.isEmpty { Text("暂无电脑任务。请在下载库多选普通漫画后选择“电脑超分”。") }
            ForEach(coordinator.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.title).font(.headline)
                    Text("\(job.phase) · 已收取 \(job.imported.count)/\(job.pageCounts.reduce(0, +)) 页").font(.subheadline)
                    Text("\(job.model.name) · 回传 \(job.deliveryScale)×").font(.caption).foregroundStyle(.secondary)
                    if !job.message.isEmpty { Text(job.message).font(.caption).foregroundStyle(.secondary) }
                    if job.submitted && !job.finished { Text("电脑已接受完整输入，手机可以离开此页面。").font(.caption).foregroundStyle(.secondary) }
                    if job.finished {
                        Button("移除任务记录（保留下载）") {
                            do { try coordinator.removeFinished(jobID: job.id) } catch { localError = error.localizedDescription }
                        }
                    } else {
                        HStack {
                            Button("重试 / 收取") { coordinator.retry(jobID: job.id) }.disabled(job.cancelRequested)
                            Spacer()
                            Button("取消任务", role: .destructive) { cancelJob = job }.disabled(job.cancelRequested)
                        }
                        if job.phase == "等待重试" || job.cancelRequested {
                            Button("电脑无法恢复？放弃本机跟踪", role: .destructive) { abandonJob = job }
                                .font(.caption)
                        }
                    }
                }.padding(.vertical, 4)
            }
        } header: { Text("电脑任务") }
    }

    private func previewPairing() {
        do {
            pairingPreview = try LanSRPairingPayload.parse(connectionText.trimmingCharacters(in: .whitespacesAndNewlines))
            showsPairConfirmation = true
        } catch { localError = error.localizedDescription }
    }
    private func connect() {
        guard pairingPreview != nil else { return }
        // Freeze the exact reviewed payload; edits cannot substitute another host.
        guard let data = try? JSONEncoder().encode(pairingPreview), let text = String(data: data, encoding: .utf8) else { return }
        pairingPreview = nil
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do { try await coordinator.pair(text: text); connectionText = ""; localError = nil }
            catch { localError = error.localizedDescription }
        }
    }
    private func refresh() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        do { try await coordinator.refreshCapabilities(); coordinator.resume(); localError = nil }
        catch { localError = error.localizedDescription }
    }
    private func updateSelection(_ capabilities: LanSRCapabilities?) {
        guard let capabilities else { selectedModelID = ""; deliveryScale = 2; return }
        if !capabilities.models.contains(where: { $0.id == selectedModelID && $0.ready }) {
            selectedModelID = capabilities.models.first { $0.id == capabilities.defaultModelID && $0.ready }?.id
                ?? capabilities.models.first(where: \.ready)?.id ?? ""
            deliveryScale = 2
        }
    }
}
#endif
