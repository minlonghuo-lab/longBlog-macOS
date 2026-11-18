import SwiftUI

struct RootView: View {
    @StateObject private var app = AppModel.shared
    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(app: app).frame(width: 220)
            Divider().ignoresSafeArea()
            VStack(spacing: 0) {
                WorkspaceToolbar(app: app)
                Divider()
                sectionContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.blogBackground)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1000, minHeight: 640)
        .foregroundStyle(Color.blogText).tint(.blogPeach)
        .background(WindowCloseGuard().frame(width: 0, height: 0))
        .onAppear { app.refreshIfNeeded() }
        .sheet(isPresented: $app.showingSettings) { ConnectionSettingsView() }
        .sheet(isPresented: $app.showingReview) { StagingReviewView(model: app.posts) }
    }
    @ViewBuilder private var sectionContent: some View {
        switch app.section {
        case .dashboard: DashboardView(model: app.dashboard)
        case .inbox: InboxWorkspace(model: app.inbox)
        case .posts: PostsWorkspace(model: app.posts)
        case .memos: MemosWorkspace(model: app.memos)
        case .configuration: ConfigurationWorkspace(model: app.configuration)
        }
    }
}

private struct WorkspaceSidebar: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var posts = AppModel.shared.posts
    @ObservedObject private var inbox = AppModel.shared.inbox
    @ObservedObject private var memos = AppModel.shared.memos
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the traffic lights; the strip also drags the window.
            WindowDragArea().frame(height: 40)
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.blogBackground)
                    .frame(width: 30, height: 30).background(Color.blogPeach.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("longBlog").font(.system(size: 15, weight: .semibold))
                    Text("你的博客工作台").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 10).padding(.bottom, 18)
            Text("工作区").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.bottom, 4)
            ForEach(Array(WorkspaceSection.allCases.enumerated()), id: \.element) { index, section in
                SidebarRow(section: section, selected: app.section == section, badge: badge(section), highlight: section == .inbox && inbox.unread > 0, shortcut: "⌘\(index + 1)") {
                    app.navigate(section)
                }
            }
            Spacer()
            Divider().padding(.vertical, 6)
            Button { app.showingSettings = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape").frame(width: 18)
                    Text("连接设置")
                    Spacer()
                    Text("⌘,").font(.caption).foregroundStyle(.tertiary)
                }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("连接设置")
        }
        .padding(.horizontal, 10).padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { ZStack { VisualEffectBackground(material: .sidebar); Color.blogSidebar }.ignoresSafeArea() }
    }
    private func badge(_ section: WorkspaceSection) -> String? {
        switch section {
        case .posts: return posts.loaded ? "\(posts.articles.count)" : nil
        case .inbox: return inbox.loaded && inbox.unread > 0 ? "\(inbox.unread)" : nil
        case .memos: return memos.loaded ? "\(memos.items.count)\(memos.more ? "+" : "")" : nil
        default: return nil
        }
    }
}

private struct SidebarRow: View {
    let section: WorkspaceSection, selected: Bool, badge: String?, highlight: Bool, shortcut: String, action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol).font(.system(size: 14)).frame(width: 18)
                Text(section.rawValue).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if let badge = badge {
                    Text(badge).font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(highlight ? Color.blogBackground : Color.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(highlight ? Color.blogPeach : Color.blogStroke, in: Capsule())
                } else if hovering {
                    Text(shortcut).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
            .background(selected ? Color.blogPeach.opacity(0.18) : (hovering ? Color.blogSurfaceHover : .clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.blogPeach : Color.blogText)
        .onHover { hovering = $0 }
        .help("\(section.rawValue)  \(shortcut)")
        .accessibilityLabel(section.rawValue).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct WorkspaceToolbar: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var posts = AppModel.shared.posts
    @ObservedObject private var inbox = AppModel.shared.inbox
    @ObservedObject private var memos = AppModel.shared.memos
    @ObservedObject private var configuration = AppModel.shared.configuration
    @ObservedObject private var dashboard = AppModel.shared.dashboard
    @FocusState private var searchFocused: Bool
    private var search: Binding<String> {
        Binding(get: { switch app.section { case .posts: return posts.search; case .inbox: return inbox.search; case .memos: return memos.search; default: return "" } }, set: { value in switch app.section { case .posts: posts.search = value; case .inbox: inbox.search = value; case .memos: memos.search = value; default: break } })
    }
    private var subtitle: String {
        switch app.section {
        case .dashboard: return dashboard.refreshed.map { "上次读取 \($0.formatted(date: .omitted, time: .shortened))" } ?? "站点、仓库与工作区状态"
        case .posts: return posts.loaded ? "共 \(posts.articles.count) 篇 · \(posts.folder)" : "本地 Markdown 工作区"
        case .inbox: return inbox.loaded ? "\(inbox.sessions.count) 个会话 · \(inbox.unread) 个未读" : "终端留言"
        case .memos: return memos.username.isEmpty ? "legacy Memos" : "@\(memos.username) · \(memos.archived ? "归档" : "时间线")"
        case .configuration: return configuration.repository.isEmpty ? "GitHub · main · .env" : "\(configuration.repository) · main · .env"
        }
    }
    private var busy: Bool {
        switch app.section { case .dashboard: return dashboard.busy; case .posts: return posts.busy; case .inbox: return inbox.busy; case .memos: return memos.busy; case .configuration: return configuration.busy }
    }
    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(app.section.rawValue).font(.system(size: 17, weight: .semibold))
                        if app.section == .configuration && configuration.isDirty { StatusBadge(text: "已修改 \(configuration.changedKeys.count) 项") }
                        if busy { ProgressView().controlSize(.mini) }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if [.posts, .inbox, .memos].contains(app.section) {
                    SearchField(prompt: app.section == .posts ? "搜索标题或摘要  ⌘F" : "搜索…  ⌘F", text: search, focused: $searchFocused) {
                        if app.section == .memos { memos.load() }
                    }.frame(width: 220).accessibilityLabel("搜索当前板块")
                }
                Button { app.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新当前板块 ⌘R").accessibilityLabel("刷新当前板块").disabled(busy)
                primaryAction
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 56)
        .onChange(of: app.searchRequested) { searchFocused = true }
    }
    @ViewBuilder private var primaryAction: some View {
        switch app.section {
        case .dashboard, .posts: Button { app.newArticle() } label: { Label("新建文章", systemImage: "plus") }.buttonStyle(.borderedProminent).disabled(posts.busy).help("⌘N")
        case .memos: Button { app.newMemo() } label: { Label("写说说", systemImage: "square.and.pencil") }.buttonStyle(.borderedProminent).disabled(memos.busy).help("⌘⇧N")
        case .configuration: Button { configuration.review() } label: { Label("审阅并提交", systemImage: "checkmark") }.buttonStyle(.borderedProminent).disabled(!configuration.isDirty || configuration.busy).help("⌘S")
        case .inbox: Button { inbox.setArchived(!inbox.archived) } label: { Label(inbox.archived ? "进行中" : "归档", systemImage: inbox.archived ? "tray" : "archivebox") }.disabled(inbox.busy)
        }
    }
}
