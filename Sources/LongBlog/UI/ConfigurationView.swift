import SwiftUI

struct StagingReviewView: View {
    @ObservedObject var model: PostsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("审阅并提交暂存文章").font(.system(size: 19, weight: .bold))
                    Text("列表已在打开审阅时冻结。全部变更将合并为单个原子 commit 更新到 main，不会逐篇覆盖远端。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.blogSecondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.busy)
            }

            HairlineDivider()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(model.frozenReview.enumerated()), id: \.offset) { _, row in
                        let act = row["action"] as? String ?? ""
                        Panel {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row["title"] as? String ?? row["id"] as? String ?? "未命名文章")
                                    .font(.system(size: 14.5, weight: .semibold))
                                Spacer()
                                StatusBadge(text: actionLabel(act), color: actionColor(act), pill: true)
                            }
                            Text("ID：\(row["id"] as? String ?? "—")")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Color.blogMuted)
                            let details = row.filter { ["mdPath", "htmlPath", "path", "summary"].contains($0.key) }
                                .keys.sorted().map { "\($0)：\(row[$0]!)" }.joined(separator: "\n")
                            if !details.isEmpty {
                                Text(details)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.blogSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Git 提交说明")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.blogMuted)
                TextField("提交说明", text: $model.commitMessage)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blogField, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.blogStroke))
                    .disabled(model.busy)
                    .accessibilityLabel("文章批量提交说明")
            }

            OperationStatus(model: model)

            HairlineDivider()

            HStack {
                Button("撤销此批暂存…") { model.revert() }
                    .buttonStyle(BlogSecondaryButtonStyle(destructive: true))
                    .disabled(model.busy || model.frozenReview.isEmpty)
                Spacer()
                Text("\(model.frozenReview.count) 项变更 → 1 个 commit → main")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.blogMuted)
                Button("提交到 main…") { model.commit() }
                    .buttonStyle(BlogPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.frozenReview.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 740, height: 600)
        .foregroundStyle(Color.blogText)
        .background(Color.blogBackground)
        .tint(Color.blogPeach)
        .interactiveDismissDisabled(model.busy)
    }

    private func actionLabel(_ value: String) -> String {
        switch value {
        case "publish": return "新增发布"
        case "update": return "内容更新"
        case "unpublish": return "下架归草稿"
        default: return value
        }
    }

    private func actionColor(_ value: String) -> Color {
        switch value {
        case "publish": return .blogGreen
        case "update": return .blogPeach
        case "unpublish": return .blogAmber
        default: return .blogMuted
        }
    }
}

struct ConfigurationWorkspace: View {
    @ObservedObject var model: ConfigurationModel

    var body: some View {
        VStack(spacing: 0) {
            if model.baseline.isEmpty {
                EmptyWorkspace(
                    symbol: "slider.horizontal.3",
                    title: "站点公开配置 (.env)",
                    detail: "从 GitHub 仓库的 main 分支读取 .env 配置。\n仅编辑 PUBLIC_ 公开字段，保留全部注释与未修改行的原始字节。",
                    settings: true,
                    actionTitle: "读取 .env 配置",
                    action: { model.refresh() }
                )
            } else {
                HSplitView {
                    sectionListColumn
                        .frame(minWidth: 270, idealWidth: 320, maxWidth: 365)
                    fieldsArea
                        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay(alignment: .bottom) { OperationStatus(model: model).padding(.bottom, 8) }
        .sheet(isPresented: $model.showingPreview) { configurationReview }
    }

    private var sectionListColumn: some View {
        ScrollView {
            VStack(spacing: 9) {
                ForEach(Array(model.sections.enumerated()), id: \.offset) { index, section in
                    let selected = model.selectedSection == index && model.search.isEmpty
                    let dirtyCount = model.dirtyCount(in: section)
                    Button {
                        withAnimation(.smooth(duration: 0.18)) {
                            model.search = ""
                            model.selectedSection = index
                        }
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.text("title"))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(selected ? Color.blogPeachSoft : Color.blogText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(sectionCountSubtitle(section))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.blogMuted)
                            }
                            Spacer(minLength: 6)
                            if dirtyCount > 0 {
                                StatusBadge(text: "改 \(dirtyCount)", color: .blogPeach, pill: true)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CardButtonStyle(selected: selected, highlighted: dirtyCount > 0))
                    .accessibilityLabel(section.text("title"))
                    .accessibilityValue(dirtyCount > 0 ? "\(sectionCountSubtitle(section))，已修改 \(dirtyCount) 项" : sectionCountSubtitle(section))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(14)
        }
    }

    private func sectionCountSubtitle(_ section: DataRow) -> String {
        let allKeys = section.data["keys"] as? [[String: Any]] ?? []
        if section.flag("friends") {
            let baseCount = (section.data["baseKeyCount"] as? NSNumber)?.intValue ?? 0
            let friendCount = (section.data["friendCount"] as? NSNumber)?.intValue ?? 0
            if baseCount > 0 {
                return "\(baseCount) 项设置 · \(friendCount) 位友链"
            }
            return "\(friendCount) 位友链"
        }
        return "\(allKeys.count) 项设置"
    }

    private var fieldsArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let q = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty {
                    searchResults(q)
                } else if model.sections.indices.contains(model.selectedSection) {
                    sectionForm(model.sections[model.selectedSection])
                }

                Spacer(minLength: 8)

                Text("保留未修改的行与注释；提交后需等待站点流水线完成构建与部署。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.blogMuted)
                    .padding(.top, 8)
            }
            .padding(28)
        }
        .disabled(model.busy)
    }

    @ViewBuilder
    private func searchResults(_ query: String) -> some View {
        let matches: [(sectionTitle: String, field: DataRow)] = model.sections.flatMap { sec -> [(String, DataRow)] in
            let sTitle = sec.text("title")
            let rawKeys = sec.data["keys"] as? [[String: Any]] ?? []
            return rawKeys.compactMap { item in
                let key = item["key"] as? String ?? ""
                let label = item["label"] as? String ?? ""
                let val = model.values[key] ?? ""
                if key.localizedCaseInsensitiveContains(query)
                    || label.localizedCaseInsensitiveContains(query)
                    || val.localizedCaseInsensitiveContains(query) {
                    var copy = item; copy["id"] = key
                    return (sTitle, DataRow(data: copy))
                }
                return nil
            }
        }

        HStack {
            Text("搜索“\(query)” · 找到 \(matches.count) 项")
                .font(.system(size: 18, weight: .bold))
            Spacer()
            Button("清除筛选") { model.search = "" }
                .buttonStyle(BlogSecondaryButtonStyle(compact: true))
        }

        ForEach(matches, id: \.field.id) { pair in
            ConfigField(model: model, field: pair.field, groupPrefix: pair.sectionTitle)
        }
    }

    @ViewBuilder
    private func sectionForm(_ section: DataRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.text("title"))
                .font(.system(size: 20, weight: .bold))
            Spacer()
            if model.isDirty {
                Button("放弃全部修改…") { model.revert() }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
            }
        }

        let rawKeys = (section.data["keys"] as? [[String: Any]] ?? []).map { item -> DataRow in
            var copy = item; copy["id"] = copy["key"]; return DataRow(data: copy)
        }

        if section.flag("friends") {
            let baseFields = rawKeys.filter { $0.data["friendIndex"] == nil }
            let friendFields = rawKeys.filter { $0.data["friendIndex"] != nil }
            let friendIndices = Array(Set(friendFields.compactMap { ($0.data["friendIndex"] as? NSNumber)?.intValue })).sorted()

            if !baseFields.isEmpty {
                ForEach(baseFields) { field in
                    ConfigField(model: model, field: field)
                }
            }

            if !friendIndices.isEmpty {
                HairlineDivider().padding(.vertical, 4)
                Text("友链条目（共 \(friendIndices.count) 位）")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.blogSecondary)

                ForEach(friendIndices, id: \.self) { idx in
                    let group = friendFields.filter { ($0.data["friendIndex"] as? NSNumber)?.intValue == idx }
                    let nameKey = "PUBLIC_FRIEND_\(idx)_NAME"
                    let enabledKey = "PUBLIC_FRIEND_\(idx)_ENABLED"
                    let friendName = model.values[nameKey] ?? ""
                    let isEnabled = !["false", "0"].contains((model.values[enabledKey] ?? "true").lowercased())

                    Panel {
                        HStack {
                            Text(friendName.isEmpty ? "友链 #\(idx)" : "友链 #\(idx) · \(friendName)")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            StatusBadge(text: isEnabled ? "已启用" : "已停用", color: isEnabled ? .blogGreen : .blogMuted, pill: true)
                        }
                        VStack(spacing: 14) {
                            ForEach(group) { field in
                                ConfigField(model: model, field: field)
                            }
                        }
                    }
                }
            }

            Text("提示：现有友链字段可直接修改并提交；新增或删除整组友链序号建议在仓库中编辑。")
                .font(.system(size: 12))
                .foregroundStyle(Color.blogMuted)
        } else {
            ForEach(rawKeys) { field in
                ConfigField(model: model, field: field)
            }
        }
    }

    private var configurationReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("审阅 .env 变更").font(.system(size: 19, weight: .bold))
                    Text("已修改 \(model.changedKeys.count) 项 · \(model.repository) · main")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.blogPeach)
                }
                Spacer()
                Button("返回编辑") { model.showingPreview = false }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.busy)
            }

            HairlineDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.changedKeys, id: \.self) { key in
                        Panel {
                            Text(key)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.blogPeachSoft)
                            Text("− \(model.baselineValues[key] ?? "")")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.9))
                                .textSelection(.enabled)
                            Text("+ \(model.values[key] ?? "")")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Color.blogGreen)
                                .textSelection(.enabled)
                        }
                    }

                    HairlineDivider().padding(.vertical, 4)

                    Text("完整序列化预览").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.blogSecondary)
                    Text(model.preview)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color.blogSecondary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blogField, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.blogStroke))
                }
            }

            OperationStatus(model: model)

            HairlineDivider()

            HStack {
                Text("使用基准文件 SHA 校验冲突，防止意外覆盖远端更新。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.blogMuted)
                Spacer()
                Button("提交到 main…") { model.commit() }
                    .buttonStyle(BlogPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.sha.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 780, height: 620)
        .foregroundStyle(Color.blogText)
        .background(Color.blogBackground)
        .tint(Color.blogPeach)
        .interactiveDismissDisabled(model.busy)
    }
}

private struct ConfigField: View {
    @ObservedObject var model: ConfigurationModel
    let field: DataRow
    var groupPrefix: String? = nil
    @FocusState private var focused: Bool

    private var key: String { field.text("key") }
    private var value: Binding<String> {
        Binding(get: { model.values[key] ?? "" }, set: { model.values[key] = $0 })
    }
    private var dirty: Bool { model.values[key] != model.baselineValues[key] }
    private var isLongText: Bool {
        key.contains("DESCRIPTION") || key.contains("INTRO") || key.contains("TEMPLATE") || (model.values[key]?.count ?? 0) > 48
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Label line matching chosen-config.png ("站点标题 · 已修改")
            HStack(spacing: 6) {
                if let prefix = groupPrefix {
                    Text("\(prefix) ·")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.blogMuted)
                }
                Text(field.text("label"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(dirty ? Color.blogPeachSoft : Color.blogMuted)
                if dirty {
                    Text("· 已修改")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.blogPeach)
                }
                Spacer()
                Text(key)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.blogMuted.opacity(0.78))
                if dirty {
                    Button {
                        model.resetKey(key)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("还原")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color.blogPeach)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("还原为读取时的基准值")
                }
            }

            if field.flag("boolean") {
                HStack {
                    Toggle(
                        "启用此项",
                        isOn: Binding(
                            get: { ["true", "1"].contains(value.wrappedValue.lowercased()) },
                            set: { value.wrappedValue = $0 ? "true" : "false" }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(field.text("label"))
                    Spacer()
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(Color.blogField, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(dirty ? Color.blogPeach.opacity(0.75) : Color.blogStroke)
                )
            } else {
                TextField(field.text("label"), text: value, axis: isLongText ? .vertical : .horizontal)
                    .lineLimit(isLongText ? 2...5 : 1...1)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.blogField, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                dirty ? Color.blogPeach.opacity(0.8) : (focused ? Color.blogPeach.opacity(0.45) : Color.blogStroke),
                                lineWidth: dirty ? 1.2 : 1
                            )
                    )
                    .accessibilityLabel(field.text("label"))
            }

            if !field.text("help").isEmpty && field.text("help") != "友链公开配置" {
                Text(field.text("help"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.blogMuted.opacity(0.85))
            }
        }
        .contextMenu {
            Button("拷贝配置键名") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
            }
            if !value.wrappedValue.isEmpty {
                Button("拷贝当前值") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value.wrappedValue, forType: .string)
                }
            }
            if dirty {
                Divider()
                Button("还原为基准值") { model.resetKey(key) }
            }
        }
    }
}
