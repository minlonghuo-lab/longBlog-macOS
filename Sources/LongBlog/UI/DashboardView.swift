import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("~/longBlog $ status").font(.system(.title2, design: .monospaced)).foregroundStyle(Color.blogPeach)
                    Text(model.refreshed.map { "上次读取：\($0.formatted(date: .abbreviated, time: .shortened)) · 未配置的服务不会显示为在线" } ?? "从站点、仓库与本地工作区读取真实状态").font(.callout).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    MetricCard(title: "文章", value: count("postsCount"), symbol: "doc.text", note: "本地工作区 / GitHub 同步状态")
                    MetricCard(title: "公开说说", value: count("publicMemosCount"), symbol: "quote.bubble", note: "站点公开镜像，不等同于 Memos 私有总数")
                    InboxMetric(model: AppModel.shared.inbox)
                    Panel("连接与权限") {
                        Label("站点、GitHub、留言、Memos 独立配置", systemImage: "key.horizontal")
                        Text("连接成功只由实际请求结果证明；不会使用设计稿中的示例数值。").font(.caption).foregroundStyle(.secondary)
                        Button("管理连接…") { AppModel.shared.showingSettings = true }
                    }
                }
                deployment
                certificates
                if let errors = model.data["errors"] as? [String: String], !errors.isEmpty {
                    Panel("服务读取结果") { ForEach(errors.keys.sorted(), id: \.self) { key in Label("\(key)：\(errors[key] ?? "")", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) } }
                }
            }.padding(26)
        }.safeAreaInset(edge: .bottom) { OperationStatus(model: model) }
    }
    private func count(_ key: String) -> String { (model.data[key] as? NSNumber)?.stringValue ?? "—" }
    private var deployment: some View {
        let head = model.data["head"] as? [String: Any] ?? [:]
        let build = model.data["build"] as? [String: Any] ?? [:]
        let version = model.data["memosVersion"] as? [String: Any] ?? [:]
        return Panel("部署与镜像") {
            HStack { Label("GitHub → main", systemImage: "arrow.triangle.branch"); Spacer(); StatusBadge(text: model.data["deployState"] as? String ?? "尚未读取") }
            LabeledContent("最新提交", value: String((head["sha"] as? String ?? "—").prefix(12)))
            Text(head["message"] as? String ?? "未取得提交信息；请检查仓库与 GitHub 权限。").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            LabeledContent("线上构建时间", value: String(describing: build["builtAt"] ?? "—"))
            LabeledContent("线上构建提交", value: String(describing: build["commit"] ?? "—"))
            if !version.isEmpty { Text("说说镜像：\(version.keys.sorted().map { "\($0)=\(version[$0]!)" }.joined(separator: " · "))").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
    private var certificates: some View {
        let certs = model.data["certs"] as? [String: Any] ?? [:]
        return Panel("HTTPS 证书") {
            if certs.isEmpty { Text("未配置证书域名或尚未取得证书。请在连接设置添加域名。").font(.callout).foregroundStyle(.secondary) }
            ForEach(certs.keys.sorted(), id: \.self) { host in
                HStack {
                    Label(host, systemImage: "lock.shield"); Spacer()
                    if let date = certs[host] as? Date {
                        let days = Int(date.timeIntervalSinceNow / 86400)
                        StatusBadge(text: "\(days) 天 · \(date.formatted(date: .abbreviated, time: .omitted))", color: days > 14 ? .green : .orange)
                    } else { Text(certs[host] as? String ?? "尚未取得").foregroundStyle(.orange).font(.caption) }
                }
            }
        }
    }
}
private struct MetricCard: View {
    let title: String, value: String, symbol: String, note: String
    var body: some View { Panel { HStack { Text(title).font(.headline); Spacer(); Image(systemName: symbol).foregroundStyle(Color.blogPeach) }; Text(value).font(.system(size: 36, weight: .semibold, design: .rounded)); Text(note).font(.caption).foregroundStyle(.secondary) } }
}
private struct InboxMetric: View {
    @ObservedObject var model: InboxModel
    var body: some View { Panel { HStack { Text("终端留言").font(.headline); Spacer(); Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(Color.blogPeach) }; Text(model.loaded && !model.archived ? "\(model.sessions.count)" : "—").font(.system(size: 36, weight: .semibold, design: .rounded)); HStack { Text(model.loaded ? "\(model.unread) 个未读会话" : "尚未读取留言服务").font(.caption).foregroundStyle(.secondary); Spacer(); Button("读取") { if model.archived { model.setArchived(false) } else { model.refresh() } }.disabled(model.busy) }; OperationStatus(model: model) } }
}
