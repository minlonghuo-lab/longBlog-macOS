import SwiftUI
import UniformTypeIdentifiers

struct PostsWorkspace: View {
    @ObservedObject var model: PostsModel
    var body: some View {
        VStack(spacing: 0) {
            if !model.staged.isEmpty { stagingBar }
            HSplitView {
                VStack(spacing: 0) {
                    Picker("文章状态", selection: $model.filter) { ForEach(["全部", "草稿", "已发布"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).padding(12)
                    if model.filtered.isEmpty { EmptyWorkspace(symbol: "doc.text", title: "暂无文章", detail: "新建本地文章，或配置 GitHub 后同步。不会自动写入远端。", settings: !model.loaded) }
                    ScrollView {
                        LazyVStack(spacing: 6) { ForEach(model.filtered) { row in PostListCell(row: row, selected: row.id == model.draft.id) { model.select(row) } } }.padding(10)
                    }
                    Divider()
                    HStack { Text(model.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1); Spacer(); Button { model.sync() } label: { Image(systemName: "arrow.down.circle") }.help("从 GitHub 同步文章和附件").accessibilityLabel("同步 GitHub 文章").disabled(model.busy) }.padding(12)
                }.frame(minWidth: 290, idealWidth: 320, maxWidth: 350)
                if model.draft.id.isEmpty { EmptyWorkspace(symbol: "doc.richtext", title: "选择一篇文章", detail: "本地编辑 → 暂存发布或下架 → 审阅 → 单个原子提交。") }
                else { PostDetailView(model: model).frame(minWidth: 430) }
            }
            OperationStatus(model: model)
        }
    }
    private var stagingBar: some View {
        HStack {
            Label("\(model.staged.count) 项待提交", systemImage: "tray.full").font(.callout.weight(.medium))
            Text("暂存尚未更改线上内容").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("撤销暂存…") { model.frozenReview = model.staged; model.revert() }.disabled(model.busy || model.isDirty)
            Button("审阅并提交…") { model.review() }.buttonStyle(.borderedProminent).disabled(model.busy)
        }.padding(12).background(Color.blogPeach.opacity(0.09))
    }
}
private struct PostListCell: View {
    let row: DataRow, selected: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Text(row.text("title").isEmpty ? "未命名" : row.text("title")).font(.headline).foregroundStyle(Color.blogText).lineLimit(2)
                HStack { StatusBadge(text: row.flag("publish") ? "已发布" : "草稿", color: row.flag("publish") ? .green : .gray); Spacer(); Text(dateLabel(row.number("updatedAt"))).font(.system(size: 10)).foregroundStyle(.secondary) }
                if !row.text("summary").isEmpty { Text(row.text("summary")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).background(selected ? Color.blogPeach.opacity(0.16) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11)).accessibilityLabel("文章：\(row.text("title"))")
    }
}
private struct PostDetailView: View {
    @ObservedObject var model: PostsModel
    @State private var importing = false
    @State private var aiSnapshot: PostDraft?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.editing { editor } else { reader }
        }.padding(20).disabled(model.busy)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result { case .success(let urls): if let url = urls.first { model.importFile(url) }; case .failure(let error): model.errors["attachment"] = error.localizedDescription }
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
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusBadge(text: model.draft.published ? "已发布" : "本地草稿", color: model.draft.published ? .green : .gray)
                if model.isDirty { StatusBadge(text: "未保存") }
                Spacer()
                Picker("文章模式", selection: $model.editing) { Text("阅读").tag(false); Text("编辑").tag(true) }.pickerStyle(.segmented).frame(width: 150)
            }
            HStack(spacing: 8) {
                Button("保存本地", systemImage: "square.and.arrow.down") { model.save() }.disabled(!model.isDirty)
                Button("附件", systemImage: "paperclip") {
                    if model.isDirty { model.errors["attachment"] = "请先保存文章再导入附件，确保资源位于稳定的文章目录。" } else { importing = true }
                }.disabled(!model.editing)
                Button("AI 写作", systemImage: "sparkles") { aiSnapshot = model.draft }.disabled(!model.editing || model.draft.bodyFormat == "html")
                Spacer()
                Menu("暂存…") {
                    Button("暂存发布 / 更新") { model.stage(true) }
                    Button("暂存下架") { model.stage(false) }.disabled(!model.draft.published)
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("暂存文章发布或下架")
            }.controlSize(.small)
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("文章标题", text: $model.draft.title).font(.title2.weight(.semibold)).textFieldStyle(.plain).accessibilityLabel("文章标题")
            TextField("手动摘要（可留空）", text: $model.draft.summary, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityLabel("文章手动摘要")
            TextField("标签，以英文逗号分隔", text: $model.draft.tags).textFieldStyle(.roundedBorder).accessibilityLabel("文章标签")
            if model.draft.bodyFormat == "html" { Label("HTML 原文：本版保留格式，仅源码编辑，不交给 Markdown 渲染器。", systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
            MarkdownEditor(text: $model.draft.markdown)
            Text("\(model.draft.markdown.count) 字符 · \(model.draft.id) · 保存不等于发布").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var reader: some View {
        Text(model.draft.title).font(.largeTitle.weight(.bold)).textSelection(.enabled)
        if !model.draft.summary.isEmpty { Text(model.draft.summary).foregroundStyle(.secondary).textSelection(.enabled) }
        if model.draft.bodyFormat == "html" { ReaderView(markdown: model.draft.markdown, baseDirectory: model.draft.directory, bodyFormat: .html) }
        else { ReaderView(markdown: model.draft.markdown, baseDirectory: model.draft.directory) }
    }
}
