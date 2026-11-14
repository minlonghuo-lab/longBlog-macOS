import SwiftUI
import UniformTypeIdentifiers

struct MemosWorkspace: View {
    @ObservedObject var model: MemosModel
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    Picker("说说列表", selection: Binding(get: { model.archived }, set: { model.setArchived($0) })) { Text("说说").tag(false); Text("归档").tag(true) }.pickerStyle(.segmented).padding(12).disabled(model.busy)
                    if model.items.isEmpty { EmptyWorkspace(symbol: "quote.bubble", title: "暂无说说", detail: "先验证 legacy Memos 账户；只有真实返回的数据才会显示。", settings: !model.errors.isEmpty) }
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.items) { row in memoCell(row) }
                            if model.more { Button("加载更多") { model.load(more: true) }.disabled(model.busy).padding() }
                        }.padding(10)
                    }
                    HStack { Image(systemName: "person.crop.circle"); Text(model.username.isEmpty ? "尚未验证账户" : model.username).lineLimit(1); Spacer(); Button("验证 / 刷新") { model.refresh() }.disabled(model.busy) }.font(.caption).padding(12)
                }.frame(minWidth: 290, idealWidth: 320, maxWidth: 350)
                if model.editing { MemoEditorView(model: model).frame(minWidth: 430) }
                else { EmptyWorkspace(symbol: "square.and.pencil", title: "记录此刻", detail: "选择一条说说，或点击“写说说”。默认可见性为仅自己；保存前会确认。") }
            }
            OperationStatus(model: model)
        }
    }
    private func memoCell(_ row: DataRow) -> some View {
        Button { model.select(row) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(dateLabel(row.number("displayTs"), milliseconds: false)).font(.caption).foregroundStyle(.secondary); Spacer(); if row.flag("pinned") { Image(systemName: "pin.fill").foregroundStyle(Color.blogPeach) } }
                Text(row.text("content")).font(.callout).lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
                HStack { StatusBadge(text: visibilityName(row.text("visibility")), color: row.text("visibility") == "PUBLIC" ? .cyan : .gray); if let resources = row.data["resourceList"] as? [Any], !resources.isEmpty { Label("\(resources.count)", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary) } }
            }.padding(13).contentShape(Rectangle())
        }.buttonStyle(.plain).background(model.selectedID == row.id ? Color.blogPeach.opacity(0.17) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11)).accessibilityLabel("说说：\(String(row.text("content").prefix(60)))")
    }
}
private func visibilityName(_ value: String) -> String { switch value { case "PUBLIC": return "公开"; case "PROTECTED": return "登录可见"; default: return "仅自己" } }
private struct MemoEditorView: View {
    @ObservedObject var model: MemosModel
    @State private var preview = false
    @State private var importing = false
    private var isArchived: Bool { model.original?["rowStatus"] as? String == "ARCHIVED" }
    private var isPinned: Bool { (model.original?["pinned"] as? NSNumber)?.boolValue ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.original == nil ? "写一条说说" : "说说 #\(model.selectedID ?? "")").font(.title2.bold())
                if model.isDirty { StatusBadge(text: "未保存") }; Spacer()
                Picker("说说编辑模式", selection: $preview) { Text("编辑").tag(false); Text("预览").tag(true) }.pickerStyle(.segmented).frame(width: 140)
            }
            if isArchived { Label("已归档 · 恢复后可编辑", systemImage: "archivebox").font(.callout).foregroundStyle(.secondary) }
            else { visibilityPicker }
            if preview { ReaderView(markdown: model.content) }
            else { MarkdownEditor(text: $model.content).disabled(isArchived || model.busy) }
            attachments
            actionBar
        }.padding(22)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result { case .success(let urls): if let url = urls.first { model.importFile(url) }; case .failure(let error): model.errors["upload"] = error.localizedDescription }
            }
    }
    private var visibilityPicker: some View {
        HStack {
            Text("可见性").font(.callout).foregroundStyle(.secondary)
            Picker("可见性", selection: $model.visibility) { Text("仅自己").tag("PRIVATE"); Text("登录可见").tag("PROTECTED"); Text("公开").tag("PUBLIC") }.pickerStyle(.segmented).disabled(model.busy)
        }
    }
    private var attachments: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Label("附件 \(model.resources.count)", systemImage: "paperclip").font(.callout); Spacer(); Button("选择文件…") { importing = true }.disabled(model.busy || isArchived) }
            if model.resources.isEmpty { Text("文件通过原生选择器导入，单个附件不超过 32 MiB。附件上传也需确认。").font(.caption).foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(model.resources.enumerated()), id: \.offset) { index, resource in
                        HStack(spacing: 6) {
                            Button { model.openResource(resource) } label: { Label(resource["filename"] as? String ?? resource["name"] as? String ?? "附件", systemImage: "doc") }.help("通过受保护的下载缓存打开附件")
                            if !isArchived { Button { model.resources.remove(at: index) } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("移除附件关联，不删除服务端文件") }
                        }.buttonStyle(.borderless).font(.caption).padding(8).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)).disabled(model.busy)
                    }
                }
            }.frame(maxHeight: model.resources.isEmpty ? 0 : 50)
        }
    }
    private var actionBar: some View {
        HStack {
            if model.original != nil {
                Button(isPinned ? "取消置顶" : "置顶", systemImage: isPinned ? "pin.slash" : "pin") { model.update(["pinned":!isPinned], title: isPinned ? "取消置顶" : "置顶说说") }
                Button(isArchived ? "恢复" : "归档", systemImage: isArchived ? "arrow.uturn.backward" : "archivebox") { model.update(["rowStatus":isArchived ? "NORMAL" : "ARCHIVED"], title: isArchived ? "恢复说说" : "归档说说") }
            }
            Spacer()
            if model.isDirty { Button("放弃修改…") { model.discardThen { model.assign(model.original) } } }
            Button("保存…", systemImage: "checkmark") { model.save() }.buttonStyle(.borderedProminent).disabled(isArchived || (!model.isDirty && model.original != nil))
        }.controlSize(.small).disabled(model.busy)
    }
}
