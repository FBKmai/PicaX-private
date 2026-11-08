#if os(iOS)
import SwiftUI
import UIKit

/// Foreground whole-chapter/whole-book rendering. The batch is always serial
/// and CPU-only; leaving the view cancels the current Core ML call and keeps
/// already written pages. It never overwrites the downloaded originals.
struct ReaderBatchRenderView: View {
    let request: ReaderBatchRenderRequest
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ReaderBatchRenderModel()
    @State private var scope: ReaderBatchRenderScope = .wholeBook
    @State private var preset: SuperResolutionPreset = .color
    @State private var inferenceMode: SuperResolutionInferenceMode = .automatic
    @State private var showsStartConfirmation = false
    @State private var showsShareSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.16))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scopeCard
                    optionsCard
                    notesCard
                    progressCard
                    problemsCard
                }
                .padding(16)
            }
            footer
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .onAppear { model.prepare(request: request) }
        .onChange(of: model.isRunning) { running in
            // A whole-book CPU batch can run for hours. Keep the screen awake
            // while the foreground-only batch is active, then restore the
            // normal auto-lock behavior on exit.
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                model.cancel()
                if !showsShareSheet {
                    model.discardTemporaryArchive()
                }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.cancel()
            if !showsShareSheet {
                model.discardTemporaryArchive()
            }
        }
        .onChange(of: model.archiveURL) { url in
            if url != nil { showsShareSheet = true }
        }
        .alert("开始批量渲染？", isPresented: $showsStartConfirmation) {
            Button("取消", role: .cancel) {}
            Button("开始") {
                model.start(scope: scope, preset: preset, mode: inferenceMode)
            }
        } message: {
            Text(startConfirmationMessage)
        }
        .sheet(isPresented: $showsShareSheet) {
            if let url = model.archiveURL {
                BatchRenderShareSheet(items: [url])
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("2× 批量渲染").font(.headline)
                Text(request.bookTitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.cancel()
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
            }
            .accessibilityLabel("取消并关闭批量渲染")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("处理范围", systemImage: "books.vertical")
                .font(.headline)
            Picker("处理范围", selection: $scope) {
                Text("当前章节").tag(ReaderBatchRenderScope.currentChapter)
                Text("整本（\(request.chapters.count) 章）").tag(ReaderBatchRenderScope.wholeBook)
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
            Text(scopeExplanation)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
        }
        .batchCard()
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("模型与推理", systemImage: "cpu")
                .font(.headline)
            HStack {
                Picker("模型预设", selection: $preset) {
                    ForEach(SuperResolutionPreset.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
                Picker("推理模式", selection: $inferenceMode) {
                    ForEach(SuperResolutionInferenceMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
            }
            .disabled(model.isRunning)
            HStack {
                Text("计算单元")
                Spacer()
                Text("仅 CPU（固定）")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.subheadline)
            Text("你在 iPhone Duo 上实测 CPU+GPU/全部会出现画面异常；批量固定使用仅 CPU，单页对比页仍可手动切换其他计算单元。")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("自动模式会优先整页；超出整页范围时回退到 128 分块，并在 manifest.json 记录实际模式与回退原因。")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
        }
        .batchCard()
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("运行说明", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("• 必须保持前台；切到后台会取消当前页，已完成页面保留。运行期间会暂时保持屏幕常亮。")
            Text("• 逐页串行处理，不会并发占用多份模型内存。CPU 整页推理可能每页数秒到数十秒，整本可能耗时很长。")
            Text("• 不覆盖下载原图；结果写入“文件 App → 我的 iPhone → PicaX → SuperResolution”。")
            Text("• 长条、超出整页范围或超预算的页面会被跳过并记录，不会标成成功。")
            Text("• 当前“整卷连续阅读”模式不提供批量入口，请切换到普通分页/条漫阅读。")
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.72))
        .batchCard()
    }

    @ViewBuilder
    private var progressCard: some View {
        if model.phase != .idle || !model.pageRecords.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.phase.title).font(.headline)
                    Spacer()
                    Text(model.elapsedText).monospacedDigit().font(.caption)
                }
                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                if model.isRunning || model.phase == .completed || model.phase == .cancelled
                    || model.phase == .failed {
                    ProgressView(value: model.overallProgress)
                        .tint(.white)
                }
                if model.currentChapterOrdinal > 0 {
                    Text("章节 \(model.currentChapterOrdinal)/\(model.scopeChapterCount) · \(model.currentChapterTitle)")
                        .font(.caption2)
                        .lineLimit(1)
                    if model.currentChapterPageCount > 0 {
                        Text("本页 \(model.currentPageOrdinal)/\(model.currentChapterPageCount)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                if model.isRunning {
                    ProgressView(value: model.currentPageProgress)
                        .tint(.green)
                }
                HStack(spacing: 14) {
                    stat("成功", model.pageSuccessCount, .green)
                    stat("跳过", model.pageSkippedCount, .orange)
                    stat("失败", model.pageFailureCount, .red)
                    if !model.failedChapterRecords.isEmpty {
                        stat("章节失败", model.failedChapterRecords.count, .red)
                    }
                }
                .font(.caption2)
                if let page = latestSucceededPage {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("最近成功：E\(page.chapterIndex + 1) · P\(page.pageIndex + 1) · \(page.modelDisplayName ?? page.modelID ?? "模型未知")（\(page.modelVersion ?? "版本未知")，\(page.modelPrecision ?? "精度未知")）")
                        Text("请求 \(modeTitle(page.requestedMode)) → 实际 \(modeTitle(page.actualMode)) · \(dimensionText(page)) · \(page.computeUnit ?? "计算单元未知") · \(elapsedText(page.elapsedSeconds))")
                        if let reason = page.fallbackReason, !reason.isEmpty {
                            Text("回退原因：\(reason)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                }
                if let directory = model.outputDirectory {
                    Text("结果目录：文件 App / 我的 iPhone / PicaX / SuperResolution / \(directory.lastPathComponent)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .textSelection(.enabled)
                }
                if let fatalMessage = model.fatalMessage {
                    Text(fatalMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let archiveMessage = model.archiveMessage {
                    Text(archiveMessage)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .textSelection(.enabled)
                }
            }
            .batchCard()
        }
    }

    @ViewBuilder
    private var problemsCard: some View {
        let pages = model.problemPageRecords
        let chapters = model.failedChapterRecords
        if !pages.isEmpty || !chapters.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("未生成 PNG 的页面", systemImage: "exclamationmark.octagon")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ForEach(Array(chapters.prefix(20))) { chapter in
                    Text("章节 \(chapter.chapterIndex + 1) · \(chapter.title)：\(chapter.errorDescription ?? "读取失败")")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                ForEach(Array(pages.suffix(30))) { page in
                    Text("E\(page.chapterIndex + 1) · P\(page.pageIndex + 1) · \(page.status.title)：\(page.errorDescription ?? "未完成")")
                        .font(.caption2)
                        .foregroundStyle(page.status == .skipped ? .orange : .red)
                }
                if pages.count > 30 {
                    Text("仅显示最近 30 页；完整清单见 manifest.json。")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .batchCard()
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if model.isRunning {
                Button(role: .destructive) {
                    model.cancel()
                } label: {
                    Label("取消批量渲染", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("取消后当前 Core ML 调用返回即停止；已完成页面和 manifest 保留。")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            } else if model.phase == .completed || model.phase == .cancelled
                        || model.phase == .failed {
                if model.isArchiving {
                    ProgressView("正在打包 ZIP…")
                        .frame(maxWidth: .infinity)
                } else if let archiveURL = model.archiveURL {
                    Button {
                        showsShareSheet = true
                    } label: {
                        Label("分享 ZIP：\(archiveURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        model.prepareArchive()
                    } label: {
                        Label("导出 ZIP", systemImage: "archivebox")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.pageRecords.contains(where: { $0.fileName != nil }))
                }
                Button("新建批次") {
                    model.resetForNewBatch()
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    showsStartConfirmation = true
                } label: {
                    Label("开始批量渲染", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(request.chapters.isEmpty)
                Text("开始前请确认范围与模型；处理期间请保持 App 在前台。")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.92))
    }

    private var scopeExplanation: String {
        switch scope {
        case .currentChapter:
            let index = min(max(request.initialChapterIndex, 0), max(request.chapters.count - 1, 0))
            let title = request.chapters.indices.contains(index) ? request.chapters[index].title : "—"
            return "只处理进入阅读器时的当前章节：\(title)。"
        case .wholeBook:
            return "从第 1 章按顺序处理全部 \(request.chapters.count) 章；不会跳过已读章节。"
        }
    }

    private var startConfirmationMessage: String {
        let range = scope == .wholeBook
            ? "全部 \(request.chapters.count) 章"
            : "当前章节"
        return "将使用 \(preset.title) · \(inferenceMode.title) · 仅 CPU，逐页处理\(range)。必须保持前台；整本可能耗时很长并占用较多存储。原图不会被覆盖。"
    }

    private func stat(_ title: String, _ value: Int, _ color: Color) -> some View {
        Text("\(title) \(value)")
            .foregroundStyle(color)
            .monospacedDigit()
    }

    private var latestSucceededPage: ReaderBatchRenderPageRecord? {
        model.pageRecords.last { $0.status == .succeeded }
    }

    private func modeTitle(_ rawValue: String?) -> String {
        guard let rawValue, let mode = SuperResolutionInferenceMode(rawValue: rawValue) else {
            return rawValue ?? "未知"
        }
        switch mode {
        case .fullPage: "整页（单次推理）"
        case .tiled: "分块（128）"
        case .automatic: "自动"
        }
    }

    private func dimensionText(_ page: ReaderBatchRenderPageRecord) -> String {
        let source = "\(page.sourceWidth ?? 0)×\(page.sourceHeight ?? 0)"
        let output = "\(page.outputWidth ?? 0)×\(page.outputHeight ?? 0)"
        let padded = "\(page.paddedInputWidth ?? 0)×\(page.paddedInputHeight ?? 0)"
        return "原图 \(source) → 输出 \(output)，补齐输入 \(padded)"
    }

    private func elapsedText(_ seconds: Double?) -> String {
        guard let seconds else { return "耗时未知" }
        return "\(Int(seconds.rounded())) 秒"
    }
}

private extension View {
    func batchCard() -> some View {
        padding(12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
    }
}

private struct BatchRenderShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
