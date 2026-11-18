import SwiftUI

struct StagingReviewView: View {
    @ObservedObject var model: PostsModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("审阅文章暂存").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() }.disabled(model.busy) }
            Text("此列表在打开审阅时冻结。提交复用 Core 的快照、非强制更新、pending 恢复与附件保护；撤销复用 opaque revertGuard。").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(model.frozenReview.enumerated()), id: \.offset) { _, row in
                        Panel {
                            HStack { Text(row["title"] as? String ?? row["id"] as? String ?? "文章").font(.headline); Spacer(); StatusBadge(text: action(row["action"] as? String ?? "")) }
                            Text("ID：\(row["id"] as? String ?? "—")").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(row.filter { ["mdPath", "htmlPath", "path", "summary"].contains($0.key) }.keys.sorted().map { "\($0)：\(row[$0]!)" }.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            TextField("提交说明", text: $model.commitMessage).textFieldStyle(.roundedBorder).disabled(model.busy).accessibilityLabel("文章批量提交说明")
            OperationStatus(model: model)
            HStack { Button("撤销此批暂存…", role: .destructive) { model.revert() }; Spacer(); Text("\(model.frozenReview.count) 项 → 一个 commit → main").font(.caption).foregroundStyle(.secondary); Button("提交到 main…") { model.commit() }.buttonStyle(.borderedProminent) }.disabled(model.busy || model.frozenReview.isEmpty)
        }.padding(24).frame(width: 740, height: 590).background(Color.blogBackground).tint(.blogPeach).interactiveDismissDisabled(model.busy)
    }
    private func action(_ value: String) -> String { switch value { case "publish": return "发布"; case "update": return "更新"; case "unpublish": return "下架"; default: return value } }
}

struct ConfigurationWorkspace: View {
    @ObservedObject var model: ConfigurationModel
    var body: some View {
        VStack(spacing: 0) {
            if model.baseline.isEmpty {
                EmptyWorkspace(symbol: "slider.horizontal.3", title: "站点公开配置", detail: "从 GitHub 仓库的 main 分支读取 .env。仅允许 PUBLIC_ 字段，未修改的行和注释保持原样。", settings: true)
                Button("读取 .env") { model.refresh() }.disabled(model.busy).padding()
            } else {
                HSplitView {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(model.sections.enumerated()), id: \.offset) { index, section in
                                Button { model.selectedSection = index } label: {
                                    HStack { Image(systemName: section.flag("friends") ? "person.2" : "slider.horizontal.3"); Text(section.text("title")); Spacer() }.padding(13).contentShape(Rectangle())
                                }.buttonStyle(.plain).background(model.selectedSection == index ? Color.blogPeach.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }
                        }.padding(12)
                    }.frame(minWidth: 290, idealWidth: 310, maxWidth: 350)
                    fields
                }
            }
            OperationStatus(model: model)
        }.sheet(isPresented: $model.showingPreview) { configurationReview }
    }
    private var fields: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.sections.indices.contains(model.selectedSection) {
                    let section = model.sections[model.selectedSection]
                    HStack { Text(section.text("title")).font(.title2.bold()); Spacer(); Button("放弃修改…") { model.revert() }.disabled(!model.isDirty) }
                    Text("\(model.repository) · main · .env").font(.caption.monospaced()).foregroundStyle(.secondary)
                    ForEach((section.data["keys"] as? [[String: Any]] ?? []).map { item -> DataRow in var copy = item; copy["id"] = copy["key"]; return DataRow(data: copy) }) { field in
                        ConfigField(model: model, field: field)
                    }
                    if section.flag("friends") { Text("现有友链字段可直接编辑。新增与移除整组友链目前请在仓库编辑，以避免意外重排行。").font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(24)
        }.disabled(model.busy)
    }
    private var configurationReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("审阅 .env 变更").font(.title2.bold()); Spacer(); Button("返回编辑") { model.showingPreview = false }.disabled(model.busy) }
            Text("已修改 \(model.changedKeys.count) 项 · \(model.repository) · main").font(.callout).foregroundStyle(Color.blogPeach)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.changedKeys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) { Text(key).font(.caption.monospaced().bold()); Text("− \(model.baselineValues[key] ?? "")").foregroundStyle(.red); Text("+ \(model.values[key] ?? "")").foregroundStyle(.green) }.font(.callout).textSelection(.enabled)
                    }
                    Divider(); Text("完整序列化预览").font(.headline)
                    Text(model.preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            OperationStatus(model: model)
            HStack { Text("保留未改动的行，使用文件 SHA 防止覆盖冲突。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("提交到 main…") { model.commit() }.buttonStyle(.borderedProminent).disabled(model.busy || model.sha.isEmpty) }
        }.padding(24).frame(width: 780, height: 610).background(Color.blogBackground).tint(.blogPeach).interactiveDismissDisabled(model.busy)
    }
}
private struct ConfigField: View {
    @ObservedObject var model: ConfigurationModel
    let field: DataRow
    private var key: String { field.text("key") }
    private var value: Binding<String> { Binding(get: { model.values[key] ?? "" }, set: { model.values[key] = $0 }) }
    private var dirty: Bool { model.values[key] != model.baselineValues[key] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(field.text("label")).font(.headline); Spacer(); if dirty { StatusBadge(text: "已修改") } }
            if field.flag("boolean") { Toggle("启用", isOn: Binding(get: { ["true", "1"].contains(value.wrappedValue.lowercased()) }, set: { value.wrappedValue = $0 ? "true" : "false" })) }
            else { TextField("字段值", text: value, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder).accessibilityLabel(field.text("label")) }
            Text(key).font(.caption.monospaced()).foregroundStyle(.tertiary)
            if !field.text("help").isEmpty { Text(field.text("help")).font(.caption).foregroundStyle(.secondary) }
        }.padding(15).background(Color.blogSurface, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(dirty ? Color.blogPeach.opacity(0.6) : Color.blogStroke))
    }
}
