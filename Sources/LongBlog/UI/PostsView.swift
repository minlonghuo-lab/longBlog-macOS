import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PostsWorkspace: View {
    @ObservedObject var model: PostsModel
    var body: some View {
        VStack(spacing: 0) {
            if !model.staged.isEmpty { stagingBar }
            HSplitView {
                PostListColumn(model: model).frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
                Group {
                    if model.draft.id.isEmpty {
                        EmptyWorkspace(symbol: "doc.richtext", title: "选择一篇文章", detail: "本地编辑 → 暂存发布或下架 → 审阅 → 单个原子提交。\n⌘N 新建文章，⌘E 切换阅读 / 编辑。")
                    } else { PostDetailView(model: model) }
                }.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity).background(Color.blogBackground)
            }
        }
        .overlay(alignment: .bottom) { OperationStatus(model: model).padding(.bottom, 8) }
    }
    private var stagingBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full.fill").foregroundStyle(Color.blogPeach)
            Text("\(model.staged.count) 项待提交").font(.callout.weight(.semibold)).foregroundStyle(Color.blogPeach)
            Text("审阅后一并提交，暂存尚未改变线上内容").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("撤销暂存…") { model.frozenReview = model.staged; model.revert() }.disabled(model.busy || model.isDirty)
            Button("审阅并提交…") { model.review() }.buttonStyle(.borderedProminent).disabled(model.busy)
                .help("⌘⇧P")
        }.controlSize(.small).padding(.horizontal, 18).padding(.vertical, 9).background(Color.blogPeach.opacity(0.09))
    }
}

private struct PostListColumn: View {
    @ObservedObject var model: PostsModel
    var body: some View {
        VStack(spacing: 0) {
            Picker("文章状态", selection: $model.filter) { ForEach(["全部", "草稿", "已发布"], id: \.self) { Text($0).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            if model.filtered.isEmpty {
                EmptyWorkspace(symbol: "doc.text", title: model.search.isEmpty ? "暂无文章" : "没有匹配的文章",
                               detail: model.search.isEmpty ? "新建本地文章，或配置 GitHub 后同步。不会自动写入远端。" : "换个关键词试试。", settings: !model.loaded)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        let staged = model.stagedIDs
                        ForEach(model.filtered) { row in
                            PostListCell(row: row, selected: row.id == model.draft.id, staged: staged.contains(row.id), dirty: row.id == model.draft.id && model.isDirty) { model.select(row) }
                                .contextMenu { contextMenu(row) }
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(model.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(model.folder)
                Spacer()
                Text("\(model.filtered.count) 篇").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                Button { model.sync() } label: { Image(systemName: "arrow.triangle.2.circlepath") }.buttonStyle(.borderless)
                    .help("从 GitHub 同步文章和附件").accessibilityLabel("同步 GitHub 文章").disabled(model.busy)
            }.padding(.horizontal, 12).padding(.vertical, 9)
        }
    }
    @ViewBuilder private func contextMenu(_ row: DataRow) -> some View {
        Button("打开") { model.select(row) }
        if let path = row.data["filePath"] as? String, !path.isEmpty {
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button("拷贝文件路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
        }
        Button("拷贝文章 ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.id, forType: .string) }
    }
}

private struct PostListCell: View {
    let row: DataRow, selected: Bool, staged: Bool, dirty: Bool, action: () -> Void
    private var tags: [String] { row.data["tags"] as? [String] ?? [] }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if row.flag("pinned") { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.blogPeach) }
                    Text(row.text("title").isEmpty ? "未命名" : row.text("title")).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? Color.blogPeach : Color.blogText).lineLimit(2)
                    Spacer(minLength: 0)
                    if dirty { Circle().fill(Color.blogPeach).frame(width: 7, height: 7).help("有未保存的修改") }
                }
                Text(dateLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !row.text("summary").isEmpty { Text(row.text("summary")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 5) {
                    StatusBadge(text: row.flag("publish") ? "已发布" : "草稿", color: row.flag("publish") ? .blogGreen : .gray)
                    if staged { StatusBadge(text: "待提交", color: .blogPeach) }
                    if row.flag("hasImage") { StatusBadge(text: "图片", color: .gray, symbol: "photo") }
                    ForEach(tags.prefix(2), id: \.self) { StatusBadge(text: "#\($0)", color: .gray) }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(CardButtonStyle(selected: selected)).accessibilityLabel("文章：\(row.text("title"))")
    }
    private var dateLine: String {
        let fmt: (Double) -> String = { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000).formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) : "—" }
        let published = row.number("publishedAt"), updated = row.number("updatedAt")
        return (published > 0 ? "发布 \(fmt(published))" : "创建 \(fmt(row.number("createdAt")))") + " · 更新 \(fmt(updated))"
    }
}

private enum EditorLayout: String, CaseIterable, Identifiable {
    case read = "阅读", edit = "编辑", split = "分栏"
    var id: String { rawValue }
    var symbol: String { switch self { case .read: return "book"; case .edit: return "square.and.pencil"; case .split: return "rectangle.split.2x1" } }
}

/// Holds the editor bridge and scroll sync outside SwiftUI observation so scrolling
/// the editor only re-renders the preview, not the whole detail view.
private final class EditorSession: ObservableObject {
    let controller = MarkdownEditorController()
    @Published var fraction: Double = 0
    init() { controller.onScroll = { [weak self] value in if abs((self?.fraction ?? 0) - value) > 0.002 { self?.fraction = value } } }
}

private struct PostDetailView: View {
    @ObservedObject var model: PostsModel
    @State private var session = EditorSession()
    @State private var importing = false
    @State private var aiSnapshot: PostDraft?
    @State private var showMeta = false
    @AppStorage("lb.editor.fontSize") private var fontSize = 15.0
    @AppStorage("lb.editor.mono") private var monospaced = false
    @AppStorage("lb.editor.syncScroll") private var syncScroll = true

    private var layout: Binding<EditorLayout> {
        Binding(get: { !model.editing ? .read : (model.splitPreview ? .split : .edit) },
                set: { value in
                    switch value { case .read: model.editing = false; case .edit: model.editing = true; model.splitPreview = false; case .split: model.editing = true; model.splitPreview = true }
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.editing { editorArea } else { reader }
        }
        .disabled(model.busy && model.running.contains("load"))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importFiles(urls) { session.controller.insert($0) }
            case .failure(let error): model.errors["attachment"] = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(get: { aiSnapshot != nil }, set: { if !$0 { aiSnapshot = nil } })) {
            if let snapshot = aiSnapshot {
                AIWritingSheet(title: snapshot.title, bodyText: snapshot.markdown, summary: snapshot.summary) { target, text in
                    guard model.draft == snapshot else { model.errors["ai"] = "文章已在 AI 生成期间变化，未自动覆盖。请重新生成或手动复制结果。"; return }
                    switch target { case .body: model.draft.markdown = text; case .summary: model.draft.summary = text; case .continuation: model.draft.markdown += "\n\n" + text }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Picker("视图", selection: layout) {
                ForEach(EditorLayout.allCases) { item in Label(item.rawValue, systemImage: item.symbol).tag(item) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize().help("阅读 ⌘⌥R · 编辑 ⌘⌥E · 分栏预览 ⌘⌥P")
            StatusBadge(text: model.draft.published ? "已发布" : "本地草稿", color: model.draft.published ? .blogGreen : .gray)
            if model.stagedIDs.contains(model.draft.id) { StatusBadge(text: "待提交") }
            if model.isDirty { StatusBadge(text: "未保存", color: .orange, symbol: "circle.fill") }
            Spacer(minLength: 8)
            Button { model.save() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                .disabled(!model.isDirty || model.busy).help("保存到本地 ⌘S")
            Button { aiSnapshot = model.draft } label: { Label("AI", systemImage: "sparkles") }
                .disabled(model.draft.bodyFormat == "html" || model.busy).help("AI 写作辅助：摘要、润色、续写")
            Menu {
                Button("暂存发布 / 更新") { model.stage(true) }
                Button("暂存下架") { model.stage(false) }.disabled(!model.draft.published)
                Divider()
                Button("在 Finder 中显示") { revealInFinder() }.disabled(model.draft.directory == nil)
            } label: { Label("暂存", systemImage: "tray.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.busy).accessibilityLabel("暂存文章发布或下架")
        }
        .controlSize(.small).labelStyle(.titleAndIcon)
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    // MARK: Editor

    private var editorArea: some View {
        VStack(spacing: 0) {
            titleAndMeta
            Divider()
            HStack(spacing: 8) {
                MarkdownToolbar(controller: session.controller, attach: { importing = true })
                Spacer(minLength: 4)
                outlineMenu
                appearanceMenu
            }.padding(.horizontal, 12).padding(.vertical, 5)
            Divider()
            if model.draft.bodyFormat == "html" {
                Label("HTML 原文：保留格式，仅源码编辑，不交给 Markdown 渲染器。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
            }
            if model.splitPreview {
                HSplitView {
                    editor.frame(minWidth: 280, maxWidth: .infinity)
                    LivePreview(model: model, session: session, sync: syncScroll).frame(minWidth: 260, maxWidth: .infinity)
                }
            } else {
                editor
            }
            Divider()
            statusBar
        }
    }

    private var editor: some View {
        MarkdownTextEditor(text: $model.draft.markdown, documentID: model.draft.id, controller: session.controller,
                           editable: !model.busy || !model.running.contains("save"), fontSize: fontSize, monospaced: monospaced,
                           maxContentWidth: model.splitPreview ? nil : 760,
                           onImportFiles: { urls in model.importFiles(urls) { session.controller.insert($0) } })
            .background(Color.blogEditor)
    }

    private var titleAndMeta: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                TextField("文章标题", text: $model.draft.title).font(.system(size: 22, weight: .bold)).textFieldStyle(.plain).accessibilityLabel("文章标题")
                Button { withAnimation(.easeOut(duration: 0.15)) { showMeta.toggle() } } label: {
                    Label(showMeta ? "收起信息" : "摘要与标签", systemImage: showMeta ? "chevron.up" : "tag")
                }.buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
            }
            if showMeta {
                TextField("手动摘要（可留空，发布时自动生成）", text: $model.draft.summary, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityLabel("文章手动摘要")
                TextField("标签，以英文逗号分隔", text: $model.draft.tags).textFieldStyle(.roundedBorder).accessibilityLabel("文章标签")
            } else if !model.draft.tags.isEmpty || !model.draft.summary.isEmpty {
                Text([model.draft.tags.isEmpty ? nil : model.draft.tags.split(separator: ",").map { "#" + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "),
                      model.draft.summary.isEmpty ? nil : model.draft.summary].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }

    private var outlineMenu: some View {
        Menu {
            let items = TextStats.headings(model.draft.markdown)
            if items.isEmpty { Text("没有标题") }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(String(repeating: "    ", count: max(0, item.level - 1)) + item.title) { session.controller.reveal(location: item.location) }
            }
        } label: { Label("大纲", systemImage: "list.bullet.indent") }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small).help("跳转到标题")
    }

    private var appearanceMenu: some View {
        Menu {
            Button("放大字号") { fontSize = min(24, fontSize + 1) }
            Button("缩小字号") { fontSize = max(11, fontSize - 1) }
            Button("默认字号") { fontSize = 15 }
            Divider()
            Toggle("等宽字体", isOn: $monospaced)
            Toggle("预览跟随编辑器滚动", isOn: $syncScroll)
        } label: { Image(systemName: "textformat.size") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("编辑器外观")
    }

    private var statusBar: some View {
        let words = TextStats.words(model.draft.markdown)
        return HStack(spacing: 14) {
            Text("\(words) 字").monospacedDigit()
            Text("约 \(TextStats.readingMinutes(words)) 分钟阅读")
            Text("\(model.draft.markdown.count) 字符").monospacedDigit()
            Spacer()
            Text(model.isDirty ? "未保存 · ⌘S 保存到本地" : "已保存到本地 · 保存不等于发布")
            Text(model.draft.id).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 5)
    }

    // MARK: Reader

    private var reader: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.draft.title.isEmpty ? "未命名文章" : model.draft.title).font(.system(size: 28, weight: .bold)).textSelection(.enabled)
                    Spacer()
                    Button { model.editing = true } label: { Label("编辑", systemImage: "square.and.pencil") }.buttonStyle(.borderedProminent).controlSize(.small).help("⌘E")
                }
                let tags = model.draft.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !tags.isEmpty { HStack(spacing: 6) { ForEach(tags, id: \.self) { StatusBadge(text: "#\($0)", color: .gray) } } }
                if !model.draft.summary.isEmpty { Text(model.draft.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4) }
            }.padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 12)
            Divider()
            if model.draft.bodyFormat == "html" { ReaderView(markdown: model.draft.markdown, baseDirectory: model.draft.directory, bodyFormat: .html) }
            else { ReaderView(markdown: model.draft.markdown, baseDirectory: model.draft.directory) }
        }
    }

    private func revealInFinder() {
        guard let dir = model.draft.directory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("index.md")].filter { FileManager.default.fileExists(atPath: $0.path) }.first.map { [$0] } ?? [dir])
    }
}

/// Only this view observes scroll position; the editor is never re-rendered by scrolling.
private struct LivePreview: View {
    @ObservedObject var model: PostsModel
    @ObservedObject var session: EditorSession
    let sync: Bool
    var body: some View {
        ReaderView(markdown: model.draft.markdown, baseDirectory: model.draft.directory,
                   bodyFormat: model.draft.bodyFormat == "html" ? .html : .markdown,
                   live: true, title: model.draft.title, scrollFraction: sync ? session.fraction : nil)
            .overlay(alignment: .topTrailing) {
                Text("实时预览").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(.thinMaterial, in: Capsule()).padding(8).allowsHitTesting(false)
            }
    }
}
