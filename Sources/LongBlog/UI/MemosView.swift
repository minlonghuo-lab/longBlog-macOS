import SwiftUI
import UniformTypeIdentifiers

struct MemosWorkspace: View {
    @ObservedObject var model: MemosModel
    @ObservedObject private var app = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                timelineColumn
                    .frame(minWidth: 270, idealWidth: 320, maxWidth: 375)
                Group {
                    if model.editing {
                        MemoEditorView(model: model)
                    } else {
                        EmptyWorkspace(
                            symbol: "text.bubble",
                            title: "记录此刻",
                            detail: "从左侧选择一条说说编辑，或点击右上角“写说说”（⌘⇧N）。\n支持 Markdown 语法、可见性控制与图片附件拖入。",
                            actionTitle: "写一条说说  ⌘⇧N",
                            action: { app.newMemo() }
                        )
                    }
                }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { OperationStatus(model: model).padding(.bottom, 16) }
            }
        }
    }

    private var timelineColumn: some View {
        VStack(spacing: 0) {
            HStack {
                BlogSegmentedControl(
                    options: [
                        SegmentedOption(value: false, label: "时间线", count: !model.archived && model.loaded ? model.items.count : nil),
                        SegmentedOption(value: true, label: "已归档", count: model.archived && model.loaded ? model.items.count : nil)
                    ],
                    selection: Binding(get: { model.archived }, set: { model.setArchived($0) }),
                    compact: true
                )
                .disabled(model.busy)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            HairlineDivider()

            if model.filtered.isEmpty {
                EmptyWorkspace(
                    symbol: "quote.bubble",
                    title: model.search.isEmpty ? "暂无说说" : "没有匹配的说说",
                    detail: model.search.isEmpty
                        ? "连接并验证 legacy Memos 账户后即可浏览与发布说说。"
                        : "换个搜索词试试。",
                    settings: !model.errors.isEmpty
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(model.filtered) { row in
                            memoCell(row)
                        }
                        if model.more {
                            Button("加载更多") { model.load(more: true) }
                                .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                                .disabled(model.busy)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(14)
                }
            }

            HairlineDivider()

            HStack(spacing: 8) {
                Image(systemName: model.username.isEmpty ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
                    .foregroundStyle(model.username.isEmpty ? Color.blogMuted : Color.blogPeach)
                Text(model.username.isEmpty ? "尚未验证账户" : "@\(model.username)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.blogSecondary)
                    .lineLimit(1)
                Spacer()
                Button("验证 / 刷新") { model.refresh() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.blogPeach)
                    .disabled(model.busy)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func memoCell(_ row: DataRow) -> some View {
        let selected = model.selectedID == row.id
        let resources = row.data["resourceList"] as? [[String: Any]] ?? []
        let hasImage = resources.contains { ($0["type"] as? String ?? "").lowercased().hasPrefix("image/") }
        let vis = row.text("visibility")

        return Button { model.select(row) } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Warm peach timestamp matching chosen-memos.png
                HStack(spacing: 6) {
                    Text(shortDateTimeLabel(row.number("displayTs"), milliseconds: false))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.blogPeach)
                    Spacer()
                    if model.selectedID == row.id && model.isDirty {
                        Circle().fill(Color.blogPeach).frame(width: 6.5, height: 6.5)
                    }
                }

                Text(row.text("content"))
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .foregroundStyle(Color.blogText)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if row.flag("pinned") {
                        StatusBadge(text: "置顶", color: .blogPeach)
                    }
                    StatusBadge(
                        text: visibilityName(vis),
                        color: vis == "PUBLIC" ? .blogTeal : (vis == "PROTECTED" ? .blogAmber : .blogMuted)
                    )
                    if hasImage {
                        StatusBadge(text: resources.count > 1 ? "图片 \(resources.count)" : "图片", color: .blogMuted, symbol: "photo")
                    } else if !resources.isEmpty {
                        StatusBadge(text: "附件 \(resources.count)", color: .blogMuted, symbol: "paperclip")
                    }
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle(selected: selected))
        .accessibilityLabel("说说：\(String(row.text("content").prefix(60)))")
    }
}

private func visibilityName(_ value: String) -> String {
    switch value {
    case "PUBLIC": return "公开"
    case "PROTECTED": return "登录可见"
    default: return "仅自己"
    }
}

private struct MemoEditorView: View {
    @ObservedObject var model: MemosModel
    @State private var preview = false
    @State private var importing = false
    @StateObject private var controller = MarkdownEditorController()

    private var isArchived: Bool { model.original?["rowStatus"] as? String == "ARCHIVED" }
    private var isPinned: Bool { (model.original?["pinned"] as? NSNumber)?.boolValue ?? false }
    private var displayTime: String {
        if let ts = (model.original?["displayTs"] as? NSNumber)?.doubleValue, ts > 0 {
            return shortDateTimeLabel(ts, milliseconds: false)
        }
        return "新建草稿"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header matching chosen-memos.png
            HStack(alignment: .center, spacing: 10) {
                Text(model.original == nil ? "写一条说说" : "编辑说说")
                    .font(.system(size: 17, weight: .semibold))
                if let id = model.selectedID {
                    Text("#\(id)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.blogMuted)
                }
                if model.isDirty {
                    StatusBadge(text: "未保存", color: .blogAmber, dot: true)
                }
                if isArchived {
                    StatusBadge(text: "已归档 · 只读", color: .blogMuted, symbol: "archivebox")
                }
                Spacer()
                Text(displayTime)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.blogMuted)
                BlogSegmentedControl(
                    options: [
                        SegmentedOption(value: false, label: "编辑"),
                        SegmentedOption(value: true, label: "预览")
                    ],
                    selection: $preview,
                    compact: true
                )
            }

            // Rounded dark editor container matching chosen-memos.png
            if preview {
                ReaderView(markdown: model.content)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.blogStroke))
            } else {
                VStack(spacing: 0) {
                    HStack {
                        MarkdownToolbar(controller: controller, compact: true, attach: isArchived ? nil : { importing = true })
                        Spacer()
                        Text("\(TextStats.words(model.content)) 字")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Color.blogMuted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blogSurface.opacity(0.5))

                    HairlineDivider()

                    MarkdownTextEditor(
                        text: $model.content,
                        documentID: model.selectedID ?? "new-memo",
                        controller: controller,
                        editable: !(isArchived || model.busy),
                        onImportFiles: isArchived ? nil : { model.importFiles($0) }
                    )
                }
                .background(Color.blogEditor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.blogStroke))
            }

            if !model.resources.isEmpty {
                attachmentsStrip
            }

            // Visibility + Attachment Drop Prompt Row (chosen-memos.png)
            if !isArchived {
                HStack(spacing: 12) {
                    Text("可见性")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.blogMuted)
                    BlogSegmentedControl(
                        options: [
                            SegmentedOption(value: "PUBLIC", label: "公开"),
                            SegmentedOption(value: "PROTECTED", label: "登录可见"),
                            SegmentedOption(value: "PRIVATE", label: "仅自己")
                        ],
                        selection: $model.visibility,
                        compact: true
                    )
                    .disabled(model.busy)

                    Spacer()

                    Button {
                        importing = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "paperclip")
                            Text("拖入图片、音频或视频，或点击添加附件…")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.blogMuted)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                }
            }

            // Bottom Action Row matching chosen-memos.png
            HStack(spacing: 10) {
                Button {
                    model.save()
                } label: {
                    HStack(spacing: 6) {
                        Text("保存")
                        ShortcutCap(text: "⌘S", onPrimary: true)
                    }
                }
                .buttonStyle(BlogPrimaryButtonStyle())
                .disabled(isArchived || model.busy || (!model.isDirty && model.original != nil))

                if model.original != nil {
                    Button(isPinned ? "取消置顶" : "置顶") {
                        model.update(["pinned": !isPinned], title: isPinned ? "取消置顶" : "置顶说说")
                    }
                    .buttonStyle(BlogSecondaryButtonStyle())
                    .disabled(model.busy)

                    Button(isArchived ? "恢复说说" : "归档") {
                        model.update(["rowStatus": isArchived ? "NORMAL" : "ARCHIVED"], title: isArchived ? "恢复说说" : "归档说说")
                    }
                    .buttonStyle(BlogSecondaryButtonStyle())
                    .disabled(model.busy)
                }

                Spacer()

                if model.isDirty {
                    Button("放弃修改") {
                        model.discardThen { model.assign(model.original) }
                    }
                    .buttonStyle(BlogSecondaryButtonStyle())
                    .disabled(model.busy)
                }
            }
        }
        .padding(24)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importFiles(urls)
            case .failure(let error): model.errors["upload"] = error.localizedDescription
            }
        }
    }

    private var attachmentsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.resources.enumerated()), id: \.offset) { index, resource in
                    let isImg = (resource["type"] as? String ?? "").lowercased().hasPrefix("image/")
                    HStack(spacing: 6) {
                        Button {
                            model.openResource(resource)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: isImg ? "photo" : "doc")
                                    .foregroundStyle(Color.blogPeach)
                                Text(resource["filename"] as? String ?? resource["name"] as? String ?? "附件")
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("下载并使用系统默认程序查看附件")

                        if !isArchived {
                            Button {
                                model.resources.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.blogMuted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除附件关联，不删除服务端文件")
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blogSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.blogStroke))
                    .disabled(model.busy)
                }
            }
        }
    }
}
