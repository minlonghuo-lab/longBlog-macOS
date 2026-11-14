import SwiftUI
import Combine

struct RootView: View {
    @StateObject private var app = AppModel.shared
    private let commandNames = ["newArticle", "newMemo", "save", "review", "refresh", "search", "editArticle"]
    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(app: app).frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                WorkspaceToolbar(app: app)
                Divider()
                sectionContent
            }
        }
        .frame(minWidth: 1050, minHeight: 700)
        .background(Color.blogBackground.opacity(0.94)).background(.ultraThinMaterial)
        .foregroundStyle(Color.blogText).tint(.blogPeach).preferredColorScheme(.dark)
        .background(WindowCloseGuard().frame(width: 0, height: 0))
        .onAppear { app.refreshIfNeeded() }
        .onReceive(Publishers.MergeMany(commandNames.map { NotificationCenter.default.publisher(for: Notification.Name("longBlog.\($0)")) })) { notification in
            app.route(notification.name.rawValue.replacingOccurrences(of: "longBlog.", with: ""))
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill").font(.title2).foregroundStyle(Color.blogPeach)
                VStack(alignment: .leading, spacing: 3) { Text("longBlog").font(.title3.weight(.semibold)); Text("你的博客工作台").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 12).padding(.top, 22).padding(.bottom, 24)
            ForEach(WorkspaceSection.allCases) { section in
                Button { app.navigate(section) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.symbol).frame(width: 20)
                        Text(section.rawValue)
                        Spacer()
                        if let value = badge(section) { Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 13).padding(.vertical, 12).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .foregroundStyle(app.section == section ? Color.blogPeach : Color.blogText)
                    .background(app.section == section ? Color.blogPeach.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(section.rawValue).accessibilityAddTraits(app.section == section ? .isSelected : [])
            }
            Spacer()
            Text("~/longBlog $ workspace").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).padding(.horizontal, 12)
            Divider().padding(.vertical, 8)
            Button { app.showingSettings = true } label: { Label("连接设置…", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading).padding(12) }.buttonStyle(.plain).accessibilityLabel("连接设置")
        }.padding(12).background(.white.opacity(0.025))
    }
    private func badge(_ section: WorkspaceSection) -> String? {
        switch section { case .posts: return posts.loaded ? "\(posts.articles.count)" : nil; case .inbox: return inbox.loaded ? "\(inbox.unread)" : nil; case .memos: return memos.loaded ? "\(memos.items.count)\(memos.more ? "+" : "")" : nil; default: return nil }
    }
}
private struct WorkspaceToolbar: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var posts = AppModel.shared.posts
    @ObservedObject private var inbox = AppModel.shared.inbox
    @ObservedObject private var memos = AppModel.shared.memos
    @ObservedObject private var configuration = AppModel.shared.configuration
    @FocusState private var searchFocused: Bool
    private var search: Binding<String> {
        Binding(get: { switch app.section { case .posts: return posts.search; case .inbox: return inbox.search; case .memos: return memos.search; default: return "" } }, set: { value in switch app.section { case .posts: posts.search = value; case .inbox: inbox.search = value; case .memos: memos.search = value; default: break } })
    }
    var body: some View {
        HStack(spacing: 14) {
            Text(app.section.rawValue).font(.title3.weight(.semibold))
            if app.section == .configuration && configuration.isDirty { StatusBadge(text: "已修改 \(configuration.changedKeys.count) 项") }
            Spacer(minLength: 8)
            if [.posts, .inbox, .memos].contains(app.section) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索…", text: search).textFieldStyle(.plain).focused($searchFocused).onSubmit { if app.section == .memos { memos.load() } } }
                    .padding(8).frame(width: 190).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("搜索当前板块")
            }
            Button { app.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新当前板块").accessibilityLabel("刷新当前板块")
            primaryAction
        }.padding(.horizontal, 22).frame(height: 64)
            .onChange(of: app.searchRequested) { _ in searchFocused = true }
    }
    @ViewBuilder private var primaryAction: some View {
        switch app.section {
        case .dashboard, .posts: Button("新建文章", systemImage: "plus") { app.newArticle() }.buttonStyle(.borderedProminent).disabled(posts.busy)
        case .memos: Button("写说说", systemImage: "square.and.pencil") { app.newMemo() }.buttonStyle(.borderedProminent).disabled(memos.busy)
        case .configuration: Button("审阅并提交", systemImage: "checkmark") { configuration.review() }.buttonStyle(.borderedProminent).disabled(!configuration.isDirty || configuration.busy)
        case .inbox: Button(inbox.archived ? "进行中" : "归档", systemImage: "archivebox") { inbox.setArchived(!inbox.archived) }.disabled(inbox.busy)
        }
    }
}
