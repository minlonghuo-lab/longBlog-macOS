import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    private let columns = Array(repeating: GridItem(.flexible(minimum: 140), spacing: 16, alignment: .top), count: 4)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting).font(.system(size: 26, weight: .bold))
                    Text(model.refreshed.map { "上次读取：\($0.formatted(date: .abbreviated, time: .shortened)) · 未配置的服务不会显示为在线" } ?? "从站点、仓库与本地工作区读取真实状态").font(.callout).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    MetricCard(title: "文章", value: count("postsCount"), symbol: "doc.text", note: "本地工作区 / GitHub 同步状态")
                    MetricCard(title: "公开说说", value: count("publicMemosCount"), symbol: "quote.bubble", note: "站点公开镜像，不等同于 Memos 私有总数")
                    InboxMetric(model: AppModel.shared.inbox)
                    MetricCard(title: "友链", value: count("friendsCount"), symbol: "link", note: "从 GitHub 站点配置读取")
                }
                HStack(alignment: .top, spacing: 18) {
                    deployment.frame(maxWidth: .infinity)
                    certificates.frame(maxWidth: .infinity)
                }
                if let errors = model.data["errors"] as? [String: String], !errors.isEmpty {
                    Panel("服务读取结果", symbol: "exclamationmark.triangle") { ForEach(errors.keys.sorted(), id: \.self) { key in Label("\(key)：\(errors[key] ?? "")", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) } }
                }
            }.padding(26)
        }.overlay(alignment: .bottom) { OperationStatus(model: model).padding(.bottom, 8) }
    }
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 6 ? "夜深了，注意休息" : hour < 12 ? "早上好" : hour < 18 ? "下午好" : "晚上好"
    }
    private func count(_ key: String) -> String { (model.data[key] as? NSNumber)?.stringValue ?? "—" }
    private var deployment: some View {
        let head = model.data["head"] as? [String: Any] ?? [:]
        let build = model.data["build"] as? [String: Any] ?? [:]
        let version = model.data["memosVersion"] as? [String: Any] ?? [:]
        return Panel("部署与镜像", symbol: "shippingbox") {
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
        return Panel("HTTPS 证书", symbol: "lock.shield") {
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
private struct MetricHeader: View {
    let title: String, symbol: String
    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.blogPeach)
                .frame(width: 28, height: 28).background(Color.blogPeach.opacity(0.14), in: Circle())
        }
    }
}
private struct MetricCard: View {
    let title: String, value: String, symbol: String, note: String
    var body: some View { Panel { MetricHeader(title: title, symbol: symbol); Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit(); Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2) } }
}
private struct InboxMetric: View {
    @ObservedObject var model: InboxModel
    var body: some View { Panel { MetricHeader(title: "终端留言", symbol: "bubble.left.and.bubble.right"); Text(model.loaded && !model.archived ? "\(model.sessions.count)" : "—").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit(); HStack { Text(model.loaded ? "\(model.unread) 个未读会话" : "尚未读取留言服务").font(.caption).foregroundStyle(.secondary); Spacer(); Button("读取") { if model.archived { model.setArchived(false) } else { model.refresh() } }.controlSize(.small).disabled(model.busy) } } }
}
