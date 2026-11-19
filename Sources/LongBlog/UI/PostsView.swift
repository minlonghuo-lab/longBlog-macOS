import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PostsWorkspace: View {
    @ObservedObject var model: PostsModel
    @ObservedObject private var app = AppModel.shared
    @State private var collapseListInStudio = false

    private var showPostList: Bool {
        !(app.focusMode && collapseListInStudio)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.staged.isEmpty && !app.focusMode {
                stagingBar
                HairlineDivider()
            }
            HSplitView {
                if showPostList {
                    PostListColumn(model: model, compact: false)
                        .frame(minWidth: 235, idealWidth: 280, maxWidth: 350)
                }
                Group {
                    if model.draft.id.isEmpty {
                        if !model.loaded || model.running.contains("load") || !model.filtered.isEmpty {
                            Color.clear
                        } else {
                            EmptyWorkspace(
                                symbol: "doc.richtext",
                                title: "选择或新建一篇文章",
                                detail: "本地 Markdown 编辑 → 暂存发布或下架 → 审阅 → 单个原子提交到 main。\n支持三栏实时预览（⌘⌥P）与专注工作台（⌘⇧F）。",
                                actionTitle: "新建文章  ⌘N",
                                action: { app.newArticle() }
                            )
                        }
                    } else {
                        PostDetailView(model: model, collapseListInStudio: $collapseListInStudio)
                    }
                }
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { OperationStatus(model: model).padding(.bottom, 28) }
            }
        }
    }

    private var stagingBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.blogPeach)
            Text("\(model.staged.count) 项待提交")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.blogPeachSoft)
            Text("审阅后一并提交，不会逐篇覆盖远端")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.blogSecondary)
            Spacer()
            BlogGlassGroup(spacing: 8) {
                Button("撤销") {
                    model.frozenReview = model.staged
                    model.revert()
                }
                .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                .disabled(model.busy || model.isDirty)

                Button {
                    model.review()
                } label: {
                    HStack(spacing: 5) {
                        Text("审阅并提交")
                        ShortcutCap(text: "⌘⇧P", onPrimary: true)
                    }
                }
                .buttonStyle(BlogPrimaryButtonStyle(compact: true))
                .disabled(model.busy)
                .help("审阅待提交文章  ⌘⇧P")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.blogTintPeach)
    }
}

private struct PostListColumn: View {
    @ObservedObject var model: PostsModel
    var compact = false
    @ObservedObject private var app = AppModel.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                SearchField(prompt: "搜索标题、摘要或标签", text: $model.search, focused: $searchFocused)
                if compact {
                    HStack {
                        Text("共 \(model.filtered.count) 篇 · \(model.folder)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.blogMuted)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            HairlineDivider()

            if model.filtered.isEmpty {
                EmptyWorkspace(
                    symbol: "doc.text",
                    title: model.search.isEmpty ? "暂无文章" : "没有匹配的文章",
                    detail: model.search.isEmpty ? "新建本地文章，或在连接设置配置 GitHub 后同步。" : "换个关键词或切换筛选状态试试。",
                    settings: !model.loaded && !model.errors.isEmpty
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: compact ? 4 : 8) {
                        let staged = model.stagedIDs
                        ForEach(model.filtered) { row in
                            PostListCell(
                                row: row,
                                selected: row.id == model.draft.id,
                                staged: staged.contains(row.id),
                                dirty: row.id == model.draft.id && model.isDirty,
                                compact: compact
                            ) {
                                model.select(row)
                            }
                            .contextMenu { contextMenu(row) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }

            HairlineDivider()

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.blogMuted)
                Text(model.folder)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.blogSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.folder)
                Spacer()
                Text("\(model.filtered.count) 篇")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Color.blogMuted)
                Button {
                    model.sync()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.blogMuted)
                }
                .buttonStyle(.plain)
                .help("从 GitHub 同步文章和附件")
                .accessibilityLabel("同步 GitHub 文章")
                .disabled(model.busy)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .onChange(of: app.searchRequested) {
            if app.section == .posts { searchFocused = true }
        }
    }

    @ViewBuilder private func contextMenu(_ row: DataRow) -> some View {
        Button("阅读文章") { model.select(row, keepStudioMode: false) }
        Button("在分栏工作台中编辑") {
            model.splitPreview = true
            model.select(row, keepStudioMode: true)
            if row.id == model.draft.id { model.editing = true }
        }
        Divider()
        if row.flag("publish") {
            Button("删除文章（需先下架）") {}
                .disabled(true)
            Button("暂存下架") { model.delete(row) }
        } else {
            Button("删除草稿…", role: .destructive) { model.delete(row) }
        }
        if let path = row.data["filePath"] as? String, !path.isEmpty {
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button("拷贝文件路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
        }
        Button("拷贝文章 ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.id, forType: .string) }
    }
}

private struct PostListCell: View {
    let row: DataRow, selected: Bool, staged: Bool, dirty: Bool, compact: Bool, action: () -> Void
    private var tags: [String] { row.data["tags"] as? [String] ?? [] }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if row.flag("pinned") {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.blogPeach)
                    }
                    Text(row.text("title").isEmpty ? "未命名文章" : row.text("title"))
                        .font(.system(size: compact ? 13 : 14, weight: .semibold))
                        .foregroundStyle(selected ? Color.blogPeachSoft : Color.blogText)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if dirty {
                        Circle()
                            .fill(Color.blogPeach)
                            .frame(width: 7, height: 7)
                            .help("有未保存的本地修改")
                    }
                }

                Text(dateLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.blogMuted)
                    .lineLimit(1)

                if !compact && !row.text("summary").isEmpty {
                    Text(row.text("summary"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.blogSecondary.opacity(0.85))
                        .lineLimit(2)
                }

                HStack(spacing: 5) {
                    StatusBadge(
                        text: row.flag("publish") ? "已发布" : "草稿",
                        color: row.flag("publish") ? .blogGreen : .blogMuted
                    )
                    if staged {
                        StatusBadge(text: "待提交", color: .blogPeach)
                    }
                    if row.flag("hasImage") {
                        StatusBadge(text: "图片", color: .blogMuted, symbol: "photo")
                    }
                    if !compact {
                        ForEach(tags.prefix(2), id: \.self) {
                            StatusBadge(text: "#\($0)", color: .blogMuted)
                        }
                    }
                }
            }
            .padding(compact ? 11 : 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle(selected: selected))
        .accessibilityLabel("文章：\(row.text("title"))")
    }

    private var dateLine: String {
        let fmt: (Double) -> String = {
            $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000).formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) : "—"
        }
        let published = row.number("publishedAt"), updated = row.number("updatedAt")
        if compact {
            let base = published > 0 ? "发布 \(fmt(published))" : "创建 \(fmt(row.number("createdAt")))"
            return base
        }
        return (published > 0 ? "发布 \(fmt(published))" : "创建 \(fmt(row.number("createdAt")))") + " · 更新 \(fmt(updated))"
    }
}

private enum EditorLayout: String, CaseIterable, Identifiable {
    case read = "阅读", edit = "编辑", split = "分栏"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .read: return "book"
        case .edit: return "square.and.pencil"
        case .split: return "rectangle.split.2x1"
        }
    }
}

/// Holds the editor bridge, scroll sync and cursor position outside parent view init.
private final class EditorSession: ObservableObject {
    let controller = MarkdownEditorController()
    @Published var fraction: Double = 0
    @Published var cursorLine: Int = 1
    @Published var cursorCol: Int = 1
    init() {
        controller.onScroll = { [weak self] value in
            if abs((self?.fraction ?? 0) - value) > 0.002 { self?.fraction = value }
        }
        controller.onCursorChange = { [weak self] line, col in
            if self?.cursorLine != line || self?.cursorCol != col {
                self?.cursorLine = line
                self?.cursorCol = col
            }
        }
    }
}

private struct PostDetailView: View {
    @ObservedObject var model: PostsModel
    @Binding var collapseListInStudio: Bool
    @ObservedObject private var app = AppModel.shared
    @StateObject private var session = EditorSession()
    @State private var importing = false
    @State private var aiSnapshot: PostDraft?
    @State private var showMeta = false
    @AppStorage("lb.editor.fontSize") private var fontSize = 15.0
    @AppStorage("lb.editor.mono") private var monospaced = false
    @AppStorage("lb.editor.lineNumbers") private var showLineNumbers = true
    @AppStorage("lb.editor.syncScroll") private var syncScroll = true
    @AppStorage("lb.editor.previewTheme") private var previewTheme = "paper"

    private var mutatingBusy: Bool {
        !model.running.subtracting(["list", "load"]).isEmpty
    }

    private var layout: Binding<EditorLayout> {
        Binding(
            get: { !model.editing ? .read : (model.splitPreview ? .split : .edit) },
            set: { value in
                switch value {
                case .read:
                    model.editing = false
                    if app.focusMode {
                        withAnimation(.easeInOut(duration: 0.22)) { app.focusMode = false }
                    }
                case .edit:
                    model.editing = true
                    model.splitPreview = false
                case .split:
                    model.editing = true
                    model.splitPreview = true
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HairlineDivider()
            if model.editing { editorArea } else { reader }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importFiles(urls) { session.controller.insert($0) }
            case .failure(let error): model.errors["attachment"] = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(get: { aiSnapshot != nil }, set: { if !$0 { aiSnapshot = nil } })) {
            if let snapshot = aiSnapshot {
                AIWritingSheet(title: snapshot.title, bodyText: snapshot.markdown, summary: snapshot.summary) { target, text in
                    guard model.draft == snapshot else {
                        model.errors["ai"] = "文章已在 AI 生成期间变化，未自动覆盖。请重新生成或手动复制结果。"
                        return
                    }
                    switch target {
                    case .body: model.draft.markdown = text
                    case .summary: model.draft.summary = text
                    case .continuation: model.draft.markdown += "\n\n" + text
                    }
                }
            }
        }
    }

    // MARK: - Detail Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(showBadges: true, compactActions: false)
            headerRow(showBadges: false, compactActions: false)
            headerRow(showBadges: false, compactActions: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private func headerRow(showBadges: Bool, compactActions: Bool) -> some View {
        HStack(spacing: 10) {
            if app.focusMode {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        collapseListInStudio.toggle()
                    }
                } label: {
                    Image(systemName: collapseListInStudio ? "sidebar.left" : "rectangle.leadinghalf.inset.filled")
                }
                .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                .fixedSize()
                .help(collapseListInStudio ? "显示文章列表（三栏工作台）" : "隐藏文章列表（纯净双栏）")
            }

            BlogSegmentedControl(
                options: EditorLayout.allCases.map { SegmentedOption(value: $0, label: $0.rawValue, symbol: $0.symbol) },
                selection: layout,
                compact: true
            )
            .help("阅读 ⌘⌥R · 编辑 ⌘⌥E · 分栏预览 ⌘⌥P")

            if showBadges {
                StatusBadge(
                    text: model.draft.published ? "已发布" : "草稿",
                    color: model.draft.published ? .blogGreen : .blogMuted
                )
                .fixedSize()
                if model.stagedIDs.contains(model.draft.id) {
                    StatusBadge(text: "待提交", color: .blogPeach)
                        .fixedSize()
                }
            }
            if model.isDirty {
                StatusBadge(text: "未保存", color: .blogAmber, dot: true)
                    .fixedSize()
            }

            Spacer(minLength: 8)

            BlogGlassGroup(spacing: 8) {
                if app.focusMode {
                    Button {
                        app.focusMode = false
                        app.sidebarCollapsed = false
                    } label: {
                        if compactActions {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                        } else {
                            Label("退出专注", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                    .fixedSize()
                    .help("退出专注模式  ⌘⇧F")
                } else {
                    Button {
                        app.toggleFocusMode()
                    } label: {
                        if compactActions {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        } else {
                            Label("专注", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                    .fixedSize()
                    .help("进入专注写作工作台  ⌘⇧F")
                }

                Button {
                    aiSnapshot = model.draft
                } label: {
                    if compactActions {
                        Image(systemName: "sparkles")
                    } else {
                        Label("AI", systemImage: "sparkles")
                    }
                }
                .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                .fixedSize()
                .disabled(model.draft.bodyFormat == "html" || mutatingBusy)
                .help("AI 写作辅助：摘要、润色、续写")

                if model.editing && !app.focusMode {
                    if model.isDirty {
                        Button("保存") {
                            model.save()
                        }
                        .buttonStyle(BlogPrimaryButtonStyle(compact: true))
                        .fixedSize()
                        .disabled(mutatingBusy)
                        .help("保存到本地  ⌘S")
                    } else {
                        Button("保存") {
                            model.save()
                        }
                        .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                        .fixedSize()
                        .disabled(true)
                        .help("保存到本地  ⌘S")
                    }
                }

                Group {
                    if #available(macOS 26.0, *) {
                        Menu {
                            stagingMenuItems
                        } label: {
                            Label("暂存", systemImage: "tray.and.arrow.up")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    } else {
                        Menu {
                            stagingMenuItems
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "tray.and.arrow.up")
                                Text("暂存")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.blogText.opacity(0.92))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5.5)
                            .blogGlassControl(capsule: true, interactive: true)
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
                .fixedSize()
                .disabled(mutatingBusy)
                .accessibilityLabel("暂存文章发布或下架")
            }
        }
    }

    @ViewBuilder
    private var stagingMenuItems: some View {
        Button("暂存发布 / 更新到队列") { model.stage(true) }
        Button("暂存下架") { model.stage(false) }.disabled(!model.draft.published)
        Divider()
        Button("在 Finder 中显示") { revealInFinder() }.disabled(model.draft.directory == nil)
        Divider()
        if model.draft.published {
            Button("删除文章（需先下架）") {}
                .disabled(true)
        } else if model.stagedIDs.contains(model.draft.id) {
            Button("删除草稿（暂存队列待处理）") {}
                .disabled(true)
        } else {
            Button("删除草稿…", role: .destructive) {
                model.delete(DataRow(data: ["id": model.draft.id, "title": model.draft.title, "publish": model.draft.published]))
            }
        }
    }

    // MARK: - Studio Editor Area

    private var editorArea: some View {
        VStack(spacing: 0) {
            titleAndMeta
            HairlineDivider()
            HStack(spacing: 6) {
                MarkdownToolbar(controller: session.controller, attach: { importing = true })
                Spacer(minLength: 4)
                outlineMenu
                Button {
                    showLineNumbers.toggle()
                } label: {
                    Image(systemName: "list.number")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(showLineNumbers ? Color.blogPeach : Color.blogMuted)
                        .frame(width: 26, height: 24)
                        .background(showLineNumbers ? Color.blogPeach.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("切换行号显示")
                appearanceMenu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color.blogSurface.opacity(0.6))

            HairlineDivider()

            if model.draft.bodyFormat == "html" {
                Label("HTML 原文模式：保留内嵌 HTML 标签与排版，直接源码编辑，不经过 Markdown 转换。", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.blogAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(Color.blogAmber.opacity(0.08))
            }

            if model.splitPreview {
                HSplitView {
                    editor.frame(minWidth: 300, maxWidth: .infinity)
                    LivePreview(
                        model: model,
                        session: session,
                        sync: syncScroll,
                        theme: $previewTheme
                    )
                    .frame(minWidth: 290, maxWidth: .infinity)
                }
            } else {
                editor
            }

            HairlineDivider()
            statusBar
        }
    }

    private var editor: some View {
        MarkdownTextEditor(
            text: $model.draft.markdown,
            documentID: model.draft.id,
            controller: session.controller,
            editable: !model.busy,
            fontSize: fontSize,
            monospaced: monospaced,
            showLineNumbers: showLineNumbers,
            maxContentWidth: model.splitPreview ? nil : 760,
            onImportFiles: { urls in model.importFiles(urls) { session.controller.insert($0) } }
        )
        .background(Color.blogEditor)
        .clipped()
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var titleAndMeta: some View {
        let tagList = model.draft.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                TextField("输入文章标题…", text: $model.draft.title)
                    .font(.system(size: 20, weight: .bold))
                    .textFieldStyle(.plain)
                    .accessibilityLabel("文章标题")

                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showMeta.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showMeta ? "chevron.up" : "tag")
                        Text(showMeta ? "收起属性" : "摘要与标签")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(showMeta ? Color.blogPeach : Color.blogMuted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.blogSlot, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if showMeta {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "tag").font(.system(size: 11.5)).foregroundStyle(Color.blogMuted).frame(width: 16)
                        TextField("文章标签，用英文逗号分隔（如：macOS, 随笔, LaTeX）", text: $model.draft.tags)
                            .font(.system(size: 12.5))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blogField, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.blogStroke))
                            .accessibilityLabel("文章标签")
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "text.quote").font(.system(size: 11.5)).foregroundStyle(Color.blogMuted).frame(width: 16).padding(.top, 6)
                        TextField("手动摘要（可留空，发布时自动提取正文前段）", text: $model.draft.summary, axis: .vertical)
                            .lineLimit(2...4)
                            .font(.system(size: 12.5))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blogField, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.blogStroke))
                            .accessibilityLabel("文章手动摘要")
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !tagList.isEmpty || !model.draft.summary.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tagList.prefix(4), id: \.self) { tag in
                        StatusBadge(text: "#\(tag)", color: .blogMuted)
                    }
                    if !model.draft.summary.isEmpty {
                        Text(model.draft.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.blogMuted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var outlineMenu: some View {
        Menu {
            let items = TextStats.headings(model.draft.markdown)
            if items.isEmpty { Text("正文暂无标题") }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(String(repeating: "  ", count: max(0, item.level - 1)) + "H\(item.level) · " + item.title) {
                    session.controller.reveal(location: item.location)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.indent")
                Text("大纲")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.blogSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按标题大纲快速跳转")
    }

    private var appearanceMenu: some View {
        Menu {
            Button("放大编辑器字号") { fontSize = min(24, fontSize + 1) }
            Button("缩小编辑器字号") { fontSize = max(12, fontSize - 1) }
            Button("恢复默认字号 (15pt)") { fontSize = 15 }
            Divider()
            Toggle("显示行号栏", isOn: $showLineNumbers)
            Toggle("使用等宽源码字体", isOn: $monospaced)
            Toggle("预览跟随编辑器滚动", isOn: $syncScroll)
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.blogSecondary)
                .frame(width: 26, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("编辑器排版与滚动设置")
    }

    private var statusBar: some View {
        let words = TextStats.words(model.draft.markdown)
        return HStack(spacing: 14) {
            Text("\(words) 字").monospacedDigit()
            Text("约 \(TextStats.readingMinutes(words)) 分钟阅读")
            Text("\(model.draft.markdown.count) 字符").monospacedDigit()
            Text("行 \(session.cursorLine), 列 \(session.cursorCol)")
                .monospacedDigit()
                .foregroundStyle(Color.blogMuted)
            Spacer()
            Text(model.isDirty ? "● 未保存 · ⌘S 保存本地" : "✓ 已保存本地 · 暂存后批量发布")
                .foregroundStyle(model.isDirty ? Color.blogPeach : Color.blogMuted)
            Text(model.draft.id)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.blogMuted.opacity(0.8))
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Color.blogSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.blogSurface.opacity(0.45))
    }

    // MARK: - Reader Mode (Scheme 1 chosen-posts.png + full offline preview)

    private var reader: some View {
        let tags = model.draft.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let dateInfo: String = {
            let fmt: (Double) -> String = {
                $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000).formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) : ""
            }
            var parts: [String] = []
            if model.draft.publishedAt > 0 { parts.append("发布 \(fmt(model.draft.publishedAt))") }
            else if model.draft.createdAt > 0 { parts.append("创建 \(fmt(model.draft.createdAt))") }
            if model.draft.updatedAt > 0 { parts.append("更新 \(fmt(model.draft.updatedAt))") }
            parts.append(model.draft.published ? "已发布" : "本地草稿")
            return parts.joined(separator: " · ")
        }()

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center) {
                    Text(model.draft.id)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color.blogMuted)
                        .textSelection(.enabled)
                    Spacer()
                    PreviewThemeSwitch(theme: $previewTheme)
                }

                Text(model.draft.title.isEmpty ? "未命名文章" : model.draft.title)
                    .font(.system(size: 26, weight: .bold))
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Text(dateInfo)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.blogMuted)
                    ForEach(tags, id: \.self) { tag in
                        StatusBadge(text: "#\(tag)", color: .blogMuted)
                    }
                }

                if !model.draft.summary.isEmpty {
                    Text(model.draft.summary)
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundStyle(Color.blogSecondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 14)

            HairlineDivider()

            ReaderView(
                markdown: model.draft.markdown,
                baseDirectory: model.draft.directory,
                bodyFormat: model.draft.bodyFormat == "html" ? .html : .markdown,
                paperTheme: previewTheme
            )
            .background(readerBackdrop(for: previewTheme))
            .transaction { $0.animation = nil }

            HairlineDivider()

            // Bottom Action Bar matching chosen-posts.png ("编辑 ⌘E" · "分栏写作" · "暂存发布 / 暂存下架")
            HStack(spacing: 10) {
                BlogGlassGroup(spacing: 10) {
                    Button {
                        model.editing = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("编辑")
                            ShortcutCap(text: "⌘E", onPrimary: true)
                        }
                    }
                    .buttonStyle(BlogPrimaryButtonStyle())

                    Button {
                        model.splitPreview = true
                        model.editing = true
                    } label: {
                        Label("分栏写作", systemImage: "rectangle.split.2x1")
                    }
                    .buttonStyle(BlogSecondaryButtonStyle())

                    if model.draft.published {
                        Button("暂存下架") { model.stage(false) }
                            .buttonStyle(BlogSecondaryButtonStyle())
                            .disabled(mutatingBusy)
                    } else {
                        Button("暂存发布") { model.stage(true) }
                            .buttonStyle(BlogSecondaryButtonStyle())
                            .disabled(mutatingBusy)
                        if !model.stagedIDs.contains(model.draft.id) {
                            Button("删除草稿") {
                                model.delete(DataRow(data: ["id": model.draft.id, "title": model.draft.title, "publish": false]))
                            }
                            .buttonStyle(BlogSecondaryButtonStyle(destructive: true))
                            .disabled(mutatingBusy)
                        }
                    }
                }

                Spacer()

                if model.draft.directory != nil {
                    Button {
                        revealInFinder()
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
        }
    }

    private func readerBackdrop(for theme: String) -> Color {
        switch theme {
        case "paper": return Color(nsColor: .rgb(246, 239, 230))
        case "dark": return Color(nsColor: .rgb(37, 30, 26))
        default: return Color(nsColor: .lb(light: .rgb(246, 239, 230), dark: .rgb(37, 30, 26)))
        }
    }

    private func revealInFinder() {
        guard let dir = model.draft.directory else { return }
        let md = dir.appendingPathComponent("index.md")
        NSWorkspace.shared.activateFileViewerSelecting(FileManager.default.fileExists(atPath: md.path) ? [md] : [dir])
    }
}

/// Only this view observes scroll position; the editor is never re-rendered by scrolling.
private struct LivePreview: View {
    @ObservedObject var model: PostsModel
    @ObservedObject var session: EditorSession
    let sync: Bool
    @Binding var theme: String

    private var isLightPaper: Bool { theme == "paper" }

    var body: some View {
        VStack(spacing: 0) {
            // Dedicated Scheme 3 ("实时预览") studio bar
            HStack(spacing: 8) {
                Text("实时预览")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isLightPaper ? Color(nsColor: .rgb(112, 96, 84)) : Color.blogMuted)
                if sync {
                    Text("· 同步滚动")
                        .font(.system(size: 11))
                        .foregroundStyle(isLightPaper ? Color(nsColor: .rgb(142, 126, 112)) : Color.blogMuted.opacity(0.75))
                }
                Spacer()
                PreviewThemeSwitch(theme: $theme, onLightSurface: isLightPaper)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(isLightPaper ? Color(nsColor: .rgb(246, 239, 230)) : Color.blogEditor)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isLightPaper ? Color.black.opacity(0.08) : Color.blogDivider)
                    .frame(height: 1)
            }

            ReaderView(
                markdown: model.draft.markdown,
                baseDirectory: model.draft.directory,
                bodyFormat: model.draft.bodyFormat == "html" ? .html : .markdown,
                live: true,
                title: model.draft.title,
                scrollFraction: sync ? session.fraction : nil,
                paperTheme: theme
            )
            .background(isLightPaper ? Color(nsColor: .rgb(246, 239, 230)) : Color(nsColor: .lb(light: .rgb(246, 239, 230), dark: .rgb(37, 30, 26))))
            .transaction { $0.animation = nil }
        }
    }
}

private struct PreviewThemeSwitch: View {
    @Binding var theme: String
    var onLightSurface = false

    var body: some View {
        BlogSegmentedControl(
            options: [
                SegmentedOption(value: "paper", label: "暖纸"),
                SegmentedOption(value: "dark", label: "深色"),
                SegmentedOption(value: "auto", label: "自动")
            ],
            selection: $theme,
            compact: true,
            onLightSurface: onLightSurface
        )
        .scaleEffect(0.88, anchor: .trailing)
        .help("切换预览纸张底色（支持按住拖动切换：暖纸 / 深色 / 跟随外观）")
    }
}
