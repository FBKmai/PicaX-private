import SwiftUI
import UniformTypeIdentifiers

struct DownloadListPage: View {
    @EnvironmentObject private var downloadService: DownloadService
    let service: ComicContentService

    @State private var showsQueueSheet = false
    @State private var showsLocalImporter = false
    @State private var integrityRecord: DownloadRecord?
    @State private var showsFilterSheet = false
    @State private var selectedRecord: DownloadRecord?
    @State private var readerRequest: DownloadedComicReaderRequest?
    @State private var readingListRequest: ReadingListRequest?
    @State private var searchRequest: DownloadedComicSearchRequest?
    @State private var selectedPlatform: ComicPlatform?
    @State private var completionFilter: DownloadCompletionFilter = .all
    @State private var libraryFilter: DownloadLibraryFilter = .all
    @State private var sortOption: DownloadSortOption = .updatedAt
    @State private var sortDirection: DownloadSortDirection = .descending
    @State private var displayRecords: [DownloadRecord] = []
    @State private var isSelectingDownloads = false
    @State private var selectedDownloadIDs = Set<String>()
    @State private var listAlert: DownloadListFeedback?
#if os(iOS)
    @State private var libraryBatch: LibrarySuperResolutionBatch?
    @State private var showsLanSuperResolution = false
    @State private var lanSelectedRecords: [DownloadRecord] = []
#endif
    @State private var exportingRecordID: String?
    @State private var archiveExportDocument = DownloadedComicExportDocument()
    @State private var archiveExportFileName = "漫画.zip"
    @State private var showsArchiveExporter = false
    @State private var pdfExportDocument = DownloadedComicExportDocument()
    @State private var pdfExportFileName = "漫画.pdf"
    @State private var showsPDFExporter = false

    var body: some View {
        Group {
            downloadList
        }
        .picaxSensitiveImageContent(!displayRecords.isEmpty)
        .navigationTitle("下载")
        .toolbar {
            ToolbarItemGroup(placement: .picaxTopBarTrailing) {
                if isSelectingDownloads {
                    Button(areAllSelectableSelected ? "取消全选" : "全选") {
                        toggleSelectAll()
                    }
                    .disabled(selectableDisplayRecords.isEmpty)

                    Button("完成") {
                        endSelection()
                    }
                } else {
                    Button { showsLocalImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel("导入本地漫画")
                    Button {
                        showsQueueSheet = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                    .accessibilityLabel("下载队列")

#if os(iOS)
                    Button { lanSelectedRecords = []; showsLanSuperResolution = true } label: {
                        Image(systemName: "desktopcomputer")
                    }
                    .accessibilityLabel("电脑超分任务与配对")
                    Button {
                        beginSelection()
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityLabel("多选批量超分")
                    .disabled(libraryFilter == .superResolution)
#endif

                    Button {
                        showsFilterSheet = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("高级筛选")
                }
            }
        }
        .sheet(isPresented: $showsLocalImporter) { LocalComicImportSheet() }
        .sheet(item: $integrityRecord) { DownloadIntegritySheet(record: $0) }
        .sheet(isPresented: $showsQueueSheet) {
            DownloadQueueSheet()
                .picaxPresentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsFilterSheet) {
            DownloadAdvancedFilterSheet(
                selectedPlatform: $selectedPlatform,
                completionFilter: $completionFilter,
                sortOption: $sortOption,
                sortDirection: $sortDirection
            )
            .picaxPresentationDetents([.medium, .large])
        }
        .fileExporter(
            isPresented: $showsArchiveExporter,
            document: archiveExportDocument,
            contentType: .zip,
            defaultFilename: archiveExportFileName
        ) { result in
            archiveExportDocument.removeTemporaryFile()
            archiveExportDocument = DownloadedComicExportDocument()
            handleExportResult(result)
        }
        .fileExporter(
            isPresented: $showsPDFExporter,
            document: pdfExportDocument,
            contentType: .pdf,
            defaultFilename: pdfExportFileName
        ) { result in
            pdfExportDocument.removeTemporaryFile()
            pdfExportDocument = DownloadedComicExportDocument()
            handleExportResult(result)
        }
        .alert(item: $listAlert) { feedback in
            Alert(
                title: Text(feedback.title),
                message: Text(feedback.message),
                dismissButton: .default(Text("好"))
            )
        }
        .sheet(item: $selectedRecord) { record in
            DownloadedComicInfoSheet(record: record, service: service) { request in
                selectedRecord = nil
                readerRequest = request
            } openSearch: { request in
                selectedRecord = nil
                searchRequest = request
            }
                .picaxPresentationDetents([.medium, .large])
        }
        .picaxNavigationDestination(item: $readerRequest) { request in
            DownloadedComicReaderPage(request: request, service: service)
        }
        .picaxNavigationDestination(item: $readingListRequest) { request in
            ReadingListReaderPage(request: request, service: service)
        }
        .picaxNavigationDestination(item: $searchRequest) { request in
            ComicSearchPage(initialQuery: request.tag.query, platform: request.tag.platform, service: service)
        }
#if os(iOS)
        .sheet(isPresented: $showsLanSuperResolution) {
            PicaxNavigationContainer {
                LanSuperResolutionView(records: lanSelectedRecords, onSubmitted: endSelection)
                    .toolbar {
                        ToolbarItem(placement: .picaxTopBarTrailing) {
                            Button("关闭") { showsLanSuperResolution = false }
                        }
                    }
            }
        }
        .fullScreenCover(item: $libraryBatch) { batch in
            LibrarySuperResolutionView(batch: batch) {
                libraryBatch = nil
            }
        }
#endif
        .task {
            refreshDisplayRecords()
        }
        .onChange(of: downloadService.records) { _ in
            refreshDisplayRecords()
        }
        .onChange(of: selectedPlatform) { _ in
            refreshDisplayRecords()
        }
        .onChange(of: completionFilter) { _ in
            refreshDisplayRecords()
        }
        .onChange(of: libraryFilter) { _ in
            selectedDownloadIDs.removeAll()
            refreshDisplayRecords()
        }
        .onChange(of: sortOption) { _ in
            refreshDisplayRecords()
        }
        .onChange(of: sortDirection) { _ in
            refreshDisplayRecords()
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            listAlert = DownloadListFeedback(title: "导出失败", message: error.localizedDescription)
        }
    }

    private func autoSuperResolutionBanner(_ status: AutoSuperResolutionStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title)
                        .font(.subheadline.weight(.semibold))
                    Text(status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if status.isRunning {
                    Button("取消") {
                        downloadService.cancelAutoSuperResolution()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        downloadService.dismissAutoSuperResolutionStatus()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭自动超分提示")
                }
            }

            if status.isRunning {
                ProgressView(value: status.progress)
                    .tint(.purple)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var downloadList: some View {
        VStack(spacing: 0) {
            if let status = downloadService.autoSuperResolutionStatus {
                autoSuperResolutionBanner(status)
            }
            libraryFilterBar
            List {
                if displayRecords.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "arrow.down.circle",
                        description: Text(emptyDescription)
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section("已下载") {
                        if !isSelectingDownloads, !readableDisplayRecords.isEmpty {
                            Button {
                                Task { @MainActor in
                                    readingListRequest = ReadingListRequest(
                                        title: "已下载",
                                        entries: readableDisplayRecords.map { record in
                                            ReadingListEntry.downloaded(
                                                record,
                                                coverURL: downloadService.localCoverURL(for: record) ?? record.item.coverURL
                                            )
                                        }
                                    )
                                }
                            } label: {
                                Label("阅读全部", systemImage: "play.circle")
                            }
                        }

                        ForEach(displayRecords) { record in
                            recordRow(record)
                        }
                    }
                }
            }
            .picaxInsetGroupedListStyle()
            .background(AppColor.groupedBackground)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
#if os(iOS)
            if isSelectingDownloads {
                selectionBar
            }
#endif
        }
    }

    private var libraryFilterBar: some View {
        Picker("下载分类", selection: $libraryFilter) {
            ForEach(DownloadLibraryFilter.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppColor.groupedBackground)
        .accessibilityLabel("下载分类")
        .disabled(isSelectingDownloads)
    }

    @ViewBuilder
    private func recordRow(_ record: DownloadRecord) -> some View {
        if isSelectingDownloads {
            selectionRow(record)
        } else {
            Button {
                selectedRecord = record
            } label: {
                DownloadRecordRow(
                    record: record,
                    coverURL: downloadService.localCoverURL(for: record) ?? record.item.coverURL
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("检查完整性与修复") { integrityRecord = record }
                Button {
                    prepareArchiveExport(for: record)
                } label: {
                    Label("以 ZIP 导出", systemImage: "archivebox")
                }
                .disabled(exportingRecordID != nil)

                Button {
                    preparePDFExport(for: record)
                } label: {
                    Label("以 PDF 导出", systemImage: "doc.richtext")
                }
                .disabled(exportingRecordID != nil)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    downloadService.removeRecord(record)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private func selectionRow(_ record: DownloadRecord) -> some View {
        let canSelect = downloadService.canSuperResolution(record)
        let isSelected = selectedDownloadIDs.contains(record.id)
        return Button {
            toggleSelection(record)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                DownloadRecordRow(
                    record: record,
                    coverURL: downloadService.localCoverURL(for: record) ?? record.item.coverURL
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSelect)
        .opacity(canSelect ? 1 : 0.45)
    }

#if os(iOS)
    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text("已选 \(selectedDownloadIDs.count) 本")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    lanSelectedRecords = displayRecords.filter {
                        selectedDownloadIDs.contains($0.id) && downloadService.canSuperResolution($0)
                    }
                    showsLanSuperResolution = true
                } label: {
                    Label("电脑超分", systemImage: "desktopcomputer")
                }
                .buttonStyle(.bordered)
                .disabled(selectedDownloadIDs.isEmpty)
                Button {
                    startLibraryBatch()
                } label: {
                    Label("本机超分", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedDownloadIDs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }
#endif

    private var readableDisplayRecords: [DownloadRecord] {
        displayRecords.filter { !$0.chapters.isEmpty }
    }

    private var selectableDisplayRecords: [DownloadRecord] {
        displayRecords.filter { downloadService.canSuperResolution($0) }
    }

    private var areAllSelectableSelected: Bool {
        !selectableDisplayRecords.isEmpty
            && selectableDisplayRecords.allSatisfy { selectedDownloadIDs.contains($0.id) }
    }

    private func beginSelection() {
        guard !selectableDisplayRecords.isEmpty else {
            listAlert = DownloadListFeedback(
                title: "没有可超分的下载",
                message: "只能选择有已下载章节、不在下载队列中，且尚无超分版本的普通漫画。"
            )
            return
        }
        selectedDownloadIDs.removeAll()
        isSelectingDownloads = true
    }

    private func endSelection() {
        isSelectingDownloads = false
        selectedDownloadIDs.removeAll()
    }

    private func toggleSelection(_ record: DownloadRecord) {
        guard downloadService.canSuperResolution(record) else { return }
        if selectedDownloadIDs.contains(record.id) {
            selectedDownloadIDs.remove(record.id)
        } else {
            selectedDownloadIDs.insert(record.id)
        }
    }

    private func toggleSelectAll() {
        if areAllSelectableSelected {
            selectedDownloadIDs.removeAll()
        } else {
            selectedDownloadIDs = Set(selectableDisplayRecords.map(\.id))
        }
    }

#if os(iOS)
    private func startLibraryBatch() {
        let selected = displayRecords.filter {
            selectedDownloadIDs.contains($0.id) && downloadService.canSuperResolution($0)
        }
        guard !selected.isEmpty else {
            listAlert = DownloadListFeedback(
                title: "没有可超分的下载",
                message: "所选漫画已有超分版本、仍在下载或没有已下载章节。"
            )
            return
        }
        do {
            let requests = try selected.map {
                try downloadService.makeSuperResolutionBatchRequest(for: $0)
            }
            libraryBatch = LibrarySuperResolutionBatch(requests: requests)
            endSelection()
        } catch {
            listAlert = DownloadListFeedback(
                title: "无法开始批量超分",
                message: error.localizedDescription
            )
        }
    }
#endif

    private func prepareArchiveExport(for record: DownloadRecord) {
        guard exportingRecordID == nil else { return }
        exportingRecordID = record.id

        Task { @MainActor in
            do {
                let export = try await downloadService.makeArchiveExport(for: record)
                archiveExportDocument.removeTemporaryFile()
                archiveExportDocument = DownloadedComicExportDocument(fileURL: export.fileURL, fileName: export.fileName)
                archiveExportFileName = export.fileName
                showsArchiveExporter = true
            } catch {
                listAlert = DownloadListFeedback(title: "导出失败", message: error.localizedDescription)
            }
            exportingRecordID = nil
        }
    }

    private func preparePDFExport(for record: DownloadRecord) {
        guard exportingRecordID == nil else { return }
        exportingRecordID = record.id

        Task { @MainActor in
            do {
                let export = try await downloadService.makePDFExport(for: record)
                pdfExportDocument.removeTemporaryFile()
                pdfExportDocument = DownloadedComicExportDocument(fileURL: export.fileURL, fileName: export.fileName)
                pdfExportFileName = export.fileName
                showsPDFExporter = true
            } catch {
                listAlert = DownloadListFeedback(title: "导出失败", message: error.localizedDescription)
            }
            exportingRecordID = nil
        }
    }

    private func refreshDisplayRecords() {
        var records = downloadService.records

        switch libraryFilter {
        case .all:
            break
        case .normal:
            records = records.filter { !$0.isSuperResolution }
        case .superResolution:
            records = records.filter(\.isSuperResolution)
        }

        if let selectedPlatform {
            records = records.filter { $0.item.platform == selectedPlatform }
        }

        switch completionFilter {
        case .all:
            break
        case .complete:
            records = records.filter {
                $0.isSuperResolution
                    ? $0.isSuperResolutionComplete
                    : $0.chapters.count >= max($0.totalChapterCount, 1)
            }
        case .partial:
            records = records.filter {
                $0.isSuperResolution
                    ? !$0.isSuperResolutionComplete
                    : $0.chapters.count < max($0.totalChapterCount, 1)
            }
        }

        records.sort { lhs, rhs in
            switch sortDirection {
            case .ascending:
                return isOrdered(lhs, before: rhs)
            case .descending:
                return isOrdered(rhs, before: lhs)
            }
        }

        if displayRecords != records {
            displayRecords = records
        }
    }

    private func isOrdered(_ lhs: DownloadRecord, before rhs: DownloadRecord) -> Bool {
        switch sortOption {
        case .updatedAt:
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
            }
            return lhs.updatedAt < rhs.updatedAt
        case .title:
            let result = lhs.item.title.localizedStandardCompare(rhs.item.title)
            if result == .orderedSame {
                return lhs.updatedAt < rhs.updatedAt
            }
            return result == .orderedAscending
        case .size:
            if lhs.totalBytes == rhs.totalBytes {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.totalBytes < rhs.totalBytes
        case .chapters:
            if lhs.chapters.count == rhs.chapters.count {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.chapters.count < rhs.chapters.count
        }
    }

    private var hasActiveFilters: Bool {
        selectedPlatform != nil || completionFilter != .all
    }

    private var emptyTitle: String {
        if libraryFilter == .superResolution {
            return "暂无超分漫画"
        }
        if libraryFilter == .normal {
            return "暂无普通下载"
        }
        return hasActiveFilters ? "没有匹配的下载" : "暂无已下载"
    }

    private var emptyDescription: String {
        if libraryFilter == .superResolution {
            return "在“全部”或“正常”分类中多选漫画，再选择“本机超分”或“电脑超分”生成。"
        }
        if hasActiveFilters {
            return "调整右上角高级筛选后再试。"
        }
        if downloadService.tasks.isEmpty {
            return "在漫画详情页选择章节后会加入下载队列。"
        }
        return "右上角下载队列中有 \(downloadService.tasks.count) 个任务。"
    }
}

private struct DownloadedComicExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip, .pdf] }
    static var writableContentTypes: [UTType] { [.zip, .pdf] }

    var fileURL: URL?
    var fileName: String?

    init(fileURL: URL? = nil, fileName: String? = nil) {
        self.fileURL = fileURL
        self.fileName = fileName
    }

    init(configuration: ReadConfiguration) throws {
        fileURL = nil
        fileName = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let fileURL else {
            throw DownloadedComicExportDocumentError.missingFile
        }
        let wrapper = try FileWrapper(url: fileURL, options: .immediate)
        wrapper.preferredFilename = fileName ?? fileURL.lastPathComponent
        return wrapper
    }

    func removeTemporaryFile() {
        guard let fileURL else { return }
        let directoryURL = fileURL.deletingLastPathComponent()
        if directoryURL.lastPathComponent.hasPrefix("PicaX-") {
            try? FileManager.default.removeItem(at: directoryURL)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

private enum DownloadedComicExportDocumentError: LocalizedError {
    case missingFile

    var errorDescription: String? {
        "导出文件尚未生成。"
    }
}

private struct DownloadListFeedback: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct DownloadQueueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloadService: DownloadService
    @EnvironmentObject private var downloadTaskStore: DownloadTaskStore
    @State private var showsClearQueueConfirmation = false

    var body: some View {
        PicaxNavigationContainer {
            List {
                if downloadTaskStore.tasks.isEmpty {
                    ContentUnavailableView("暂无下载任务", systemImage: "tray", description: Text("新任务会从漫画详情页加入"))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(downloadTaskStore.tasks) { task in
                            DownloadTaskRow(task: task)
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    if task.status == .paused {
                                        Button {
                                            downloadService.resume(task)
                                        } label: {
                                            Label("继续", systemImage: "play.fill")
                                        }
                                        .tint(.green)
                                    } else if task.status == .queued || task.status == .downloading {
                                        Button {
                                            downloadService.pause(task)
                                        } label: {
                                            Label("暂停", systemImage: "pause.fill")
                                        }
                                        .tint(.orange)
                                    }

                                    Button {
                                        downloadService.prioritize(task)
                                    } label: {
                                        Label("优先", systemImage: "arrow.up.to.line")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        downloadService.removeTask(task)
                                    } label: {
                                        Label("移除", systemImage: "trash")
                                    }

                                    if task.status == .failed {
                                        Button {
                                            downloadService.retry(task)
                                        } label: {
                                            Label("重试", systemImage: "arrow.clockwise")
                                        }
                                        .tint(.blue)
                                    }
                                }
                        }
                    } footer: {
                        Text("右滑可以暂停、继续或优先下载；左滑可以移除任务，失败任务可以重试。")
                    }
                }
            }
            .picaxInsetGroupedListStyle()
            .background(AppColor.groupedBackground)
            .picaxSensitiveImageContent(!downloadTaskStore.tasks.isEmpty)
            .navigationTitle("下载队列")
            .picaxNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItemGroup(placement: .picaxTopBarTrailing) {
                    if !downloadTaskStore.tasks.isEmpty {
                        Button(role: .destructive) {
                            showsClearQueueConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("清空下载队列")
                    }

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭")
                }
            }
            .alert("清空下载队列？", isPresented: $showsClearQueueConfirmation) {
                Button("清空队列", role: .destructive) {
                    downloadService.clearTasks()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作会移除所有等待中、下载中、暂停和失败的下载任务，不会删除已经下载完成的漫画文件。")
            }
        }
    }
}

private struct DownloadAdvancedFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedPlatform: ComicPlatform?
    @Binding var completionFilter: DownloadCompletionFilter
    @Binding var sortOption: DownloadSortOption
    @Binding var sortDirection: DownloadSortDirection

    var body: some View {
        PicaxNavigationContainer {
            List {
                Section("平台") {
                    Picker("平台", selection: $selectedPlatform) {
                        Text("全部").tag(nil as ComicPlatform?)
                        ForEach(ComicPlatform.allCases) { platform in
                            Text(platform.title)
                                .tag(platform as ComicPlatform?)
                        }
                    }
                }

                Section("状态") {
                    Picker("完成状态", selection: $completionFilter) {
                        ForEach(DownloadCompletionFilter.allCases) { option in
                            Text(option.title)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("排序") {
                    Picker("排序方式", selection: $sortOption) {
                        ForEach(DownloadSortOption.allCases) { option in
                            Text(option.title)
                                .tag(option)
                        }
                    }

                    Picker("排序方向", selection: $sortDirection) {
                        ForEach(DownloadSortDirection.allCases) { option in
                            Text(option.title)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .picaxInsetGroupedListStyle()
            .background(AppColor.groupedBackground)
            .navigationTitle("高级筛选")
            .picaxNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .picaxTopBarLeading) {
                    Button("重置") {
                        reset()
                    }
                }

                ToolbarItem(placement: .picaxTopBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("完成")
                }
            }
        }
    }

    private func reset() {
        selectedPlatform = nil
        completionFilter = .all
        sortOption = .updatedAt
        sortDirection = .descending
    }
}

private struct DownloadTaskRow: View {
    let task: ComicDownloadTask

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ComicCoverView(url: task.item.coverURL, accentColor: task.item.accentColor, width: 58, height: 78)

            VStack(alignment: .leading, spacing: 6) {
                Text(task.item.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(task.statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)

                ProgressView(value: task.progress)
                    .tint(task.item.accentColor)

                Text(task.chapterCountText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch task.status {
        case .failed:
            .red
        case .paused:
            .orange
        case .queued, .downloading:
            .secondary
        }
    }
}

private struct DownloadRecordRow: View {
    let record: DownloadRecord
    let coverURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ComicCoverView(url: coverURL, accentColor: record.item.accentColor, width: 58, height: 78)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(record.item.title)
                        .font(.headline)
                        .lineLimit(2)

                    if record.isSuperResolution {
                        Text("超分")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(record.item.accentColor.opacity(0.16), in: Capsule())
                            .foregroundStyle(record.item.accentColor)
                    }
                }

                Text(record.detailText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(record.item.accentColor)
                    .lineLimit(1)

                Text("\(record.item.platformTitle) · \(record.updatedAtText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private enum DownloadCompletionFilter: String, CaseIterable, Identifiable {
    case all
    case complete
    case partial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "全部"
        case .complete:
            "完整"
        case .partial:
            "部分"
        }
    }
}

private enum DownloadLibraryFilter: String, CaseIterable, Identifiable {
    case all
    case normal
    case superResolution

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "全部"
        case .normal:
            "正常"
        case .superResolution:
            "超分"
        }
    }
}

private enum DownloadSortOption: String, CaseIterable, Identifiable {
    case updatedAt
    case title
    case size
    case chapters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updatedAt:
            "最近更新"
        case .title:
            "标题"
        case .size:
            "大小"
        case .chapters:
            "章节数"
        }
    }
}

private enum DownloadSortDirection: String, CaseIterable, Identifiable {
    case descending
    case ascending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .descending:
            "降序"
        case .ascending:
            "升序"
        }
    }
}
