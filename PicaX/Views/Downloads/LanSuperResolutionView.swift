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
    @State private var scannedConnection: String?
    @State private var showsScanner = false
    @State private var showsDisconnectConfirmation = false
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
            addressSection
            modelSection
            if !records.isEmpty { submissionSection }
            taskSection
            Section {
                Text("仅发送已下载漫画的规范化原图，不传送漫画源账号或 Cookie。结果另存到“下载 → 超分”，不覆盖原图。")
                Text("关闭页面不会取消电脑任务。手机只有在前台时传输；完整上传并提交后，电脑会独立处理。回到同一局域网并打开 App 后继续收取。")
                Text("电脑默认保留闲置任务 24 小时，可在启动参数中延长。请及时收取结果；电脑关闭或任务过期会中断同步，换 IP 后输入新地址即可重连。")
            } header: { Text("使用说明") }
        }
        .picaxInsetGroupedListStyle()
        .navigationTitle("局域网电脑超分")
        .picaxNavigationBarTitleDisplayModeInline()
        .picaxHidesTabBar()
        .sheet(isPresented: $showsScanner, onDismiss: {
            // Wait for the scanner sheet to close before updating connection UI.
            guard let text = scannedConnection else { return }
            scannedConnection = nil
            connectionText = text
            connect()
        }) {
            LanSRQRCodeScanner { text in scannedConnection = text }
        }
        .confirmationDialog("断开电脑连接？", isPresented: $showsDisconnectConfirmation, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) {
                do { try coordinator.disconnect() } catch { localError = error.localizedDescription }
            }
        } message: { Text("只删除本机保存的电脑地址，不删除已收取的结果。") }
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
            Text("这不会取消电脑上的处理，也不会删除已收取的页面。仅在电脑丢失、任务过期或连接无法恢复时使用；放弃后无法从此任务继续收取。")
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
                LabeledContent("已连接电脑", value: "http://\(server.address)")
                Button("刷新电脑模型 / 重新连接") { Task { await refresh() } }.disabled(isConnecting)
                Button("断开连接", role: .destructive) { showsDisconnectConfirmation = true }
                    .disabled(hasUnfinishedJobs || isConnecting)
            } else {
                Text("先启动电脑服务，再输入电脑 IP 或扫描二维码即可连接。")
            }
            if isConnecting { ProgressView("正在连接电脑…") }
        } header: { Text("电脑连接") }
    }

    private var discoverySection: some View {
        Section {
            Button(discovery.isSearching ? "重新搜索附近电脑" : "搜索附近电脑") { discovery.start() }
            ForEach(discovery.names, id: \.self) { name in Label(name, systemImage: "desktopcomputer") }
            if !discovery.message.isEmpty { Text(discovery.message).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("局域网发现") }
        footer: { Text("扫描电脑二维码或直接输入 IP 地址连接。") }
    }

    private var addressSection: some View {
        Section {
            Button { scannedConnection = nil; showsScanner = true } label: { Label("扫描电脑连接二维码", systemImage: "qrcode.viewfinder") }
                .disabled(isConnecting)
            TextField("例如 192.168.5.8:18443", text: $connectionText)
                .font(.callout.monospaced())
                .picaxDisablesTextAutocapitalization()
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityLabel("电脑 IP 地址或连接信息")
                .disabled(isConnecting)
            Button("连接电脑") { connect() }
                .disabled(connectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
        } header: { Text("输入地址或扫码连接") }
        footer: { Text("无需配对、口令或证书，二维码不过期。使用局域网 HTTP 直连，不加密；只在自己的可信局域网使用，不要映射到公网。") }
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
            } else { Text("连接后显示电脑实际配置的模型。") }
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

    private func connect() {
        guard !isConnecting else { return }
        let text = connectionText
        localError = nil
        coordinator.errorMessage = nil
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do { try await coordinator.connect(text: text); connectionText = ""; localError = nil }
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
