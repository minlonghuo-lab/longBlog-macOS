import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var posts = AppModel.shared.posts
    @ObservedObject private var inbox = AppModel.shared.inbox

    private let columns = Array(repeating: GridItem(.flexible(minimum: 160), spacing: 16, alignment: .top), count: 4)

    private var siteHost: String {
        if let raw = model.data["siteURL"] as? String, let host = URL(string: raw)?.host, !host.isEmpty {
            return host
        }
        return "longBlog"
    }

    private var postsValue: String {
        if posts.loaded { return String(posts.articles.count) }
        if let n = model.data["postsCount"] as? NSNumber { return n.stringValue }
        return "—"
    }

    private var postsNote: String {
        let ts = (model.data["latestPostAt"] as? NSNumber)?.doubleValue ?? 0
        if ts > 0 { return "最近：\(shortDateTimeLabel(ts))" }
        if let first = posts.articles.first {
            let localTs = max(first.number("updatedAt"), max(first.number("publishedAt"), first.number("createdAt")))
            if localTs > 0 { return "最近：\(shortDateTimeLabel(localTs))" }
        }
        return "本地工作区文章"
    }

    private var memosNote: String {
        let ts = (model.data["latestMemoAt"] as? NSNumber)?.doubleValue ?? 0
        if ts > 0 { return "最近：\(shortDateTimeLabel(ts))" }
        return "站点公开说说镜像"
    }

    private var friendsNote: String {
        if model.data["friendsCount"] is NSNumber { return "从 GitHub .env 读取" }
        guard let configured = model.data["githubConfigured"] as? Bool else { return "正在读取站点配置" }
        return configured ? "正在读取 .env" : "请在连接设置保存 GitHub 令牌"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Subtle warm-terminal header line + greeting
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("~/\(siteHost)")
                                .foregroundStyle(Color.blogPeach)
                            Text("$ status")
                                .foregroundStyle(Color.blogMuted)
                        }
                        .font(.system(size: 12, weight: .medium, design: .monospaced))

                        Text(greeting)
                            .font(.system(size: 25, weight: .bold))
                    }
                    Spacer()
                    if let refreshed = model.refreshed {
                        Text("核验于 \(refreshed.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.blogMuted)
                    }
                }

                // Staged local changes quick banner when present
                if !posts.staged.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "tray.full.fill").foregroundStyle(Color.blogPeach)
                        Text("\(posts.staged.count) 项本地文章变更待提交")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.blogPeachSoft)
                        Text("审阅后合并为一个 commit 提交到 main")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.blogSecondary)
                        Spacer()
                        Button("审阅并提交  ⌘⇧P") { app.review() }
                            .buttonStyle(BlogPrimaryButtonStyle(compact: true))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Color.blogTintPeach, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.blogPeach.opacity(0.32)))
                }

                // 4 Tinted Glass Metric Cards (Scheme 1 exact tint hierarchy)
                LazyVGrid(columns: columns, spacing: 16) {
                    DashboardMetricCard(
                        title: "文章",
                        value: postsValue,
                        note: postsNote,
                        symbol: "doc.text",
                        tint: .blogTintPeach
                    ) {
                        app.navigate(.posts)
                    }

                    DashboardMetricCard(
                        title: "公开说说",
                        value: count("publicMemosCount"),
                        note: memosNote,
                        symbol: "text.bubble",
                        tint: .blogTintTeal
                    ) {
                        app.navigate(.memos)
                    }

                    InboxDashboardCard(model: inbox) {
                        app.navigate(.inbox)
                    }

                    DashboardMetricCard(
                        title: "友链",
                        value: count("friendsCount"),
                        note: friendsNote,
                        symbol: "link",
                        tint: .blogTintRose
                    ) {
                        app.navigate(.configuration)
                    }
                }

                // Asymmetric 1.25 : 1 Deployment + Certificates Grid (Scheme 1)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        deploymentCard.frame(minWidth: 420, idealWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                        certificatesCard.frame(minWidth: 320, idealWidth: 420, maxWidth: 480, maxHeight: .infinity)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 16) {
                        deploymentCard
                        certificatesCard
                    }
                }

                if let errors = model.data["errors"] as? [String: String], !errors.isEmpty {
                    Panel("服务读取提示", symbol: "exclamationmark.triangle") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(errors.keys.sorted(), id: \.self) { key in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.circle")
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Color.blogAmber)
                                        .padding(.top, 2)
                                    Text("\(key)：\(errors[key] ?? "")")
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Color.blogSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .overlay(alignment: .bottom) { OperationStatus(model: model).padding(.bottom, 8) }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 6 ? "夜深了，注意休息" : hour < 12 ? "早上好" : hour < 18 ? "下午好" : "晚上好"
    }

    private func count(_ key: String) -> String {
        (model.data[key] as? NSNumber)?.stringValue ?? "—"
    }

    // MARK: - Deployment Card

    private var deploymentCard: some View {
        let head = model.data["head"] as? [String: Any] ?? [:]
        let build = model.data["build"] as? [String: Any] ?? [:]
        let version = model.data["memosVersion"] as? [String: Any] ?? [:]
        let sha = head["sha"] as? String ?? ""
        let shortSHA = sha.isEmpty ? "—" : String(sha.prefix(7))
        let deployState = model.data["deployState"] as? String ?? "尚未读取部署状态"
        let pending = (model.data["deployPending"] as? NSNumber)?.boolValue ?? false

        let badgeColor: Color = {
            if deployState.contains("已是最新") { return .blogGreen }
            if pending || deployState.contains("等待") || deployState.contains("复核失败") { return .blogAmber }
            return .blogMuted
        }()

        let buildLine: (String, Color) = {
            guard let builtAt = build["builtAt"] as? String, !builtAt.isEmpty else {
                return ("尚未获取线上构建标记", .blogMuted)
            }
            let verified = model.refreshed.map { " · 核验\(relativeTimeLabel($0.timeIntervalSince1970, milliseconds: false))" } ?? ""
            return ("\(formattedISOBuildTime(builtAt))\(verified)", .blogGreen)
        }()

        let heartbeatLine: (String, Color) = {
            if let checked = version["checkedAt"] as? NSNumber {
                let raw = checked.doubleValue
                let ms = raw > 1e11 ? raw : raw * 1000
                return (relativeTimeLabel(ms), .blogGreen)
            }
            return ("尚未获取镜像心跳", .blogMuted)
        }()

        return Panel("部署") {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    Text("最近提交").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if !sha.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sha, forType: .string)
                            model.flash("copy", "已复制提交 SHA：\(shortSHA)")
                        } label: {
                            HStack(spacing: 5) {
                                Text(shortSHA)
                                    .font(.system(size: 13.5, design: .monospaced))
                                    .foregroundStyle(Color.blogSecondary)
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Color.blogMuted)
                            }
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("点击复制完整提交哈希")
                    } else {
                        Text("—")
                            .font(.system(size: 13.5, design: .monospaced))
                            .foregroundStyle(Color.blogMuted)
                    }
                }

                Text(head["message"] as? String ?? "未读取到仓库提交记录；配置 GitHub 仓库与令牌后可比对线上构建。")
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(Color.blogSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)

                HairlineDivider().padding(.vertical, 2)

                HStack {
                    Text("线上构建").font(.system(size: 13.5)).foregroundStyle(Color.blogText)
                    Spacer()
                    Text(buildLine.0).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(buildLine.1)
                }

                if let commit = build["commit"] as? String, !commit.isEmpty {
                    HStack {
                        Text("线上版本提交").font(.system(size: 13.5)).foregroundStyle(Color.blogText)
                        Spacer()
                        Text(String(commit.prefix(7)))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.blogSecondary)
                    }
                }

                HStack {
                    Text("说说镜像心跳").font(.system(size: 13.5)).foregroundStyle(Color.blogText)
                    Spacer()
                    Text(heartbeatLine.0).font(.system(size: 13, weight: .medium)).foregroundStyle(heartbeatLine.1)
                }

                Spacer(minLength: 10)

                StatusBadge(text: deployState, color: badgeColor, dot: true, pill: true)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Certificates Card

    private var certificatesCard: some View {
        let certs = model.data["certs"] as? [String: Any] ?? [:]
        return Panel("HTTPS 证书") {
            VStack(alignment: .leading, spacing: 14) {
                if certs.isEmpty {
                    Text("尚未取得证书到期时间。点击右上角刷新或前往连接设置核对监控域名。")
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(Color.blogMuted)
                } else {
                    ForEach(certs.keys.sorted(), id: \.self) { host in
                        HStack(spacing: 10) {
                            Text(host)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color.blogText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            if let date = certs[host] as? Date {
                                let days = Int(date.timeIntervalSinceNow / 86400)
                                let color: Color = days > 21 ? .blogGreen : (days > 7 ? .blogAmber : .red)
                                let label = days > 30 ? "正常 · \(days) 天" : "剩 \(days) 天"
                                StatusBadge(text: label, color: color, pill: true)
                                    .help("到期日：\(date.formatted(date: .abbreviated, time: .omitted))")
                            } else {
                                StatusBadge(text: certs[host] as? String ?? "待复核", color: .blogAmber, pill: true)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct DashboardMetricCard: View {
    let title: String
    let value: String
    let note: String
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.blogSecondary)
                    Spacer()
                    Image(systemName: hovering ? "arrow.up.right" : symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.blogPeach.opacity(hovering ? 1 : 0.78))
                }
                Text(value)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.blogText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.blogMuted)
                    .lineLimit(1)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(hovering ? Color.blogPeach.opacity(0.4) : Color.blogStroke)
            )
            .offset(y: hovering ? -1.5 : 0)
            .animation(.easeOut(duration: 0.14), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointingHandCursor()
    }
}

private struct InboxDashboardCard: View {
    @ObservedObject var model: InboxModel
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("终端留言")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.blogSecondary)
                Spacer()
                if !model.loaded {
                    Button("读取") {
                        if model.archived { model.setArchived(false) } else { model.refresh() }
                    }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                    .disabled(model.busy)
                } else {
                    Image(systemName: hovering ? "arrow.up.right" : "bubble.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.unread > 0 ? Color.blogPeach : Color.blogPeach.opacity(0.78))
                }
            }
            Button(action: action) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.loaded && !model.archived ? "\(model.sessions.count)" : "—")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.blogText)
                    Text(model.loaded ? (model.unread > 0 ? "\(model.unread) 个未读会话" : "进行中的会话") : "尚未读取留言服务")
                        .font(.system(size: 12))
                        .foregroundStyle(model.unread > 0 ? Color.blogPeachSoft : Color.blogMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blogTintPurple, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(hovering ? Color.blogPeach.opacity(0.4) : Color.blogStroke)
        )
        .offset(y: hovering ? -1.5 : 0)
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}
