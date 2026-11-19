import SwiftUI
import AppKit

struct PaletteItem: Identifiable {
    let id: String
    let command: String
    let title: String
    let subtitle: String?
    let symbol: String
    let shortcut: String?
    let badge: String?
    let action: () -> Void
}

struct CommandPaletteOverlay: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var posts = AppModel.shared.posts
    @ObservedObject private var inbox = AppModel.shared.inbox
    @ObservedObject private var memos = AppModel.shared.memos
    @ObservedObject private var config = AppModel.shared.configuration

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var inputFocused: Bool

    private var allItems: [PaletteItem] {
        var list: [PaletteItem] = [
            PaletteItem(id: "cmd.newPost", command: "new post", title: "创建新文章", subtitle: "在本地工作区新建 Markdown 草稿", symbol: "plus.square.on.square", shortcut: "⌘N", badge: nil) {
                app.newArticle()
            },
            PaletteItem(id: "cmd.newMemo", command: "new memo", title: "写一条说说", subtitle: "打开说说编辑器记录此刻", symbol: "square.and.pencil", shortcut: "⌘⇧N", badge: nil) {
                app.newMemo()
            },
            PaletteItem(id: "cmd.commitStaged", command: "commit staged", title: "审阅并提交暂存文章", subtitle: posts.staged.isEmpty ? "当前没有待提交的文章变更" : "\(posts.staged.count) 项本地暂存待提交到 main", symbol: "tray.and.arrow.up.fill", shortcut: "⌘⇧P", badge: posts.staged.isEmpty ? nil : "\(posts.staged.count)") {
                if !posts.staged.isEmpty { app.review() } else { app.navigate(.posts) }
            },
            PaletteItem(id: "cmd.focus", command: "focus studio", title: app.focusMode ? "退出专注写作模式" : "进入专注写作工作台", subtitle: "收起外层导航，沉浸式分栏编辑与实时预览", symbol: "arrow.up.left.and.arrow.down.right", shortcut: "⌘⇧F", badge: nil) {
                app.toggleFocusMode()
            },
            PaletteItem(id: "nav.dashboard", command: "deploy status", title: "查看部署与证书状态", subtitle: "跳转到仪表盘", symbol: WorkspaceSection.dashboard.symbol, shortcut: "⌘1", badge: nil) {
                app.navigate(.dashboard)
            },
            PaletteItem(id: "nav.inbox", command: "reply inbox", title: "查看或回复终端留言", subtitle: inbox.loaded ? "\(inbox.sessions.count) 个会话 · \(inbox.unread) 个未读" : "跳转到留言板块", symbol: WorkspaceSection.inbox.symbol, shortcut: "⌘2", badge: inbox.unread > 0 ? "\(inbox.unread)" : nil) {
                app.navigate(.inbox)
            },
            PaletteItem(id: "nav.posts", command: "posts", title: "打开文章列表与工作台", subtitle: posts.loaded ? "共 \(posts.articles.count) 篇文章" : "管理本地草稿与已发布文章", symbol: WorkspaceSection.posts.symbol, shortcut: "⌘3", badge: posts.loaded ? "\(posts.articles.count)" : nil) {
                app.navigate(.posts)
            },
            PaletteItem(id: "nav.memos", command: "memos", title: "浏览说说时间线", subtitle: memos.loaded ? "已载入 \(memos.items.count) 条" : "查看与编辑 legacy Memos", symbol: WorkspaceSection.memos.symbol, shortcut: "⌘4", badge: nil) {
                app.navigate(.memos)
            },
            PaletteItem(id: "nav.config", command: "site config", title: "编辑站点公开配置 (.env)", subtitle: config.isDirty ? "已修改 \(config.changedKeys.count) 项待提交" : "站点标题、导航、SEO 与友链", symbol: WorkspaceSection.configuration.symbol, shortcut: "⌘5", badge: config.isDirty ? "\(config.changedKeys.count)" : nil) {
                app.navigate(.configuration)
            },
            PaletteItem(id: "cmd.sync", command: "git sync", title: "从 GitHub 同步文章", subtitle: "拉取远端 main 分支文章与附件（保留本地草稿）", symbol: "arrow.triangle.2.circlepath", shortcut: nil, badge: nil) {
                app.navigate(.posts)
                posts.sync()
            },
            PaletteItem(id: "cmd.refresh", command: "refresh", title: "刷新当前板块", subtitle: "重新读取 \(app.section.rawValue) 数据", symbol: "arrow.clockwise", shortcut: "⌘R", badge: nil) {
                app.refresh()
            },
            PaletteItem(id: "cmd.theme", command: "theme appearance", title: "切换界面深浅色外观", subtitle: "当前：\(AppAppearance.current.title)", symbol: AppAppearance.current.symbol, shortcut: nil, badge: nil) {
                let next: AppAppearance = AppAppearance.current == .dark ? .light : .dark
                AppAppearance.apply(next)
            },
            PaletteItem(id: "cmd.settings", command: "settings", title: "打开服务与连接设置", subtitle: "配置站点 URL、GitHub、留言、Memos 与本地目录", symbol: "gearshape", shortcut: "⌘,", badge: nil) {
                app.showingSettings = true
            }
        ]

        // Real local articles for instant jump
        for row in posts.articles {
            let title = row.text("title").isEmpty ? "未命名文章" : row.text("title")
            let status = row.flag("publish") ? "已发布" : "草稿"
            let tags = (row.data["tags"] as? [String] ?? []).map { "#\($0)" }.joined(separator: " ")
            list.append(
                PaletteItem(
                    id: "post.\(row.id)",
                    command: "open",
                    title: title,
                    subtitle: [status, tags.isEmpty ? nil : tags].compactMap { $0 }.joined(separator: " · "),
                    symbol: row.flag("publish") ? "doc.text.fill" : "doc.badge.ellipsis",
                    shortcut: nil,
                    badge: status
                ) {
                    app.navigate(.posts)
                    posts.select(row)
                }
            )
        }

        // Loaded config sections
        for (idx, sec) in config.sections.enumerated() {
            list.append(
                PaletteItem(
                    id: "cfg.\(idx)",
                    command: "env",
                    title: "配置分组 · \(sec.text("title"))",
                    subtitle: ".env 公开字段",
                    symbol: "slider.horizontal.3",
                    shortcut: nil,
                    badge: nil
                ) {
                    config.selectedSection = idx
                    app.navigate(.configuration)
                }
            )
        }

        return list
    }

    private var filtered: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(allItems.prefix(9)) }
        return Array(allItems.filter { item in
            item.command.localizedCaseInsensitiveContains(q)
                || item.title.localizedCaseInsensitiveContains(q)
                || (item.subtitle?.localizedCaseInsensitiveContains(q) ?? false)
        }.prefix(12))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                // Terminal-warm prompt bar (Scheme 2 aesthetic)
                HStack(spacing: 10) {
                    Text(">")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blogPeach)
                    TextField("输入命令、搜索本地文章或跳转板块…", text: $query)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .textFieldStyle(.plain)
                        .focused($inputFocused)
                        .onSubmit { executeSelected() }
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.blogMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("ESC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.blogMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.blogSlot, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)

                HairlineDivider()

                if filtered.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.blogMuted)
                        Text("没有匹配的命令或文章")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.blogMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 3) {
                                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                    PaletteRow(item: item, active: index == selectedIndex) {
                                        run(item)
                                    }
                                    .id(item.id)
                                    .onHover { hovering in
                                        if hovering { selectedIndex = index }
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: selectedIndex) { _, idx in
                            if filtered.indices.contains(idx) {
                                proxy.scrollTo(filtered[idx].id, anchor: .center)
                            }
                        }
                    }
                }

                HairlineDivider()

                HStack(spacing: 14) {
                    Label("选择", systemImage: "arrow.up.arrow.down")
                    Label("执行", systemImage: "return")
                    Label("关闭", systemImage: "escape")
                    Spacer()
                    Text("~/longBlog $ palette")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.blogMuted.opacity(0.75))
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.blogMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.blogField.opacity(0.5))
            }
            .frame(width: 580)
            .modifier(CommandPaletteSurfaceModifier())
            .shadow(color: .black.opacity(0.42), radius: 34, y: 16)
            .padding(.top, 84)
        }
        .onAppear {
            selectedIndex = 0
            DispatchQueue.main.async { inputFocused = true }
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onKeyPress(.upArrow) {
            guard !filtered.isEmpty else { return .handled }
            selectedIndex = (selectedIndex - 1 + filtered.count) % filtered.count
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !filtered.isEmpty else { return .handled }
            selectedIndex = (selectedIndex + 1) % filtered.count
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private func executeSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        run(filtered[selectedIndex])
    }

    private func run(_ item: PaletteItem) {
        app.closeCommandPalette(restoreFocus: false)
        item.action()
    }

    private func close() {
        app.closeCommandPalette(restoreFocus: true)
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? Color.blogPeach : Color.blogMuted)
                    .frame(width: 22)
                Text(item.command)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(active ? Color.blogPeachSoft : Color.blogSecondary)
                Text(item.title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(Color.blogText)
                    .lineLimit(1)
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.blogMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let badge = item.badge {
                    StatusBadge(text: badge, color: active ? .blogPeach : .blogMuted)
                }
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(active ? Color.blogPeachSoft : Color.blogMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                active ? Color.blogPeach.opacity(0.20) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CommandPaletteSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(Color.blogBackground.opacity(0.28), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            content
                .background {
                    ZStack {
                        VisualEffectBackground(material: .popover, blendingMode: .withinWindow)
                        Color.blogSidebar.opacity(0.94)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.blogPeach.opacity(0.35), lineWidth: 1)
                )
        }
    }
}
