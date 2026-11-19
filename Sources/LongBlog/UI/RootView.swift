import SwiftUI

struct RootView: View {
    @StateObject private var app = AppModel.shared
    @ObservedObject private var posts = AppModel.shared.posts
    @ObservedObject private var inbox = AppModel.shared.inbox
    @ObservedObject private var memos = AppModel.shared.memos
    @ObservedObject private var configuration = AppModel.shared.configuration
    @ObservedObject private var dashboard = AppModel.shared.dashboard

    @State private var mountedSections: Set<WorkspaceSection> = [.dashboard]
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var searchFocused: Bool

    private var sidebarShouldHide: Bool {
        app.sidebarCollapsed || app.focusMode
    }

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                WorkspaceSidebar(app: app)
                    .navigationSplitViewColumnWidth(min: 214, ideal: 234, max: 268)
            } detail: {
                sectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { AmbientCanvasBackground().ignoresSafeArea() }
                    .navigationTitle(toolbarTitle)
                    .navigationSubtitle(statusSubtitle.text)
                    .toolbar {
                        if !(app.section == .configuration && configuration.baseline.isEmpty && !configuration.isDirty)
                            && !(app.section == .posts && app.focusMode) {
                            #if compiler(>=6.2)
                            if #available(macOS 26.0, *) {
                                ToolbarItem(placement: .principal) {
                                    toolbarCenterControls
                                }
                                .sharedBackgroundVisibility(.hidden)
                            } else {
                                ToolbarItem(placement: .principal) {
                                    toolbarCenterControls
                                }
                            }
                            #else
                            ToolbarItem(placement: .principal) {
                                toolbarCenterControls
                            }
                            #endif
                        }

                        if busy {
                            #if compiler(>=6.2)
                            if #available(macOS 26.0, *) {
                                ToolbarItem(placement: .primaryAction) {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                .sharedBackgroundVisibility(.hidden)
                            } else {
                                ToolbarItem(placement: .primaryAction) {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            #else
                            ToolbarItem(placement: .primaryAction) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            #endif
                        }

                        #if compiler(>=6.2)
                        if #available(macOS 26.0, *) {
                            ToolbarItem(placement: .primaryAction) { toolbarActions }
                                .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: .primaryAction) { toolbarActions }
                        }
                        #else
                        ToolbarItem(placement: .primaryAction) { toolbarActions }
                        #endif
                    }
            }
            .navigationSplitViewStyle(.balanced)

            if app.showingCommandPalette {
                CommandPaletteOverlay(app: app)
            }
        }
        .frame(minWidth: 1020, minHeight: 660)
        .foregroundStyle(Color.blogText)
        .onAppear {
            mountedSections.insert(app.section)
            columnVisibility = sidebarShouldHide ? .detailOnly : .all
        }
        .onChange(of: app.section) { _, next in
            mountedSections.insert(next)
        }
        .onChange(of: sidebarShouldHide) { _, hide in
            let target: NavigationSplitViewVisibility = hide ? .detailOnly : .all
            if columnVisibility != target {
                withAnimation(.easeInOut(duration: 0.25)) {
                    columnVisibility = target
                }
            }
        }
        .onChange(of: columnVisibility) { _, vis in
            // Keep app state synced when the user clicks macOS's native toolbar sidebar button.
            if vis == .all {
                if app.focusMode { app.focusMode = false }
                if app.sidebarCollapsed { app.sidebarCollapsed = false }
            } else if vis == .detailOnly {
                if !app.focusMode && !app.sidebarCollapsed { app.sidebarCollapsed = true }
            }
        }
        .onChange(of: app.searchRequested) {
            if [.inbox, .memos, .configuration].contains(app.section) {
                searchFocused = true
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

    // MARK: - Persistent Section Host (Zero WKWebView Rebuild)

    @ViewBuilder private var sectionContent: some View {
        ZStack {
            ForEach(WorkspaceSection.allCases) { sec in
                if mountedSections.contains(sec) || app.section == sec {
                    sectionView(sec)
                        .opacity(app.section == sec ? 1 : 0)
                        .allowsHitTesting(app.section == sec)
                        .accessibilityHidden(app.section != sec)
                        .zIndex(app.section == sec ? 1 : 0)
                }
            }
        }
        .transaction { $0.animation = nil }
    }

    @ViewBuilder private func sectionView(_ sec: WorkspaceSection) -> some View {
        switch sec {
        case .dashboard: DashboardView(model: app.dashboard)
        case .inbox: InboxWorkspace(model: app.inbox)
        case .posts: PostsWorkspace(model: app.posts)
        case .memos: MemosWorkspace(model: app.memos)
        case .configuration: ConfigurationWorkspace(model: app.configuration)
        }
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
            if app.focusMode && !posts.draft.title.isEmpty {
                let state = posts.draft.published ? "已发布" : "草稿"
                return (posts.isDirty ? .blogPeach : .blogGreen, "\(state)\(posts.isDirty ? " · 未保存" : " · 专注写作中")", .blogMuted)
            }
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
        if app.section == .posts && app.focusMode {
            return "专注写作"
        }
        if app.section == .inbox { return "终端留言" }
        return app.section.rawValue
    }

    @ViewBuilder private var toolbarCenterControls: some View {
        switch app.section {
        case .dashboard:
            Button {
                app.toggleCommandPalette()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.blogMuted)
                    Text("搜索或命令…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.blogMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("⌘K")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.blogMuted.opacity(0.75))
                }
                .padding(.horizontal, 12)
                .frame(width: 224, height: WorkspaceToolbarMetrics.height)
                .blogGlassControl(capsule: true, interactive: true, fallbackFill: .blogField)
            }
            .buttonStyle(.plain)
            .help("打开快速搜索与命令面板  ⌘K / ⌘F")

        case .posts:
            if !app.focusMode {
                BlogSegmentedControl(
                    options: [
                        SegmentedOption(value: "全部", label: "全部", count: posts.loaded ? posts.articles.count : nil),
                        SegmentedOption(value: "草稿", label: "草稿", count: posts.loaded ? posts.draftCount : nil),
                        SegmentedOption(value: "已发布", label: "已发布", count: posts.loaded ? posts.publishedCount : nil)
                    ],
                    selection: $posts.filter,
                    compact: true, toolbarSized: true
                )
            }

        case .inbox:
            SearchField(prompt: "搜索会话或留言", text: search, focused: $searchFocused, toolbarSized: true)
                .frame(width: 224)
                .accessibilityLabel("搜索当前板块")

        case .memos:
            SearchField(prompt: "搜索说说", text: search, focused: $searchFocused, toolbarSized: true) {
                memos.load()
            }
            .frame(width: 224)
            .accessibilityLabel("搜索当前板块")

        case .configuration:
            HStack(spacing: 8) {
                if !configuration.baseline.isEmpty {
                    SearchField(prompt: "筛选配置项", text: search, focused: $searchFocused, toolbarSized: true)
                        .frame(width: 224)
                        .accessibilityLabel("搜索配置项")
                }
                if configuration.isDirty {
                    StatusBadge(text: "已修改 \(configuration.changedKeys.count) 项", color: .blogPeach, pill: true)
                }
            }
        }
    }

    private var toolbarActions: some View {
        HStack(spacing: 10) {
            Button { app.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(ToolbarIconButtonStyle())
                .accessibilityLabel("刷新当前板块")
                .help("刷新当前板块  ⌘R")
                .disabled(busy)
            if app.section == .posts && app.focusMode {
                Button("保存") { posts.save() }
                    .buttonStyle(ToolbarPillButtonStyle(prominent: false, minWidth: 60))
                    .disabled(!posts.isDirty || posts.busy)
                    .help("保存到本地  ⌘S")
            }
            primaryAction
        }
        .fixedSize()
        .padding(.trailing, WorkspaceToolbarMetrics.trailingInset)
    }

    @ViewBuilder private var primaryAction: some View {
        switch app.section {
        case .dashboard:
            Button { app.newArticle() } label: {
                HStack(spacing: 5) {
                    Text("新建文章")
                    ShortcutCap(text: "⌘N", onPrimary: true)
                }
            }
            .buttonStyle(ToolbarPillButtonStyle())
            .disabled(posts.busy)
            .help("新建文章  ⌘N")

        case .posts:
            if app.focusMode {
                if !posts.staged.isEmpty {
                    Button { posts.review() } label: {
                        HStack(spacing: 4) {
                            Text("提交发布（\(posts.staged.count)）")
                            ShortcutCap(text: "⌘⇧P", onPrimary: true)
                        }
                    }
                    .buttonStyle(ToolbarPillButtonStyle())
                    .disabled(posts.busy)
                } else {
                    Button("暂存发布") { posts.stage(true) }
                        .buttonStyle(ToolbarPillButtonStyle())
                        .disabled(posts.busy || posts.draft.id.isEmpty)
                }
            } else {
                Button { app.newArticle() } label: {
                    HStack(spacing: 5) {
                        Text("新建文章")
                        ShortcutCap(text: "⌘N", onPrimary: true)
                    }
                }
                .buttonStyle(ToolbarPillButtonStyle())
                .disabled(posts.busy)
                .help("新建文章  ⌘N")
            }

        case .memos:
            Button { app.newMemo() } label: {
                HStack(spacing: 5) {
                    Text("写说说")
                    ShortcutCap(text: "⌘⇧N", onPrimary: true)
                }
            }
            .buttonStyle(ToolbarPillButtonStyle())
            .disabled(memos.busy)
            .help("写说说  ⌘⇧N")

        case .configuration:
            Button { configuration.review() } label: {
                HStack(spacing: 5) {
                    Text("提交到 main")
                    ShortcutCap(text: "⌘S", onPrimary: true)
                }
            }
            .buttonStyle(ToolbarPillButtonStyle())
            .disabled(!configuration.isDirty || configuration.busy)
            .help("审阅并提交配置变更  ⌘S")

        case .inbox:
            Button { inbox.setArchived(!inbox.archived) } label: {
                Label(inbox.archived ? "返回进行中" : "归档记录", systemImage: inbox.archived ? "tray" : "archivebox")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(ToolbarPillButtonStyle(prominent: false))
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
    @State private var cmdHover = false
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
            VStack(alignment: .leading, spacing: 10) {
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
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.blogMuted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 2)

                Button {
                    app.toggleCommandPalette()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.blogMuted)
                        Text("快速跳转与命令…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.blogMuted)
                            .lineLimit(1)
                        Spacer()
                        Text("⌘K")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.blogMuted.opacity(0.85))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.blogSlot, in: Capsule())
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6.5)
                    .blogGlassControl(
                        capsule: true,
                        interactive: true,
                        fallbackFill: cmdHover ? .blogSurfaceHover : .blogField,
                        fallbackStroke: .blogStroke
                    )
                }
                .buttonStyle(.plain)
                .onHover { cmdHover = $0 }
                .help("打开命令面板  ⌘K / ⌘P")
            }
            .padding(.top, 2)
            .padding(.bottom, 6)
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
            VStack(spacing: 8) {
                HairlineDivider()
                HStack(alignment: .center, spacing: 6) {
                    Button {
                        app.showingSettings = true
                    } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repoLine)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.blogSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.9)
                                Text(branchLine)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Color.blogMuted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 2)
                            Image(systemName: "gearshape")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.blogMuted)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(settingsHover ? Color.blogSurfaceHover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { settingsHover = $0 }
                    .help("服务与连接设置  ⌘,")
                    .accessibilityLabel("连接设置")

                    Button {
                        let next: AppAppearance = AppAppearance.current == .dark ? .light : .dark
                        appearance = next.rawValue
                        AppAppearance.apply(next)
                    } label: {
                        Image(systemName: AppAppearance(rawValue: appearance)?.symbol ?? "moon.stars.fill")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                    .help("切换深浅色模式")
                    .accessibilityLabel("切换深浅色模式")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
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
    @State private var hovering = false

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
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(section.rawValue)  \(shortcut)")
        .accessibilityLabel(section.rawValue)
    }
}
