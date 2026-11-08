import Combine
import CoreGraphics
import Foundation
import SwiftUI

private enum ReaderComparisonMode: String, CaseIterable, Identifiable {
    case original, traditional, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "原图"
        case .traditional: "传统滤镜"
        case .ai: "AI 试处理"
        }
    }
}

private nonisolated struct ReaderTraditionalResult: @unchecked Sendable {
    let image: CGImage?
}

@MainActor
private final class ReaderImageCompareModel: ObservableObject {
    @Published private(set) var source: ReaderImageSource?
    @Published private(set) var traditionalImage: CGImage?
    @Published private(set) var aiResult: SuperResolutionResult?
    @Published private(set) var isLoading = false
    @Published private(set) var isProcessing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var sourceMessage = "正在读取原图…"
    @Published private(set) var trialMessage = "尚未处理；原图未修改。"

    private var loadID = UUID()
    private var trialID = UUID()
    private var trialTask: Task<Void, Never>?

    func load(request: ReaderImageCompareRequest, pixelWidth: Int?) async {
        release()
        let id = UUID()
        loadID = id
        isLoading = true
        sourceMessage = "正在读取原图…"
        defer { if loadID == id { isLoading = false } }
        do {
            guard let url = URL.picaxResolved(from: request.urlString) else { throw URLError(.badURL) }
            let snapshot = try await ReaderImageSourceLoader.load(url: url)
            try Task.checkCancellation()
            guard loadID == id else { return }
            source = snapshot
            sourceMessage = "原图 \(snapshot.dimensions.label) px；两侧使用同一源图快照。"
            let enhancement = request.enhancement
            if enhancement.isEnabled {
                let task = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try ReaderTraditionalResult(image: ReaderImageSourceLoader.traditionalImage(
                        source: snapshot, targetPixelWidth: pixelWidth, enhancement: enhancement
                    ))
                }
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard loadID == id else { return }
                traditionalImage = result.image
            }
        } catch where error.isTaskCancellation {
            return
        } catch {
            guard loadID == id else { return }
            sourceMessage = "未加载可用原图：\(error.localizedDescription)"
        }
    }

    func start(
        preset: SuperResolutionPreset,
        mode: SuperResolutionInferenceMode,
        computeUnit: SuperResolutionComputeUnit
    ) {
        guard let source, !isProcessing else { return }
        clearResult()
        let id = UUID()
        trialID = id
        progress = 0
        isProcessing = true
        trialMessage = "正在核对模型、推理模式与页级预算…"
        trialTask = Task { [weak self] in
            do {
                let result = try await SuperResolutionService.shared.process(
                    source: source, preset: preset, mode: mode, computeUnit: computeUnit
                ) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.trialID == id, self.isProcessing else { return }
                        self.progress = min(max(value, 0), 1)
                        self.trialMessage = "前台试处理 \(Int(self.progress * 100))%"
                    }
                }
                guard let self, self.trialID == id, !Task.isCancelled,
                      self.source?.fingerprint == result.sourceFingerprint else {
                    Self.removeTrialFile(result.outputURL)
                    return
                }
                self.aiResult = result
                self.progress = 1
                self.trialMessage = "本页 AI 已完成；仅用于此次对比，未替换下载原图。"
                self.isProcessing = false
                self.trialTask = nil
            } catch {
                guard let self, self.trialID == id else { return }
                self.isProcessing = false
                self.trialTask = nil
                self.trialMessage = error.isTaskCancellation
                    ? "已取消；继续显示原图，未标记为 AI 完成。"
                    : "未完成 AI：\(error.localizedDescription) 原图未修改。"
            }
        }
    }

    func cancel() {
        guard isProcessing else { return }
        trialTask?.cancel()
        trialMessage = "取消中；当前 Core ML 推理调用返回后停止并清理，未完成不会标记为成功。"
    }

    func changePreset() {
        trialTask?.cancel()
        trialTask = nil
        trialID = UUID()
        isProcessing = false
        progress = 0
        clearResult()
        trialMessage = "预设或推理选项已更换；尚未处理，不使用上一结果。"
    }

    func release() {
        loadID = UUID()
        changePreset()
        source = nil
        traditionalImage = nil
        isLoading = false
        trialMessage = "尚未处理；原图未修改。"
    }

    private func clearResult() {
        if let result = aiResult { Self.removeTrialFile(result.outputURL) }
        aiResult = nil
    }

    private static func removeTrialFile(_ url: URL) {
        // Only an app-generated, unique trial directory is ever removed.
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().lastPathComponent == "PicaX-SuperResolutionTrials" else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
    }
}

/// Foreground, current-page experiment. Ordinary reader decode/preload never
/// invokes this service. Leaving the view or backgrounding cancels the trial.
struct ReaderImageCompareView: View {
    let request: ReaderImageCompareRequest
    let targetPixelWidth: Int?
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ReaderImageCompareModel()
    @State private var mode: ReaderComparisonMode = .ai
    @State private var preset: SuperResolutionPreset = .manga
    @State private var inferenceMode: SuperResolutionInferenceMode = .automatic
    @State private var computeUnit: SuperResolutionComputeUnit = .all
    @State private var showsOriginal = false

    var body: some View {
        VStack(spacing: 10) {
            header
            Picker("对比模式", selection: $mode) {
                ForEach(ReaderComparisonMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isProcessing)
            .padding(.horizontal)

            if let source = model.source {
                ReaderImageCompareCanvas(
                    original: source.image,
                    result: showsOriginal || mode == .original ? nil : comparedImage,
                    resultLabel: resultLabel
                )
                .id(source.fingerprint)
                .overlay(alignment: .topLeading) {
                    Text(showsOriginal || mode == .original ? "仅原图" : "左：原图 · 右：\(resultLabel)")
                        .font(.caption)
                        .padding(6)
                        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            } else if model.isLoading {
                ProgressView("读取原始尺寸图片…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            controls
        }
        .padding(.vertical, 10)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .task(id: request.id) { await model.load(request: request, pixelWidth: targetPixelWidth) }
        .onChange(of: preset) { _ in model.changePreset() }
        .onChange(of: inferenceMode) { _ in model.changePreset() }
        .onChange(of: computeUnit) { _ in model.changePreset() }
        .onChange(of: scenePhase) { phase in if phase != .active { model.cancel() } }
        .onDisappear { model.release() }
    }

    private var header: some View {
        HStack {
            Text("本页画质验证").font(.headline)
            Spacer()
            Toggle("仅原图", isOn: $showsOriginal)
                .toggleStyle(.button)
                .font(.caption)
            Button { model.release(); onClose() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2)
            }
            .accessibilityLabel("关闭对比并取消处理")
        }
        .padding(.horizontal)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.sourceMessage).font(.caption).foregroundStyle(.white.opacity(0.8))
            if mode == .ai {
                HStack {
                    Picker("本页预设", selection: $preset) {
                        ForEach(SuperResolutionPreset.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.isProcessing)
                    Spacer()
                    Picker("计算单元", selection: $computeUnit) {
                        ForEach(SuperResolutionComputeUnit.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.isProcessing)
                }
                HStack {
                    Picker("推理模式", selection: $inferenceMode) {
                        ForEach(SuperResolutionInferenceMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.isProcessing)
                    Spacer()
                    if model.isProcessing {
                        Button("取消") { model.cancel() }
                    } else {
                        Button("本页 2× 试处理") {
                            model.start(preset: preset, mode: inferenceMode, computeUnit: computeUnit)
                        }
                        .disabled(model.source == nil || model.isLoading || scenePhase != .active)
                    }
                }
                if model.isProcessing { ProgressView(value: model.progress) }
                Text(model.trialMessage).font(.caption).textSelection(.enabled)
                if let result = model.aiResult {
                    Text("输入 \(model.source?.dimensions.label ?? "—") → 输出 \(result.image.width) × \(result.image.height) px\n\(result.model.displayName) · \(result.model.version) · \(result.model.precision)\n实际模式 \(result.actualMode.title)（请求 \(result.requestedMode.title)） · 计算单元 \(result.computeUnit.title)\n\(modeDetail(result))\n耗时 \(String(format: "%.2f", result.elapsedSeconds)) s · PNG \(bytes(result.outputByteCount)) · 内存预算估算 \(bytes(result.estimatedPeakBytes))（非实测峰值）")
                        .font(.caption2)
                        .textSelection(.enabled)
                    if let fallback = result.fallbackReason {
                        Text("回退说明：\(fallback)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("只运行随包提供且已验证的 Core ML 模型；缺失/未验证会明确失败，不用滤镜替代。整页模式为一次模型调用，分块模式保留 128×128 实验路径。")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }
            } else if mode == .traditional {
                Text(traditionalSummary).font(.caption)
            } else {
                Text("原图不改写；关闭此页后清理试处理副本。")
                    .font(.caption)
            }
        }
        .padding(.horizontal)
    }

    private var comparedImage: CGImage? {
        switch mode {
        case .original: nil
        case .traditional: model.traditionalImage
        case .ai: model.aiResult?.image
        }
    }

    private var resultLabel: String {
        switch mode {
        case .original: "原图"
        case .traditional: model.traditionalImage == nil ? "原图（传统未改变）" : "传统插值 / 锐化"
        case .ai:
            guard let result = model.aiResult else { return "原图（AI 尚未完成）" }
            return "AI 2× · \(result.actualMode == .fullPage ? "整页" : "分块")"
        }
    }

    private func modeDetail(_ result: SuperResolutionResult) -> String {
        if let width = result.paddedInputWidth, let height = result.paddedInputHeight {
            return "整页输入 \(width) × \(height) px：反射补齐后单次 Core ML 推理，再裁剪回原页 2×"
        }
        return "分块输入 128 × 128 px：保留实验性重叠/拼接路径"
    }

    private var traditionalSummary: String {
        let enhancement = request.enhancement
        guard enhancement.isEnabled else { return "传统滤镜已关闭；当前显示原图，不是 AI 输出。" }
        let output = model.traditionalImage.map { "\($0.width) × \($0.height)" } ?? (model.source?.dimensions.label ?? "—")
        return "传统插值 / 锐化（非 AI）：\(enhancement.mode.title)，强度 \(Int(enhancement.strength * 100))%，输出 \(output) px。\(model.traditionalImage == nil ? "未改变，回退原图。" : "")"
    }

    private func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// Both layers share one source-coordinate transform. The divider itself stays
/// in viewport coordinates, so dragging it cannot desynchronize the images.
private struct ReaderImageCompareCanvas: View {
    let original: CGImage
    let result: CGImage?
    let resultLabel: String

    @State private var zoom: CGFloat = 1
    @State private var savedZoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var savedOffset = CGSize.zero
    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let factor = min(size.width / CGFloat(original.width), size.height / CGFloat(original.height))
            let fitted = CGSize(width: CGFloat(original.width) * factor, height: CGFloat(original.height) * factor)
            let nativeZoom = 1 / max(factor * displayScale, 0.000001)
            ZStack {
                imageLayer(result ?? original, fitted: fitted, viewport: size)
                if result != nil {
                    imageLayer(original, fitted: fitted, viewport: size)
                        .mask(alignment: .leading) { Rectangle().frame(width: size.width * split) }
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .clipped()
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = clamped(CGSize(width: savedOffset.width + value.translation.width,
                                                height: savedOffset.height + value.translation.height),
                                         fitted: fitted, viewport: size)
                    }
                    .onEnded { _ in savedOffset = offset }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        zoom = min(max(savedZoom * value, min(1, nativeZoom)), max(8, nativeZoom))
                        offset = clamped(offset, fitted: fitted, viewport: size)
                    }
                    .onEnded { _ in savedZoom = zoom; savedOffset = offset }
            )
            .overlay {
                if result != nil {
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 1)
                        .position(x: size.width * split, y: size.height / 2)
                        .allowsHitTesting(false)
                    Image(systemName: "arrow.left.and.right.circle.fill")
                        .font(.system(size: 32))
                        .shadow(radius: 4)
                        .frame(width: 48, height: 56)
                        .position(x: size.width * split, y: size.height / 2)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("readerComparison"))
                            .onChanged { value in split = min(max(value.location.x / max(size.width, 1), 0.03), 0.97) })
                        .accessibilityLabel("拖动原图与结果分割线")
                }
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 16) {
                    Button("适合页面") { reset() }
                    Button("1:1 原图像素") {
                        zoom = nativeZoom
                        savedZoom = zoom
                        offset = .zero
                        savedOffset = .zero
                    }
                    Text("\(String(format: "%.2f", zoom * factor * displayScale)) px/px").monospacedDigit()
                }
                .font(.caption)
                .padding(8)
                .background(Color.black.opacity(0.75), in: Capsule())
                .padding(.bottom, 8)
            }
            .coordinateSpace(name: "readerComparison")
            .onChange(of: size) { _ in reset() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("原图与\(resultLabel)同步缩放对比；双指缩放，单指移动")
    }

    @Environment(\.displayScale) private var displayScale

    private func imageLayer(_ image: CGImage, fitted: CGSize, viewport: CGSize) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: fitted.width, height: fitted.height)
            .scaleEffect(zoom)
            .offset(offset)
            .frame(width: viewport.width, height: viewport.height)
    }

    private func clamped(_ value: CGSize, fitted: CGSize, viewport: CGSize) -> CGSize {
        let x = max((fitted.width * zoom - viewport.width) / 2, 0)
        let y = max((fitted.height * zoom - viewport.height) / 2, 0)
        return CGSize(width: min(max(value.width, -x), x), height: min(max(value.height, -y), y))
    }

    private func reset() {
        zoom = 1; savedZoom = 1; offset = .zero; savedOffset = .zero
    }
}
