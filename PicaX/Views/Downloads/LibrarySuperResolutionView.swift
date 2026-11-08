#if os(iOS)
import SwiftUI
import UIKit

struct LibrarySuperResolutionBatch: Identifiable {
    let id = UUID()
    let requests: [ReaderBatchRenderRequest]
}

/// Multi-book queue launched from the download list. Results are written into
/// the PicaX downloads library as synthetic "超分" records; the original
/// downloads are never modified.
struct LibrarySuperResolutionView: View {
    let batch: LibrarySuperResolutionBatch
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ReaderBatchRenderModel()
    @State private var preset: SuperResolutionPreset = .color
    @State private var inferenceMode: SuperResolutionInferenceMode = .automatic
    @State private var showsStartConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.16))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    booksCard
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
        .onAppear { model.prepare(requests: batch.requests) }
        .onChange(of: model.isRunning) { running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                model.cancel()
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.cancel()
        }
        .alert("开始批量超分？", isPresented: $showsStartConfirmation) {
            Button("取消", role: .cancel) {}
            Button("开始") {
                model.start(scope: .wholeBook, preset: preset, mode: inferenceMode)
            }
        } message: {
            Text(startConfirmationMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("批量 2× 超分").font(.headline)
                Text("已选 \(batch.requests.count) 本 · 串行处理")
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
            .accessibilityLabel("取消并关闭批量超分")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var booksCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("处理范围", systemImage: "books.vertical")
                .font(.headline)
            Text("按下载顺序逐本处理全部已下载章节，不处理未下载章节。")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
            ForEach(Array(batch.requests.enumerated()), id: \.element.id) { offset, request in
                Text("\(offset + 1). \(request.bookTitle) · \(request.chapters.count) 章")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .libraryBatchCard()
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
            Text("批量固定仅 CPU：你在 iPhone Duo 上实测 CPU+GPU/全部会出现画面异常。")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("自动模式会优先整页；超出整页范围时回退到 128 分块，并在 manifest.json 记录实际模式与回退原因。")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
        }
        .libraryBatchCard()
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("运行说明", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("• 必须保持前台；切到后台会取消当前页，已完成页面保留。运行期间会暂时保持屏幕常亮。")
            Text("• 逐本、逐页串行处理，不会并发占用多份模型内存。CPU 整页推理可能每页数秒到数十秒。")
            Text("• 不覆盖原始下载；超分结果保存为“PicaX 下载 → 超分”分类中的独立漫画，可正常阅读、导出 ZIP/PDF。")
            Text("• 每本书内跳过的长条/超预算页面会记录为未生成，不会标成成功。")
            Text("• 若某本书已有超分版本，或仍在下载，会在开始前被排除。")
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.72))
        .libraryBatchCard()
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
                if model.bookCount > 1, model.currentBookOrdinal > 0 {
                    Text("漫画 \(model.currentBookOrdinal)/\(model.bookCount) · \(model.currentBookTitle)")
                        .font(.caption2)
                        .lineLimit(1)
                    Text("完成 \(model.bookSuccessCount) 本 · 失败 \(model.bookFailureCount) 本")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
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
                }
                .font(.caption2)
                if let fatalMessage = model.fatalMessage {
                    Text(fatalMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Text("结果位置：PicaX 下载 → 超分分类")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .libraryBatchCard()
        }
    }

    @ViewBuilder
    private var problemsCard: some View {
        let pages = model.problemPageRecords
        let chapters = model.failedChapterRecords
        if !pages.isEmpty || !chapters.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("未生成的页面", systemImage: "exclamationmark.octagon")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ForEach(Array(chapters.suffix(10))) { chapter in
                    Text("章节 \(chapter.chapterIndex + 1) · \(chapter.title)：\(chapter.errorDescription ?? "读取失败")")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                ForEach(Array(pages.suffix(20))) { page in
                    Text("E\(page.chapterIndex + 1) · P\(page.pageIndex + 1) · \(page.status.title)：\(page.errorDescription ?? "未完成")")
                        .font(.caption2)
                        .foregroundStyle(page.status == .skipped ? .orange : .red)
                }
                if pages.count > 20 || chapters.count > 10 {
                    Text("仅显示最近记录；完整清单写在每本书的 manifest.json。")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .libraryBatchCard()
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if model.isRunning {
                Button(role: .destructive) {
                    model.cancel()
                } label: {
                    Label("取消批量超分", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("取消后当前 Core ML 调用返回即停止；已完成页面和下载记录保留。")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            } else if model.phase == .completed || model.phase == .cancelled
                        || model.phase == .failed {
                Button {
                    onClose()
                } label: {
                    Label("完成", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("结果已保存到 PicaX 下载的超分分类；返回后可用分类器筛选。")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Button {
                    showsStartConfirmation = true
                } label: {
                    Label("开始批量超分", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(batch.requests.isEmpty)
                Text("开始前请确认模型与推理模式；处理期间请保持 App 在前台。")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.92))
    }

    private var startConfirmationMessage: String {
        "将使用 \(preset.title) · \(inferenceMode.title) · 仅 CPU，逐本处理 \(batch.requests.count) 本漫画的全部已下载章节。必须保持前台；可能耗时很长并占用较多存储。原始下载不会被覆盖，结果保存到 PicaX 下载的超分分类。"
    }

    private func stat(_ title: String, _ value: Int, _ color: Color) -> some View {
        Text("\(title) \(value)")
            .foregroundStyle(color)
            .monospacedDigit()
    }
}

private extension View {
    func libraryBatchCard() -> some View {
        padding(12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
    }
}
#endif
