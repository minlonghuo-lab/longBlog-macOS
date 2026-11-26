import SwiftUI
import AppKit
import QuartzCore

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var app = AppModel.shared
    @ObservedObject private var posts = AppModel.shared.posts
    @ObservedObject private var inbox = AppModel.shared.inbox
    @ObservedObject private var memos = AppModel.shared.memos
    @ObservedObject private var configuration = AppModel.shared.configuration
    @ObservedObject private var dashboard = AppModel.shared.dashboard

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchFocusRequest = UUID()

    private var sidebarShouldHide: Bool {
        app.sidebarCollapsed
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebar(app: app)
                .navigationSplitViewColumnWidth(min: 214, ideal: 234, max: 268)
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1020, maxWidth: .infinity, minHeight: 660, maxHeight: .infinity)
        .foregroundStyle(Color.blogText)
        .tint(Color.blogPeach)
        .onAppear {
            columnVisibility = sidebarShouldHide ? .detailOnly : .all
            (NSApp.delegate as? LongBlogAppDelegate)?.suppressTitlebarHoverHighlight()
        }
        .onChange(of: app.section) { _, _ in
            (NSApp.delegate as? LongBlogAppDelegate)?.suppressTitlebarHoverHighlight()
        }
        .onChange(of: sidebarShouldHide) { _, hide in
            let target: NavigationSplitViewVisibility = hide ? .detailOnly : .all
            if columnVisibility != target {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    columnVisibility = target
                }
            }
        }
        .onChange(of: columnVisibility) { _, vis in
            // Keep app state synced when the user clicks macOS's native toolbar sidebar button.
            if vis == .all {
                if app.sidebarCollapsed { app.sidebarCollapsed = false }
            } else if vis == .detailOnly {
                if !app.sidebarCollapsed { app.sidebarCollapsed = true }
            }
        }
        .onChange(of: app.searchRequested) {
            if [.inbox, .memos, .configuration].contains(app.section) {
                searchFocusRequest = UUID()
            }
        }
        .task {
            // Defer initial IO until after first layout pass so the window renders instantaneously.
            app.refreshIfNeeded()
        }
        .task(id: app.section) {
            app.checkVisibleSection()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                app.checkVisibleSection()
            }
        }
        .sheet(isPresented: $app.showingSettings) { ConnectionSettingsView() }
        .sheet(isPresented: $app.showingReview) { StagingReviewView(model: app.posts) }
    }

    @ViewBuilder private var detailColumn: some View {
        let base = sectionContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AmbientCanvasBackground().ignoresSafeArea() }
            .navigationTitle(toolbarTitle)
            .navigationSubtitle(statusSubtitle.text)
            .toolbar {
                // Keep toolbar item structure & sharedBackgroundVisibility 100% static across
                // all sections so NSToolbar never rebuilds or flashes NSScrollPocket on switch.
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .principal) {
                        toolbarCenterControls
                    }
                    .sharedBackgroundVisibility(.hidden)

                    ToolbarItem(placement: .primaryAction) { toolbarActions }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) { toolbarCenterControls }
                    ToolbarItem(placement: .primaryAction) { toolbarActions }
                }
                #else
                ToolbarItem(placement: .principal) { toolbarCenterControls }
                ToolbarItem(placement: .primaryAction) { toolbarActions }
                #endif
            }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            base
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .scrollEdgeEffectHidden(true, for: .top)
        } else if #available(macOS 15.0, *) {
            base
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            base
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        #else
        if #available(macOS 15.0, *) {
            base
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            base
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        #endif
    }

    // MARK: - Persistent Section Host (AppKit isHidden Isolation + GPU CATransition)

    @ViewBuilder private var sectionContent: some View {
        PersistentSectionHost(activeSection: app.section, app: app)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar Metadata & Controls

    private var search: Binding<String> {
        Binding(
            get: {
                switch app.section {
                case .posts: return posts.search
                case .inbox: return inbox.search
                case .memos: return memos.search
                case .configuration: return configuration.search
                case .dashboard: return ""
                }
            },
            set: { value in
                switch app.section {
                case .posts: posts.search = value
                case .inbox: inbox.search = value
                case .memos: memos.search = value
                case .configuration: configuration.search = value
                case .dashboard: break
                }
            }
        )
    }

    private var dashboardHostLabel: String {
        let raw = dashboard.data["siteURL"] as? String ?? ""
        if let host = URL(string: raw)?.host, !host.isEmpty { return host }
        return "本地与站点概览"
    }

    private var statusSubtitle: (dot: Color?, text: String, tint: Color) {
        switch app.section {
        case .dashboard:
            let build = dashboard.data["build"] as? [String: Any] ?? [:]
            let pending = (dashboard.data["deployPending"] as? NSNumber)?.boolValue ?? false
            if pending {
                return (.blogAmber, "部署流水线构建中 · \(dashboardHostLabel)", .blogAmber)
            }
            if !build.isEmpty {
                return (.blogGreen, "站点运行中 · \(dashboardHostLabel)", .blogGreen)
            }
            if let refreshed = dashboard.refreshed {
                return (nil, "上次读取 \(refreshed.formatted(date: .omitted, time: .shortened)) · \(dashboardHostLabel)", .blogMuted)
            }
            return (nil, "从站点、仓库与本地工作区读取真实状态", .blogMuted)
        case .posts:
            return (nil, posts.loaded ? "共 \(posts.articles.count) 篇 · \(posts.folder)" : "本地 Markdown 工作区", .blogMuted)
        case .inbox:
            if inbox.loaded {
                let syncInfo = inbox.lastSync.map { " · 已同步 \(relativeTimeLabel($0.timeIntervalSince1970, milliseconds: false))" } ?? ""
                let base = inbox.archived ? "\(inbox.sessions.count) 个归档会话" : "\(inbox.sessions.count) 个进行中的会话"
                return (inbox.unread > 0 ? .blogPeach : nil, base + syncInfo, .blogMuted)
            }
            return (nil, "访客终端实时对话与归档记录", .blogMuted)
        case .memos:
            if memos.loaded {
                let who = memos.username.isEmpty ? "" : "@\(memos.username) · "
                return (nil, "\(who)共 \(memos.items.count)\(memos.more ? "+" : "") 条 · \(memos.archived ? "归档" : "时间线")", .blogMuted)
            }
            return (nil, "legacy Memos 时间线与私密记录", .blogMuted)
        case .configuration:
            let repo = configuration.repository.isEmpty ? ((dashboard.data["repo"] as? String) ?? "GitHub") : configuration.repository
            return (nil, "\(repo) · main · .env", .blogMuted)
        }
    }

    private var busy: Bool {
        switch app.section {
        case .dashboard: return dashboard.busy
        case .posts: return posts.busy
        case .inbox: return inbox.busy
        case .memos: return memos.busy
        case .configuration: return configuration.busy
        }
    }

    private var toolbarTitle: String {
        if app.section == .inbox { return "终端留言" }
        return app.section.rawValue
    }

    @ViewBuilder private var toolbarCenterControls: some View {
        ZStack {
            switch app.section {
            case .dashboard:
                Color.clear
                    .frame(width: 1, height: 30)

            case .posts:
                BlogSegmentedControl(
                    title: "文章状态",
                    options: [
                        SegmentedOption(value: "全部", label: "全部", count: posts.loaded ? posts.articles.count : nil),
                        SegmentedOption(value: "草稿", label: "草稿", count: posts.loaded ? posts.draftCount : nil),
                        SegmentedOption(value: "已发布", label: "已发布", count: posts.loaded ? posts.publishedCount : nil)
                    ],
                    selection: $posts.filter,
                    compact: false
                )

            case .inbox:
                toolbarSearchPill(prompt: "搜索会话或留言", label: "搜索当前板块")

            case .memos:
                toolbarSearchPill(prompt: "搜索说说", label: "搜索当前板块") {
                    memos.load()
                }

            case .configuration:
                HStack(spacing: 8) {
                    if !configuration.baseline.isEmpty {
                        toolbarSearchPill(prompt: "筛选配置项", label: "搜索配置项")
                    } else {
                        Color.clear.frame(width: 1, height: 30)
                    }
                    if configuration.isDirty {
                        StatusBadge(text: "已修改 \(configuration.changedKeys.count) 项", color: .blogPeach, pill: true)
                    }
                }
            }
        }
        .frame(minHeight: 30)
        .transaction { $0.animation = nil }
    }

    private func toolbarSearchPill(prompt: String, label: String, onSubmit: @escaping () -> Void = {}) -> some View {
        SearchField(prompt: prompt, text: search, focusRequest: searchFocusRequest, borderless: true, onSubmit: onSubmit)
            .padding(.horizontal, 10)
            .frame(width: 224, height: 30)
            .background(Capsule().fill(Color.blogSlot))
            .overlay(Capsule().strokeBorder(Color.blogStrokeStrong, lineWidth: 0.8))
            .accessibilityLabel(label)
    }

    private var toolbarActions: some View {
        BlogGlassGroup(spacing: 8) {
            Button {
                app.showingShortcutsHelp.toggle()
            } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(BlogSecondaryButtonStyle(large: true, shape: .circle))
            .accessibilityLabel("快捷键帮助")
            .help("查看快捷键指南  ⌘/")
            .popover(isPresented: $app.showingShortcutsHelp, arrowEdge: .bottom) {
                ShortcutsHelpPopover()
            }

            Button { app.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(busy ? 0.45 : 1.0)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(BlogSecondaryButtonStyle(large: true, shape: .circle))
            .accessibilityLabel("刷新当前板块")
            .help("刷新当前板块  ⌘R")
            .disabled(busy)

            primaryAction
        }
        .fixedSize()
        .padding(.trailing, 22)
    }

    @ViewBuilder private var primaryAction: some View {
        switch app.section {
        case .dashboard:
            Button("新建文章") { app.newArticle() }
            .buttonStyle(BlogPrimaryButtonStyle(large: true))
            .disabled(posts.busy)
            .help("新建文章  ⌘N")

        case .posts:
            Button("新建文章") { app.newArticle() }
            .buttonStyle(BlogPrimaryButtonStyle(large: true))
            .disabled(posts.busy)
            .help("新建文章  ⌘N")

        case .memos:
            Button("写说说") { app.newMemo() }
            .buttonStyle(BlogPrimaryButtonStyle(large: true))
            .disabled(memos.busy)
            .help("写说说  ⌘⇧N")

        case .configuration:
            Button("提交到 main…") { configuration.review() }
            .buttonStyle(BlogPrimaryButtonStyle(large: true))
            .disabled(!configuration.isDirty || configuration.busy)
            .help("审阅并提交配置变更  ⌘S")

        case .inbox:
            Button { inbox.setArchived(!inbox.archived) } label: {
                Label(inbox.archived ? "返回进行中" : "归档记录", systemImage: inbox.archived ? "tray" : "archivebox")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(BlogSecondaryButtonStyle(large: true))
            .disabled(inbox.busy)
        }
    }
}

// MARK: - Official Tahoe Floating Liquid Glass Sidebar

private struct WorkspaceSidebar: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var posts = AppModel.shared.posts
    @ObservedObject private var inbox = AppModel.shared.inbox
    @ObservedObject private var memos = AppModel.shared.memos
    @ObservedObject private var dashboard = AppModel.shared.dashboard
    @ObservedObject private var config = AppModel.shared.configuration
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.dark.rawValue
    @State private var settingsHover = false

    private var repoLine: String {
        let repo = (dashboard.data["repo"] as? String) ?? config.repository
        return repo.isEmpty ? "本地博客工作台" : repo
    }

    private var branchLine: String {
        let head = dashboard.data["head"] as? [String: Any] ?? [:]
        if let sha = head["sha"] as? String, !sha.isEmpty {
            return "main · \(sha.prefix(7))"
        }
        if !posts.staged.isEmpty {
            return "main · \(posts.staged.count) 项暂存"
        }
        return "main · 本地就绪"
    }

    var body: some View {
        List {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blogPeach.opacity(0.20))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.blogPeach.opacity(0.38)))
                    Image(systemName: "terminal")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.blogPeach)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("longBlog")
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(0.2)
                    Text("macOS Studio")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.blogMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .padding(.bottom, 4)
            .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section {
                ForEach(Array(WorkspaceSection.allCases.enumerated()), id: \.element) { index, section in
                    SidebarItemRow(
                        section: section,
                        selected: app.section == section,
                        badge: badge(section),
                        highlight: (section == .inbox && inbox.unread > 0) || (section == .posts && !posts.staged.isEmpty),
                        dirtyDot: isSectionDirty(section),
                        shortcut: "⌘\(index + 1)"
                    ) {
                        app.navigate(section)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                Button {
                    app.showingSettings = true
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(!posts.staged.isEmpty ? Color.blogPeach : Color.blogGreen)
                            .frame(width: 6.5, height: 6.5)
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text(repoLine)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.blogText.opacity(0.92))
                                .lineLimit(1)
                                .minimumScaleFactor(0.88)
                            Text(branchLine)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.blogMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .background(
                        settingsHover ? Color.blogSurfaceHover : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .onHover { settingsHover = $0 }
                .pointingHandCursor()
                .help("服务与连接设置  ⌘,")
                .accessibilityLabel("连接设置")

                Rectangle()
                    .fill(Color.blogDivider)
                    .frame(width: 1, height: 22)
                    .padding(.horizontal, 1)

                HStack(spacing: 3) {
                    SidebarFooterIconButton(
                        symbol: "gearshape",
                        help: "服务与连接设置  ⌘,",
                        accessibilityLabel: "连接设置"
                    ) {
                        app.showingSettings = true
                    }

                    SidebarFooterIconButton(
                        symbol: AppAppearance(rawValue: appearance)?.symbol ?? "moon.stars.fill",
                        help: "切换深浅色模式",
                        accessibilityLabel: "切换深浅色模式"
                    ) {
                        let next: AppAppearance = AppAppearance.current == .dark ? .light : .dark
                        appearance = next.rawValue
                        AppAppearance.apply(next)
                    }
                }
            }
            .padding(5)
            .background(Color.blogSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.blogStroke))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    private func isSectionDirty(_ section: WorkspaceSection) -> Bool {
        switch section {
        case .posts: return posts.isDirty
        case .memos: return memos.isDirty
        case .configuration: return config.isDirty
        case .inbox: return !inbox.reply.isEmpty
        case .dashboard: return false
        }
    }

    private func badge(_ section: WorkspaceSection) -> String? {
        switch section {
        case .inbox:
            if inbox.unread > 0 { return "\(inbox.unread)" }
            return inbox.loaded ? "0" : nil
        case .posts:
            if posts.loaded { return "\(posts.articles.count)" }
            if let n = dashboard.data["postsCount"] as? NSNumber { return n.stringValue }
            return nil
        case .memos:
            if memos.loaded { return "\(memos.items.count)\(memos.more ? "+" : "")" }
            if let n = dashboard.data["publicMemosCount"] as? NSNumber { return n.stringValue }
            return nil
        case .configuration:
            return config.isDirty ? "\(config.changedKeys.count)" : nil
        case .dashboard:
            return nil
        }
    }
}

private struct SidebarItemRow: View {
    let section: WorkspaceSection
    let selected: Bool
    let badge: String?
    let highlight: Bool
    let dirtyDot: Bool
    let shortcut: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var accessibilityValueText: String {
        var parts: [String] = []
        if let badge, !badge.isEmpty { parts.append("\(badge) 项") }
        if dirtyDot { parts.append("有未保存修改") }
        return parts.joined(separator: "，")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.blogPeach : Color.blogSecondary)
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.blogText : Color.blogSecondary)
                if dirtyDot {
                    Circle().fill(Color.blogPeach).frame(width: 5.5, height: 5.5)
                }
                Spacer()
                if let badge = badge {
                    if highlight {
                        Text(badge)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.blogPeachInk)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 1.5)
                            .background(Color.blogPeach, in: Capsule())
                    } else {
                        Text(badge)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(selected ? Color.blogPeachSoft : Color.blogMuted)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.blogPeach.opacity(0.18) : (hovering ? Color.blogSurfaceHover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.blogPeach.opacity(0.32) : .clear)
            )
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: selected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .help("\(section.rawValue)  \(shortcut)")
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(accessibilityValueText)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct SidebarFooterIconButton: View {
    let symbol: String
    let help: String
    let accessibilityLabel: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? Color.blogPeach : Color.blogSecondary)
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(
                    hovering ? Color.blogSurfaceHover : Color.blogSlot,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ShortcutsHelpPopover: View {
    private struct Item: Identifiable {
        let key: String
        let label: String
        var id: String { key + label }
    }

    private let groups: [(title: String, symbol: String, items: [Item])] = [
        ("工作区导航", "sidebar.left", [
            Item(key: "⌘1 ～ ⌘5", label: "切换仪表盘 / 留言 / 文章 / 说说 / 配置"),
            Item(key: "⌘[ / ⌘]", label: "切换当前列表上一项 / 下一项（或 ↑ / ↓）"),
            Item(key: "⌘\\", label: "显示或收起左侧导航栏"),
            Item(key: "⌃⌘Z", label: "窗口铺满屏幕 / 还原默认尺寸")
        ]),
        ("创作与同步", "square.and.pencil", [
            Item(key: "⌘N", label: "新建本地 Markdown 文章"),
            Item(key: "⌘⇧N", label: "新建一条说说"),
            Item(key: "⌘⇧A", label: "打开文章 AI 写作辅助"),
            Item(key: "⌘S", label: "保存当前修改 / 审阅配置"),
            Item(key: "⌘⇧P", label: "审阅并批量提交暂存文章"),
            Item(key: "⌘R", label: "刷新当前板块状态")
        ]),
        ("阅读与写作布局", "rectangle.split.2x1", [
            Item(key: "⌘E", label: "切换文章阅读 / 编辑模式"),
            Item(key: "⌘⌥R", label: "文章阅读视图"),
            Item(key: "⌘⌥E", label: "文章纯编辑视图"),
            Item(key: "⌘⌥P", label: "文章编辑 + 实时预览分栏")
        ]),
        ("查找与设置", "gearshape", [
            Item(key: "⌘F", label: "搜索当前列表或编辑器内查找"),
            Item(key: "⌘,", label: "打开服务与连接设置"),
            Item(key: "⌘/", label: "显示或隐藏此快捷键指南")
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.blogPeach)
                Text("快捷键指南")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.blogText)
                Spacer()
            }

            ForEach(Array(groups.enumerated()), id: \.offset) { idx, group in
                if idx > 0 {
                    HairlineDivider()
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: group.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.blogPeach)
                        Text(group.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.blogMuted)
                    }
                    ForEach(group.items) { item in
                        HStack(spacing: 12) {
                            Text(item.label)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.blogSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 10)
                            Text(item.key)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.blogPeachSoft)
                                .fixedSize()
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.blogSlot, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.blogStroke))
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 384)
        .background {
            if #unavailable(macOS 26.0) {
                Color.blogBackground
            }
        }
    }
}

// MARK: - Persistent Section Host (AppKit View Isolation + GPU CATransition)

/// Hosts all 5 workspace sections inside isolated AppKit `NSHostingView` subviews so:
/// 1. Only the active section is visible (`isHidden == false`), preventing multiple
///    `HSplitView`s from fighting over safe-area or shifting left/up during transitions.
/// 2. Hidden sections stay mounted in memory (zero `WKWebView` / editor / scroll reset).
/// 3. Section switches use a WindowServer GPU `CATransition(.fade)` on the container layer
///    after pre-laying out the incoming subview at exact bounds (zero layout jump or flash).
private struct PersistentSectionHost: NSViewRepresentable {
    let activeSection: WorkspaceSection
    let app: AppModel

    func makeNSView(context: Context) -> SectionContainerView {
        SectionContainerView(app: app, initialSection: activeSection)
    }

    func updateNSView(_ container: SectionContainerView, context: Context) {
        container.select(activeSection)
    }
}

@MainActor
private final class SectionContainerView: NSView {
    private var hosts: [WorkspaceSection: NSHostingView<AnyView>] = [:]
    private var currentSection: WorkspaceSection

    init(app: AppModel, initialSection: WorkspaceSection) {
        self.currentSection = initialSection
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        for section in WorkspaceSection.allCases {
            let root = AnyView(
                Self.makeSectionView(section, app: app)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(Color.blogText)
                    .tint(Color.blogPeach)
            )
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.autoresizingMask = [.width, .height]
            hosting.wantsLayer = true
            hosting.isHidden = (section != initialSection)
            addSubview(hosting)
            hosts[section] = hosting
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // Keep every section (including hidden ones) laid out to exact container bounds
        // so switching never triggers a first-frame HSplitView resize or shift.
        for hosting in hosts.values {
            if hosting.frame != bounds {
                hosting.frame = bounds
            }
        }
    }

    func select(_ section: WorkspaceSection) {
        guard section != currentSection else { return }
        let previous = currentSection
        currentSection = section

        guard let nextView = hosts[section] else { return }
        if nextView.frame != bounds && bounds.width > 0 && bounds.height > 0 {
            nextView.frame = bounds
        }
        nextView.layoutSubtreeIfNeeded()

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.12
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(transition, forKey: "longBlogSectionFade")
        }

        hosts[previous]?.isHidden = true
        nextView.isHidden = false
    }

    @ViewBuilder
    private static func makeSectionView(_ sec: WorkspaceSection, app: AppModel) -> some View {
        switch sec {
        case .dashboard: DashboardView(model: app.dashboard)
        case .inbox: InboxWorkspace(model: app.inbox)
        case .posts: PostsWorkspace(model: app.posts)
        case .memos: MemosWorkspace(model: app.memos)
        case .configuration: ConfigurationWorkspace(model: app.configuration)
        }
    }
}
