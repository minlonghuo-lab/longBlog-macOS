import SwiftUI
import AppKit
import Combine

struct DataRow: Identifiable {
    let data: [String: Any]
    var id: String {
        if let id = data["id"] as? String { return id }
        return (data["id"] as? NSNumber)?.stringValue ?? UUID().uuidString
    }
    func text(_ key: String) -> String { data[key] as? String ?? "" }
    func flag(_ key: String) -> Bool { (data[key] as? NSNumber)?.boolValue ?? false }
    func number(_ key: String) -> Double { (data[key] as? NSNumber)?.doubleValue ?? 0 }
}

func rows(_ value: Any?) -> [DataRow] { (value as? [[String: Any]] ?? []).map { DataRow(data: $0) } }

func dateLabel(_ value: Double, milliseconds: Bool = true) -> String {
    guard value > 0 else { return "—" }
    return Date(timeIntervalSince1970: value / (milliseconds ? 1000 : 1)).formatted(date: .abbreviated, time: .shortened)
}

func shortDateTimeLabel(_ value: Double, milliseconds: Bool = true) -> String {
    guard value > 0 else { return "—" }
    let date = Date(timeIntervalSince1970: value / (milliseconds ? 1000 : 1))
    let cal = Calendar.current
    if cal.isDateInToday(date) {
        return "今天 " + date.formatted(date: .omitted, time: .shortened)
    } else if cal.isDateInYesterday(date) {
        return "昨天 " + date.formatted(date: .omitted, time: .shortened)
    }
    let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
    if sameYear {
        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
    return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
}

func relativeTimeLabel(_ value: Double, milliseconds: Bool = true) -> String {
    guard value > 0 else { return "—" }
    let seconds = value / (milliseconds ? 1000 : 1)
    let delta = Date().timeIntervalSince1970 - seconds
    if delta < 45 { return "刚刚" }
    if delta < 3600 { return "\(max(1, Int(delta / 60))) 分钟前" }
    if delta < 86400, Calendar.current.isDateInToday(Date(timeIntervalSince1970: seconds)) {
        return "\(max(1, Int(delta / 3600))) 小时前"
    }
    if Calendar.current.isDateInYesterday(Date(timeIntervalSince1970: seconds)) { return "昨天" }
    return shortDateTimeLabel(value, milliseconds: milliseconds)
}

func formattedISOBuildTime(_ raw: String?) -> String {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "—" }
    let isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoPlain = ISO8601DateFormatter()
    if let date = isoFrac.date(from: raw) ?? isoPlain.date(from: raw) {
        return shortDateTimeLabel(date.timeIntervalSince1970, milliseconds: false)
    }
    return raw
}

@MainActor class ServiceModel: ObservableObject {
    @Published var running = Set<String>()
    @Published var errors: [String: String] = [:]
    @Published var successes: [String: String] = [:]
    var busy: Bool { !running.isEmpty }
    func run(_ key: String, _ operation: String, _ arguments: [String: Any] = [:], success: String? = nil, done: @escaping ([String: Any]) -> Void = { _ in }) {
        guard !running.contains(key) else { return }
        running.insert(key); errors[key] = nil; successes[key] = nil
        LBUIRequest(operation, arguments) { [weak self] result, error in
            // Core and bridge both guarantee main-queue completions.
            guard let self = self else { return }
            self.running.remove(key)
            defer { self.drainIdleActions() }
            if let error = error { self.errors[key] = error.localizedDescription; return }
            if let success = success { self.flash(key, success) }
            done(result ?? [:])
        }
    }
    func clearMessages() { errors = [:]; successes = [:] }
    private var idleActions: [() -> Void] = []
    /// Runs now, or right after the current requests finish (e.g. ⌘N while the list loads)
    /// instead of silently ignoring the command.
    func whenIdle(_ action: @escaping () -> Void) {
        if busy { idleActions.append(action) } else { action() }
    }
    private func drainIdleActions() {
        guard !busy, !idleActions.isEmpty else { return }
        let actions = idleActions; idleActions = []
        actions.forEach { $0() }
    }
    /// Success notes are transient toasts; errors stay until dismissed.
    func flash(_ key: String, _ text: String) {
        successes[key] = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.successes[key] == text { self?.successes[key] = nil }
        }
    }
    static func label(_ key: String) -> String {
        ["list": "读取列表", "load": "读取", "save": "保存", "new": "新建", "stage": "暂存", "sync": "同步", "commit": "提交",
         "revert": "撤销", "delete": "删除", "deleteArchive": "删除归档", "attachment": "导入附件", "dashboard": "读取状态", "sessions": "读取会话", "messages": "读取消息",
         "read": "标记已读", "contact": "联系信息", "reply": "发送回复", "identity": "验证账户", "update": "更新",
         "upload": "上传附件", "download": "下载附件", "preview": "生成预览", "folder": "绑定目录",
         "settings": "读取连接"][key] ?? key
    }
}

struct PendingConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let button: String
    let destructive: Bool
    let action: () -> Void
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case dashboard = "仪表盘", inbox = "留言", posts = "文章", memos = "说说", configuration = "站点配置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .inbox: return "bubble.left"
        case .posts: return "doc.text"
        case .memos: return "text.bubble"
        case .configuration: return "slider.horizontal.3"
        }
    }
    var commandAlias: String {
        switch self {
        case .dashboard: return "dashboard"
        case .inbox: return "inbox"
        case .posts: return "posts"
        case .memos: return "memos"
        case .configuration: return "config"
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var section: WorkspaceSection = .dashboard
    @Published var confirmation: PendingConfirmation?
    @Published var showingSettings = false
    @Published var showingReview = false
    @Published var showingCommandPalette = false
    @Published var showingShortcutsHelp = false
    @Published var isWindowZoomed = false
    @Published var focusMode = false
    @Published var sidebarCollapsed = false
    @Published var searchRequested = UUID()
    @Published var aiRequested = UUID()
    let dashboard = DashboardModel()
    let posts = PostsModel()
    let inbox = InboxModel()
    let memos = MemosModel()
    let configuration = ConfigurationModel()
    private var commandObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private weak var paletteSavedWindow: NSWindow?
    private weak var paletteSavedResponder: NSResponder?
    private var paletteSavedFieldSelection: NSRange?
    static let commandNames = ["newArticle", "newMemo", "save", "review", "syncArticles", "refresh", "search", "editArticle", "aiAssistant",
                               "nav.dashboard", "nav.inbox", "nav.posts", "nav.memos", "nav.configuration", "nav.prev", "nav.next", "settings",
                               "layout.read", "layout.edit", "layout.split", "editor.zoomIn", "editor.zoomOut", "editor.zoomReset",
                               "commandPalette", "shortcutsHelp", "toggleWindowZoom", "toggleFocus", "toggleSidebar", "openSite"]

    /// Menu commands are routed ONCE here (not per view), so a second window or a
    /// re-created RootView can never execute ⌘N / ⌘S twice.
    private init() {
        commandObservers = Self.commandNames.map { name in
            NotificationCenter.default.addObserver(forName: Notification.Name("longBlog." + name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.route(name) }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let keyCode = event.keyCode
            guard flags.isEmpty, (keyCode == 125 || keyCode == 126) else { return event }
            let consumed = MainActor.assumeIsolated {
                let app = AppModel.shared
                guard !Self.activeTextInputHasMarkedText,
                      app.confirmation == nil, !app.showingSettings, !app.showingReview, !app.showingShortcutsHelp,
                      app.memos.previewAttachment == nil, !app.configuration.showingPreview,
                      NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return false }
                if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                    return false
                }
                guard app.canStepSelection else { return false }
                app.stepSelection(keyCode == 125 ? 1 : -1)
                return true
            }
            return consumed ? nil : event
        }
        commandObservers.append(
            NotificationCenter.default.addObserver(forName: Notification.Name("LBSyncDidChange"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.inbox.syncFromCore() }
            }
        )
        commandObservers.append(NotificationCenter.default.addObserver(forName: Notification.Name("LBWorkspaceFilesDidChange"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.posts.workspaceChanged() }
        })
        commandObservers.append(NotificationCenter.default.addObserver(forName: Notification.Name("LBSiteDataDidChange"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.dashboard.receiveProgress() }
        })
        commandObservers.append(
            NotificationCenter.default.addObserver(forName: Notification.Name("LBMemosDidChange"), object: nil, queue: .main) { note in
                guard note.userInfo?["reset"] as? Bool == true else { return }
                MainActor.assumeIsolated { AppModel.shared.memos.clearAccount() }
            }
        )
        commandObservers.append(
            NotificationCenter.default.addObserver(forName: Notification.Name("LBMemosCacheDidChange"), object: nil, queue: .main) { note in
                let info = note.userInfo as? [String: Any] ?? [:]
                MainActor.assumeIsolated { AppModel.shared.memos.receiveCacheProgress(info) }
            }
        )
        commandObservers.append(
            NotificationCenter.default.addObserver(forName: Notification.Name("LBOpenSessionRequest"), object: nil, queue: .main) { note in
                let sid = note.userInfo?["sessionId"] as? String
                MainActor.assumeIsolated {
                    (NSApp.delegate as? LongBlogAppDelegate)?.showWorkspace(reloadInboxOnFocus: false)
                    AppModel.shared.openInboxSession(sid)
                }
            }
        )
    }

    var connectionLocked: Bool {
        posts.busy || inbox.busy || memos.busy || configuration.busy || dashboard.busy || showingReview || confirmation != nil
    }

    var canSaveCurrentSection: Bool {
        switch section {
        case .posts: return !posts.draft.id.isEmpty && posts.isDirty && !posts.busy
        case .memos: return memos.editing && (memos.isDirty || memos.original == nil) && !memos.busy && (memos.original?["rowStatus"] as? String != "ARCHIVED")
        case .configuration: return configuration.isDirty && !configuration.busy
        default: return false
        }
    }

    var isMarkdownEditingAvailable: Bool {
        switch section {
        case .posts: return posts.editing && !posts.draft.id.isEmpty && !posts.busy
        case .memos: return memos.editing && !memos.busy && (memos.original?["rowStatus"] as? String != "ARCHIVED")
        default: return false
        }
    }

    var canStepSelection: Bool {
        switch section {
        case .posts: return posts.filtered.count > 1 && !posts.busy
        case .inbox: return inbox.filtered.count > 1 && !inbox.busy
        case .memos: return memos.filtered.count > 1 && !memos.busy
        case .configuration: return configuration.sections.count > 1 && configuration.search.isEmpty && !configuration.busy
        case .dashboard: return false
        }
    }

    func stepSelection(_ delta: Int) {
        switch section {
        case .posts:
            let list = posts.filtered
            guard !list.isEmpty else { return }
            let cur = list.firstIndex(where: { $0.id == posts.draft.id }) ?? (delta > 0 ? -1 : 0)
            let next = min(max(0, cur + delta), list.count - 1)
            if list.indices.contains(next) { posts.select(list[next]) }
        case .inbox:
            let list = inbox.filtered
            guard !list.isEmpty else { return }
            let cur = list.firstIndex(where: { $0.id == inbox.selected?.id }) ?? (delta > 0 ? -1 : 0)
            let next = min(max(0, cur + delta), list.count - 1)
            if list.indices.contains(next) { inbox.select(list[next]) }
        case .memos:
            let list = memos.filtered
            guard !list.isEmpty else { return }
            let cur = list.firstIndex(where: { $0.id == memos.selectedID }) ?? (delta > 0 ? -1 : 0)
            let next = min(max(0, cur + delta), list.count - 1)
            if list.indices.contains(next) { memos.select(list[next]) }
        case .configuration:
            guard !configuration.sections.isEmpty else { return }
            configuration.search = ""
            configuration.selectedSection = min(max(0, configuration.selectedSection + delta), configuration.sections.count - 1)
        case .dashboard:
            break
        }
    }

    func resetConnectionViews() {
        posts.checkID = UUID(); posts.nextCheck = .distantPast
        configuration.checkID = UUID(); configuration.nextCheck = .distantPast
        memos.checkID = UUID(); memos.nextCheck = .distantPast; memos.more = false
        posts.resetBuffer(); posts.articles = []; posts.staged = []; posts.loaded = false; posts.clearMessages()
        inbox.setActiveSession(nil)
        inbox.pendingSelectID = nil
        inbox.sessions = []; inbox.messages = []; inbox.selected = nil; inbox.contact = nil; inbox.reply = ""; inbox.failedReply = nil; inbox.loaded = false; inbox.unread = 0; inbox.lastSync = nil; inbox.clearMessages()
        memos.assign(nil); memos.items = []; memos.editing = false; memos.loaded = false; memos.username = ""; memos.clearMessages()
        configuration.baseline = ""; configuration.sha = ""; configuration.values = [:]; configuration.baselineValues = [:]; configuration.sections = []; configuration.search = ""; configuration.clearMessages()
        dashboard.invalidate(); dashboard.clearMessages()
    }

    /// Parent AppDelegate may use this for applicationShouldTerminate(.terminateLater).
    func confirmDiscardBeforeClose(_ completion: @escaping (Bool) -> Void) {
        if connectionLocked {
            let alert = NSAlert(); alert.messageText = "操作尚未完成"; alert.informativeText = "请等待当前操作结束后再退出。"; alert.runModal(); completion(false); return
        }
        guard !dirtyNames.isEmpty else { completion(true); return }
        let alert = NSAlert(); alert.messageText = "仍有未保存的修改"; alert.informativeText = dirtyNames.joined(separator: "、") + "尚未保存。退出将丢失编辑缓冲区。"
        alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃并退出")
        AlertHost.present(alert) { completion($0 == .alertSecondButtonReturn) }
    }

    var dirtyNames: [String] {
        var result: [String] = []
        if posts.isDirty { result.append("文章") }
        if memos.isDirty { result.append("说说") }
        if configuration.isDirty { result.append("站点配置") }
        if !inbox.reply.isEmpty { result.append("回复") }
        return result
    }

    func confirm(_ title: String, _ detail: String, button: String = "确认", destructive: Bool = false, action: @escaping () -> Void) {
        guard confirmation == nil else { return }
        confirmation = PendingConfirmation(title: title, detail: detail, button: button, destructive: destructive, action: action)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.alertStyle = destructive ? .warning : .informational
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: button)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            self.confirmation = nil
            if response == .alertSecondButtonReturn { action() }
        }
        AlertHost.present(alert, completion: finish)
    }

    func navigate(_ target: WorkspaceSection, reloadingSelectedInbox: Bool = true) {
        if section != target {
            if section == .inbox { inbox.setActiveSession(nil) }
            section = target
            if target != .posts && focusMode { focusMode = false }
            if target == .inbox, reloadingSelectedInbox, let selected = inbox.selected, !inbox.archived {
                inbox.setActiveSession(selected.id)
                inbox.loadMessages()
            }
            (NSApp.delegate as? LongBlogAppDelegate)?.suppressTitlebarHoverHighlight()
        }
        refreshIfNeeded()
    }

    func openInboxSession(_ sessionID: String?) {
        if showingCommandPalette { showingCommandPalette = false }
        guard let sessionID = sessionID, !sessionID.isEmpty else {
            navigate(.inbox)
            return
        }
        if !inbox.loaded {
            inbox.pendingSelectID = sessionID
            navigate(.inbox, reloadingSelectedInbox: false)
            return
        }
        if !inbox.archived, inbox.selected?.id == sessionID {
            navigate(.inbox, reloadingSelectedInbox: true)
            inbox.whenIdle {
                guard self.section == .inbox, !self.inbox.archived, self.inbox.selected?.id == sessionID else { return }
                self.inbox.setActiveSession(sessionID)
                self.inbox.loadMessages()
            }
            return
        }
        navigate(.inbox, reloadingSelectedInbox: false)
        inbox.whenIdle {
            guard self.section == .inbox else { return }
            if self.inbox.archived {
                self.inbox.setArchived(false, selecting: sessionID)
            } else if let hit = self.inbox.sessions.first(where: { $0.id == sessionID }) {
                self.inbox.select(hit)
            } else {
                self.inbox.pendingSelectID = sessionID
                self.inbox.refresh()
            }
        }
    }

    // Editors are retained across section switches. Selection changes are separately confirmed.
    func refreshIfNeeded() {
        // Also pre-load local posts count silently once so sidebar badge & ⌘K search work immediately.
        if !posts.loaded && !posts.busy { posts.openLocal() }
        switch section {
        case .dashboard: dashboard.openLocal()
        case .posts:
            if posts.loaded, posts.draft.id.isEmpty, !posts.editing, let first = posts.filtered.first {
                posts.select(first)
            }
        case .inbox: if !inbox.loaded { inbox.refresh() }
        case .memos: memos.openLocal()
        case .configuration: configuration.openLocal()
        }
    }

    func checkVisibleSection() {
        guard NSApp.isActive, !showingSettings, !showingReview, confirmation == nil,
              !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        switch section {
        case .dashboard: if !dashboard.data.isEmpty { dashboard.verifyIfNeeded() }
        case .posts: posts.checkForChanges()
        case .configuration: configuration.openLocal()
        case .memos: memos.openLocal()
        default: break
        }
    }
    func newArticle() { navigate(.posts); posts.newArticle() }
    func newMemo() { navigate(.memos); memos.newMemo() }
    func save() {
        switch section { case .posts: posts.save(); case .memos: memos.save(); case .configuration: configuration.review(); default: break }
    }
    func review() { navigate(.posts); posts.review() }
    func refresh() {
        switch section {
        case .dashboard: dashboard.refresh()
        case .posts: posts.refresh(autoSelectFirst: posts.draft.id.isEmpty)
        case .inbox: inbox.refresh()
        case .memos: memos.refresh()
        case .configuration: configuration.refresh()
        }
    }
    func editArticle() {
        navigate(.posts)
        guard !posts.draft.id.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            posts.editing.toggle()
            if !posts.editing && focusMode { focusMode = false }
        }
    }
    func toggleFocusMode() {
        if section != .posts { navigate(.posts) }
        guard !posts.draft.id.isEmpty else { return }
        if !focusMode {
            if !posts.editing {
                // Mount editor first so native NavigationSplitView sidebar glide starts with zero frame drop.
                posts.editing = true
                DispatchQueue.main.async {
                    self.focusMode = true
                }
            } else {
                focusMode = true
            }
        } else {
            focusMode = false
        }
    }
    func openCommandPalette() {
        guard !showingCommandPalette, !Self.activeTextInputHasMarkedText else { return }
        var win = NSApp.keyWindow ?? NSApp.mainWindow ?? (NSApp.delegate as? LongBlogAppDelegate)?.workspaceWindow
        while let sheet = win?.attachedSheet { win = sheet }
        paletteSavedWindow = win
        if let tv = win?.firstResponder as? NSTextView, tv.isFieldEditor {
            paletteSavedResponder = tv.delegate as? NSResponder
            paletteSavedFieldSelection = tv.selectedRange()
        } else {
            paletteSavedResponder = win?.firstResponder
            paletteSavedFieldSelection = nil
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            showingCommandPalette = true
        }
    }

    func closeCommandPalette(restoreFocus: Bool) {
        guard showingCommandPalette else { return }
        let win = paletteSavedWindow
        let responder = paletteSavedResponder
        let savedRange = paletteSavedFieldSelection
        paletteSavedWindow = nil
        paletteSavedResponder = nil
        paletteSavedFieldSelection = nil
        withAnimation(.easeOut(duration: 0.14)) {
            showingCommandPalette = false
        }
        guard restoreFocus, let win = win, let responder = responder, responder !== win else { return }
        @MainActor func applyRestore() {
            guard win.attachedSheet == nil, self.confirmation == nil, !self.showingCommandPalette else { return }
            _ = win.makeFirstResponder(responder)
            if let range = savedRange, let tv = win.firstResponder as? NSTextView, tv.isFieldEditor {
                let len = (tv.string as NSString).length
                let loc = min(range.location, len)
                tv.setSelectedRange(NSRange(location: loc, length: min(range.length, len - loc)))
            }
        }
        applyRestore()
        DispatchQueue.main.async { applyRestore() }
    }

    func toggleCommandPalette() {
        showingShortcutsHelp.toggle()
    }
    func toggleShortcutsHelp() {
        showingShortcutsHelp.toggle()
    }
    func toggleWindowZoom() {
        (NSApp.delegate as? LongBlogAppDelegate)?.toggleWindowZoom()
    }
    func search() {
        // Inside the Markdown editor ⌘F opens the in-document find bar instead.
        if let editor = MarkdownEditorController.focused {
            let item = NSMenuItem(); item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
            editor.performTextFinderAction(item); return
        }
        if section == .dashboard {
            navigate(.posts)
        }
        searchRequested = UUID()
    }
    static var activeTextInputHasMarkedText: Bool {
        var window = NSApp.keyWindow ?? NSApp.mainWindow ?? (NSApp.delegate as? LongBlogAppDelegate)?.workspaceWindow
        while let sheet = window?.attachedSheet { window = sheet }
        return (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    func route(_ name: String) {
        guard !Self.activeTextInputHasMarkedText,
              confirmation == nil, NSApp.modalWindow == nil, NSApp.keyWindow?.sheetParent == nil,
              NSApp.mainWindow?.attachedSheet == nil else { return }
        switch name {
        case "newArticle": newArticle()
        case "newMemo": newMemo()
        case "save": save()
        case "review": review()
        case "syncArticles": navigate(.posts); posts.sync()
        case "refresh": refresh()
        case "search": search()
        case "editArticle": editArticle()
        case "aiAssistant":
            navigate(.posts)
            if !posts.draft.id.isEmpty, posts.draft.bodyFormat != "html", !posts.busy {
                aiRequested = UUID()
            }
        case "settings": showingSettings = true
        case "commandPalette", "shortcutsHelp": toggleShortcutsHelp()
        case "toggleWindowZoom": toggleWindowZoom()
        case "toggleFocus": toggleFocusMode()
        case "toggleSidebar": sidebarCollapsed.toggle()
        case "nav.dashboard": navigate(.dashboard)
        case "nav.inbox": navigate(.inbox)
        case "nav.posts": navigate(.posts)
        case "nav.memos": navigate(.memos)
        case "nav.configuration": navigate(.configuration)
        case "nav.prev": stepSelection(-1)
        case "nav.next": stepSelection(1)
        case "layout.read": if section == .posts, !posts.draft.id.isEmpty { posts.editing = false; focusMode = false }
        case "layout.edit": if section == .posts, !posts.draft.id.isEmpty { posts.editing = true; posts.splitPreview = false }
        case "layout.split": if section == .posts, !posts.draft.id.isEmpty { posts.editing = true; posts.splitPreview = true }
        case "editor.zoomIn":
            let current = UserDefaults.standard.object(forKey: "lb.editor.fontSize") as? Double ?? 15.0
            UserDefaults.standard.set(min(24.0, current + 1.0), forKey: "lb.editor.fontSize")
        case "editor.zoomOut":
            let current = UserDefaults.standard.object(forKey: "lb.editor.fontSize") as? Double ?? 15.0
            UserDefaults.standard.set(max(12.0, current - 1.0), forKey: "lb.editor.fontSize")
        case "editor.zoomReset":
            UserDefaults.standard.set(15.0, forKey: "lb.editor.fontSize")
        case "openSite":
            let raw = (dashboard.data["siteURL"] as? String) ?? LBUIConnectionSettings()["site"] as? String ?? "https://huowenlong.com"
            if let url = URL(string: raw), url.scheme?.lowercased() == "https" {
                NSWorkspace.shared.open(url)
            }
        default: break
        }
    }
}

@MainActor final class DashboardModel: ServiceModel {
    @Published var data: [String: Any] = [:]
    @Published var refreshed: Date?
    private var verificationID = UUID()
    private var verifying = false
    private var nextVerification = Date.distantPast
    func invalidate() {
        verificationID = UUID(); verifying = false; nextVerification = .distantPast
        data = [:]; refreshed = nil
    }
    func openLocal() {
        if !data.isEmpty { verifyIfNeeded(); return }
        guard !busy else { return }
        run("dashboard", "site.cached") { result in
            self.data = result
            self.refreshed = result["checkedAt"] as? Date
            LBUIRequest("inbox.pollIfUnlocked", [:]) { _, _ in }
            self.verifyIfNeeded()
        }
    }
    private func mergeSnapshot(_ result: [String: Any]) {
        for (key, value) in result {
            if value is NSNull { continue }
            if let map = value as? NSDictionary, map.count == 0, key != "errors" { continue }
            data[key] = value
        }
    }
    func receiveProgress() {
        guard verifying else { return }
        let id = verificationID
        LBUIRequest("site.live", [:]) { result, _ in
            guard self.verifying, self.verificationID == id, let result else { return }
            self.mergeSnapshot(result)
        }
    }
    func verifyIfNeeded() {
        guard Date() >= nextVerification else { return }
        refresh(manual: false)
    }
    func refresh(manual: Bool = true) {
        guard !verifying, !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        nextVerification = Date().addingTimeInterval(60)
        let id = UUID(); verificationID = id; verifying = true
        LBUIRequest("site.refresh", ["manual": manual]) { result, _ in
            guard self.verificationID == id else { return }
            self.verifying = false
            if let result { self.mergeSnapshot(result); self.refreshed = Date() }
        }
    }
}

struct PostDraft: Equatable {
    var id = "", title = "", markdown = "", summary = "", tags = "", published = false, bodyFormat = "markdown"
    var createdAt: Double = 0, updatedAt: Double = 0, publishedAt: Double = 0
    var directory: URL?
    var sourceRevision = ""
    init() {}
    init(_ row: [String: Any]) {
        id = row["id"] as? String ?? ""
        title = row["title"] as? String ?? ""
        markdown = row["markdown"] as? String ?? ""
        summary = row["manualSummary"] as? String ?? row["summary"] as? String ?? ""
        tags = (row["tags"] as? [String] ?? []).joined(separator: ", ")
        published = (row["publish"] as? NSNumber)?.boolValue ?? false
        createdAt = (row["createdAt"] as? NSNumber)?.doubleValue ?? 0
        updatedAt = (row["updatedAt"] as? NSNumber)?.doubleValue ?? 0
        publishedAt = (row["publishedAt"] as? NSNumber)?.doubleValue ?? 0
        sourceRevision = row["sourceRevision"] as? String ?? ""
        directory = row["directory"] as? URL
        bodyFormat = row["bodyFormat"] as? String ?? "markdown"
    }
    static func == (lhs: PostDraft, rhs: PostDraft) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.markdown == rhs.markdown &&
        lhs.summary == rhs.summary &&
        lhs.tags == rhs.tags &&
        lhs.published == rhs.published &&
        lhs.bodyFormat == rhs.bodyFormat &&
        lhs.directory == rhs.directory
    }
    var arguments: [String: Any] {
        ["id": id, "sourceRevision": sourceRevision, "title": title, "markdown": markdown, "summary": summary, "publish": published,
         "tags": tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }]
    }
}

@MainActor final class PostsModel: ServiceModel {
    @Published var articles: [DataRow] = []
    @Published var staged: [[String: Any]] = []
    @Published var draft = PostDraft()
    @Published var editing = false
    @Published var splitPreview = UserDefaults.standard.object(forKey: "lb.editor.split") as? Bool ?? true {
        didSet { UserDefaults.standard.set(splitPreview, forKey: "lb.editor.split") }
    }
    @Published var filter = "全部"
    @Published var search = ""
    @Published var folder = "Posts"
    @Published var loaded = false
    @Published var frozenReview: [[String: Any]] = []
    @Published var commitMessage = "Update articles from longBlog macOS"
    var nextCheck = Date.distantPast
    var checkID = UUID()
    func checkForChanges() {
        guard loaded, !editing, !busy, !isDirty, Date() >= nextCheck else { return }
        nextCheck = Date().addingTimeInterval(60)
        let id = UUID(); checkID = id
        LBUIRequest("posts.check", [:]) { result, _ in
            let app = AppModel.shared
            guard self.checkID == id, app.section == .posts, !app.connectionLocked, !app.showingSettings,
                  !self.editing, !self.isDirty, result?["changed"] as? Bool == true else { return }
            self.run("sync", "posts.sync") { _ in
                self.refresh(autoSelectFirst: self.draft.id.isEmpty)
                if !self.editing && !self.isDirty { self.reloadCurrent() }
            }
        }
    }
    private var saved = PostDraft()
    var isDirty: Bool { draft != saved }
    var stagedIDs: Set<String> { Set(staged.compactMap { $0["id"] as? String }) }
    var draftCount: Int { articles.filter { !$0.flag("publish") }.count }
    var publishedCount: Int { articles.filter { $0.flag("publish") }.count }
    var filtered: [DataRow] {
        articles.filter {
            let matchesFilter = filter == "全部" || ($0.flag("publish") ? filter == "已发布" : filter == "草稿")
            guard matchesFilter else { return false }
            guard !search.isEmpty else { return true }
            let tags = ($0.data["tags"] as? [String] ?? []).joined(separator: " ")
            return $0.text("title").localizedCaseInsensitiveContains(search)
                || $0.text("summary").localizedCaseInsensitiveContains(search)
                || tags.localizedCaseInsensitiveContains(search)
        }
    }
    private var awaitingWorkspaceRefresh = false
    func workspaceChanged() {
        guard !awaitingWorkspaceRefresh else { return }
        awaitingWorkspaceRefresh = true
        whenIdle {
            self.awaitingWorkspaceRefresh = false
            self.refresh()
            self.whenIdle {
                guard !self.isDirty, !self.editing, !self.draft.id.isEmpty else { return }
                if self.articles.contains(where: { $0.id == self.draft.id }) { self.reloadCurrent() }
                else { self.resetBuffer() }
            }
        }
    }
    func resetBuffer() { draft = PostDraft(); saved = draft; editing = false; frozenReview = [] }
    func reloadCurrent() {
        guard !draft.id.isEmpty, !isDirty else { return }
        let id = draft.id
        run("load", "posts.load", ["id": id]) { self.draft = PostDraft($0); self.saved = self.draft }
    }
    func openLocal() {
        run("list", "posts.cached") { result in
            if let snapshot = result["rows"] as? [[String: Any]] {
                self.articles = rows(snapshot); self.folder = result["folder"] as? String ?? "Posts"
                if AppModel.shared.section == .posts, self.draft.id.isEmpty, !self.editing, let first = self.filtered.first { self.select(first) }
            }
            self.refresh(autoSelectFirst: AppModel.shared.section == .posts)
        }
    }
    func refresh(autoSelectFirst: Bool = false) {
        run("list", "posts.list") {
            self.articles = rows($0["rows"])
            self.staged = $0["staged"] as? [[String: Any]] ?? []
            self.folder = $0["folder"] as? String ?? "Posts"
            self.loaded = true
            if (autoSelectFirst || AppModel.shared.section == .posts), self.draft.id.isEmpty, !self.editing, let first = self.filtered.first {
                self.select(first)
            }
            self.whenIdle {
                if AppModel.shared.section == .posts { AppModel.shared.checkVisibleSection() }
            }
        }
    }
    func discardThen(_ action: @escaping () -> Void) {
        guard !busy else { whenIdle { self.discardThen(action) }; return }
        if isDirty { AppModel.shared.confirm("放弃未保存的文章修改？", "当前编辑缓冲区将被替换。本地已保存文件不受影响。", button: "放弃修改", destructive: true, action: action) } else { action() }
    }
    func select(_ row: DataRow, keepStudioMode: Bool? = nil) {
        guard row.id != draft.id else { return }
        let stayEditing = keepStudioMode ?? (editing && splitPreview)
        discardThen {
            self.run("load", "posts.load", ["id": row.id]) {
                self.draft = PostDraft($0)
                self.saved = self.draft
                self.editing = stayEditing
            }
        }
    }
    func newArticle() {
        discardThen {
            self.run("new", "posts.new") {
                self.draft = PostDraft($0)
                self.saved = self.draft
                self.editing = true
            }
        }
    }
    func save(after: (() -> Void)? = nil) {
        guard !busy, !draft.id.isEmpty else { return }
        guard isDirty else { successes["save"] = "文章没有变化，未重写文件或 updatedAt。"; after?(); return }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errors["save"] = "请填写文章标题。"; return }
        let frozen = draft
        run("save", "posts.save", frozen.arguments, success: "文章已保存到本地；线上内容尚未改变。") { result in
            self.draft = PostDraft(result); self.saved = self.draft
            after?()
            self.refresh()
        }
    }
    func stage(_ publish: Bool) {
        guard !draft.id.isEmpty, !busy else { return }
        let id = draft.id
        let apply = {
            self.run("stage", "posts.stage", ["id": id, "publish": publish],
                     success: publish ? "已暂存发布；请审阅后批量提交。" : "已暂存下架；线上尚未改变。") { _ in
                self.refresh(); self.reloadCurrent()
            }
        }
        if isDirty { save(after: apply) } else { apply() }
    }
    func delete(_ row: DataRow) {
        guard !busy else { return }
        if row.flag("publish") {
            let targetID = row.id
            AppModel.shared.confirm("已发布文章不能直接删除", "请先暂存下架，提交到 main 并确认线上撤下后再删除草稿。", button: "暂存下架") {
                let apply = {
                    self.run("stage", "posts.stage", ["id": targetID, "publish": false], success: "已暂存下架；请审阅提交到 main 变为草稿后再删除。") { _ in
                        self.refresh()
                        if self.draft.id == targetID { self.reloadCurrent() }
                    }
                }
                if self.draft.id == targetID && self.isDirty { self.save(after: apply) } else { apply() }
            }
            return
        }
        if stagedIDs.contains(row.id) {
            AppModel.shared.confirm("文章仍在暂存队列", "请先在暂存队列撤销或提交该文章，完成线上状态变更后再删除。", button: "知道了") {}
            return
        }
        let targetID = row.id
        AppModel.shared.confirm("永久删除草稿？", "将删除「\(row.text("title").isEmpty ? "未命名文章" : row.text("title"))」及其文章目录与附件。此操作不可撤销。", button: "删除草稿", destructive: true) {
            self.run("delete", "posts.delete", ["id": targetID], success: "草稿已删除。") { _ in
                if self.draft.id == targetID { self.resetBuffer() }
                self.refresh(autoSelectFirst: self.draft.id.isEmpty)
            }
        }
    }
    func sync() {
        guard !busy else { return }
        AppModel.shared.confirm("同步 GitHub 文章？", "下载 main 的文章和附件。Core 会保留本地草稿、修改和待确认事务；不会自动提交。", button: "同步") {
            self.run("sync", "posts.sync", success: "GitHub 同步完成；本地修改已保留。") { _ in
                self.refresh(autoSelectFirst: self.draft.id.isEmpty)
                self.reloadCurrent()
            }
        }
    }
    func review() {
        guard !busy, !staged.isEmpty else { return }
        if isDirty { errors["review"] = "请先保存当前文章再审阅提交。"; return }
        frozenReview = staged; AppModel.shared.showingReview = true
    }
    func commit() {
        let frozen = frozenReview, message = commitMessage
        guard !frozen.isEmpty, !busy else { return }
        AppModel.shared.confirm("将 \(frozen.count) 项变更提交到 main？", "创建一个原子提交，并以非强制方式更新分支。失败或结果未知时不自动重试；Core 的 pending 保护保持生效。", button: "提交到 main") {
            self.run("commit", "posts.commit", ["rows": frozen, "message": message], success: "文章批次已提交。部署仍需等待流水线。") { _ in
                AppModel.shared.showingReview = false; self.refresh(); self.reloadCurrent()
            }
        }
    }
    func revert() {
        let frozen = frozenReview.isEmpty ? staged : frozenReview
        guard !frozen.isEmpty, !busy else { return }
        AppModel.shared.confirm("撤销这 \(frozen.count) 项暂存？", "Core 将验证冻结的 revertGuard 与远端基准。已跟踪的本地改动可能被还原；从未发布的草稿和未跟踪附件保留。不会创建远端提交。", button: "撤销暂存", destructive: true) {
            self.run("revert", "posts.revert", ["rows": frozen], success: "冻结选择的暂存变更已撤销。") { _ in
                AppModel.shared.showingReview = false; self.refresh()
                if !self.draft.id.isEmpty {
                    let id = self.draft.id
                    self.run("load", "posts.load", ["id": id]) { self.draft = PostDraft($0); self.saved = self.draft }
                }
            }
        }
    }
    /// Copies files into the article's asset folder. A dirty draft is saved first so the
    /// assets land in the stable per-article directory. Markdown is inserted at the caret.
    func importFiles(_ urls: [URL], insert: ((String) -> Void)? = nil) {
        guard !busy, !draft.id.isEmpty, !urls.isEmpty else { return }
        if isDirty {
            guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errors["attachment"] = "请先填写文章标题，保存后才能导入附件。"
                return
            }
            save { self.importFiles(urls, insert: insert) }
            return
        }
        var remaining = urls
        let first = remaining.removeFirst()
        let id = draft.id
        run("attachment", "posts.import", ["id": id, "url": first], success: "附件已复制到文章资源目录；保存后随文章一起审阅提交。") { result in
            guard self.draft.id == id, let path = result["path"] as? String else { return }
            let name = (result["filename"] as? String ?? "附件").replacingOccurrences(of: "]", with: "\\]")
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let image = ["png", "jpg", "jpeg", "gif", "webp"].contains(first.pathExtension.lowercased())
            let snippet = "\(image ? "!" : "")[\(name)](\(encoded))\n"
            if let insert = insert { insert(snippet) } else { self.draft.markdown += "\n" + snippet }
            self.draft.directory = result["directory"] as? URL
            if !remaining.isEmpty { DispatchQueue.main.async { self.importFiles(remaining, insert: insert) } }
        }
    }
}

@MainActor final class InboxModel: ServiceModel {
    @Published var sessions: [DataRow] = []
    @Published var messages: [DataRow] = []
    @Published var selected: DataRow?
    @Published var archived = false
    @Published var loaded = false
    @Published var reply = ""
    @Published var search = ""
    @Published var unread = 0
    @Published var lastSync: Date?
    @Published var contact: [String: Any]?
    @Published var archiveCursor = ""
    @Published var messageCursor = 0
    @Published var failedReply: (id: String, text: String)?
    var pendingSelectID: String?
    private var listRevision = UUID()
    private var selectionRevision = UUID()

    var filtered: [DataRow] {
        sessions.filter {
            search.isEmpty ||
            $0.text("title").localizedCaseInsensitiveContains(search) ||
            $0.id.localizedCaseInsensitiveContains(search) ||
            (($0.data["last"] as? [String: Any])?["text"] as? String ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private var workspaceHasFocus = false
    private var visibleConversation: Bool {
        workspaceHasFocus && AppModel.shared.section == .inbox && !archived
    }

    func workspaceFocusChanged(_ focused: Bool, reload: Bool = true) {
        workspaceHasFocus = focused
        guard AppModel.shared.confirmation == nil, pendingSelectID == nil else {
            if !focused { setActiveSession(nil) }
            return
        }
        setActiveSession(selected?.id)
        if reload, visibleConversation, selected != nil { loadMessages() }
    }

    func setActiveSession(_ id: String?) {
        LBUIRequest("inbox.active", ["id": visibleConversation ? id ?? "" : ""]) { _, _ in }
    }

    func syncFromCore() {
        LBUIRequest("inbox.syncState", [:]) { [weak self] result, _ in
            guard let self = self, let result = result else { return }
            self.unread = (result["unread"] as? NSNumber)?.intValue ?? 0
            if let syncDate = result["lastSync"] as? Date { self.lastSync = syncDate }
            if !self.archived, let rawRows = result["rows"] {
                let updated = rows(rawRows)
                if !updated.isEmpty || self.loaded {
                    self.sessions = updated
                    if let selected = self.selected, let refreshed = updated.first(where: { $0.id == selected.id }) {
                        self.selected = refreshed
                        if self.visibleConversation, refreshed.number("lastUserSequence") > selected.number("lastUserSequence") {
                            self.loadMessages()
                        }
                    }
                }
            }
        }
    }

    private var cachedSessionsByArchive: [Bool: [DataRow]] = [:]
    private var cachedLoadedByArchive: [Bool: Bool] = [:]

    func refresh(more: Bool = false) {
        var args: [String: Any] = [:]
        if more && !archiveCursor.isEmpty { args["cursor"] = archiveCursor }
        let targetArchive = archived
        let revision = listRevision
        let previous = more ? sessions : []
        run("sessions", targetArchive ? "inbox.archives" : "inbox.list", args) { result in
            let nextRows = previous + rows(result["rows"])
            self.cachedSessionsByArchive[targetArchive] = nextRows
            self.cachedLoadedByArchive[targetArchive] = true
            guard self.listRevision == revision, self.archived == targetArchive else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                self.sessions = nextRows
                self.loaded = true
            }
            self.archiveCursor = result["cursor"] as? String ?? ""
            if !self.archived {
                self.unread = (result["unread"] as? NSNumber)?.intValue ?? 0
                if let syncDate = result["lastSync"] as? Date { self.lastSync = syncDate }
                LBUIRequest("inbox.polling", ["active": true]) { _, _ in }
            }
            if let wanted = self.pendingSelectID {
                self.pendingSelectID = nil
                if let hit = self.sessions.first(where: { $0.id == wanted }) { self.select(hit) }
                else { self.errors["sessions"] = "该会话已不在当前列表中。" }
            } else if self.selected == nil, let first = self.sessions.first {
                self.select(first)
            }
        }
    }

    func setArchived(_ value: Bool, selecting sessionID: String? = nil) {
        guard value != archived else { return }
        let action = {
            self.pendingSelectID = sessionID
            self.setActiveSession(nil)
            if self.loaded {
                self.cachedSessionsByArchive[self.archived] = self.sessions
                self.cachedLoadedByArchive[self.archived] = true
            }
            let revision = UUID()
            self.listRevision = revision
            self.archived = value
            self.selected = nil
            self.messages = []
            self.reply = ""
            self.failedReply = nil
            self.contact = nil
            self.selectionRevision = UUID()
            self.archiveCursor = ""
            self.sessions = self.cachedSessionsByArchive[value] ?? []
            self.loaded = self.cachedLoadedByArchive[value] ?? false
            self.whenIdle {
                guard self.listRevision == revision else { return }
                self.refresh()
            }
        }
        if !reply.isEmpty { AppModel.shared.confirm("放弃未发送的回复？", "切换会话列表会清除回复输入。", button: "放弃回复", destructive: true, action: action) } else { action() }
    }

    func select(_ row: DataRow) {
        guard !busy, selected?.id != row.id else { return }
        let action = {
            self.selected = row; self.messages = []; self.reply = ""
            self.failedReply = nil; self.contact = nil; self.messageCursor = 0
            self.selectionRevision = UUID()
            if AppModel.shared.section == .inbox && !self.archived { self.setActiveSession(row.id) }
            self.loadMessages()
        }
        if !reply.isEmpty { AppModel.shared.confirm("放弃未发送的回复？", "回复内容不会发送或保存。", button: "放弃回复", destructive: true, action: action) } else { action() }
    }

    func loadMessages() {
        guard let selected = selected else { return }
        let revision = selectionRevision
        run("messages", "inbox.messages", ["id": selected.id, "archived": archived, "cursor": messageCursor]) { result in
            guard self.selectionRevision == revision else { return }
            let incoming = rows(result["rows"])
            let existing = Set(self.messages.map(\.id))
            self.messages += incoming.filter { !existing.contains($0.id) }
            self.messages.sort { $0.number("sequence") < $1.number("sequence") }
            self.messageCursor = (result["cursor"] as? NSNumber)?.intValue ?? self.messageCursor
            if self.visibleConversation,
               let maxVisitorSeq = self.messages.filter({ $0.flag("visitor") }).map({ Int($0.number("sequence")) }).max(),
               maxVisitorSeq > 0 {
                self.run("read", "inbox.read", ["id": selected.id, "sequence": maxVisitorSeq])
            }
        }
    }

    func fetchContact() {
        guard let selected = selected else { return }
        let revision = selectionRevision
        run("contact", "inbox.contact", ["id": selected.id]) { if revision == self.selectionRevision { self.contact = $0 } }
    }

    func markRead(_ row: DataRow) {
        guard !archived, row.flag("unread") else { return }
        let seq = Int(row.number("lastUserSequence"))
        run("read", "inbox.read", ["id": row.id, "sequence": max(1, seq)]) { result in
            self.unread = (result["unread"] as? NSNumber)?.intValue ?? max(0, self.unread - 1)
            self.syncFromCore()
        }
    }

    func deleteArchive(_ row: DataRow) {
        guard archived, !busy else { return }
        let titleText = row.text("title").isEmpty ? String(row.id.prefix(6)).uppercased() : row.text("title")
        AppModel.shared.confirm("永久删除归档会话 #\(titleText)？", "将永久删除该会话的云端归档、残留消息及访客邮箱记录，其他设备也将无法再查看，且不可恢复。", button: "永久删除", destructive: true) {
            self.run("deleteArchive", "inbox.deleteArchive", ["id": row.id], success: "归档会话已删除。") { _ in
                if self.selected?.id == row.id {
                    self.selected = nil
                    self.messages = []
                    self.contact = nil
                }
                self.sessions.removeAll { $0.id == row.id }
                self.cachedSessionsByArchive[true] = self.sessions
                if self.selected == nil, let first = self.sessions.first {
                    self.select(first)
                }
            }
        }
    }

    func send() {
        guard !busy, !archived, let selected = selected else { return }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let messageID = failedReply?.text == text ? failedReply!.id : UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        AppModel.shared.confirm("发送回复？", "发送到访客 · \(selected.text("title"))。\n\n\(text)", button: "发送回复") {
            self.failedReply = (messageID, text)
            self.run("reply", "inbox.reply", ["id": selected.id, "messageID": messageID, "text": text], success: "回复已发送。") { result in
                self.reply = ""; self.failedReply = nil
                let row = DataRow(data: result)
                if !self.messages.contains(where: { $0.id == row.id }) { self.messages.append(row) }
            }
        }
    }
}

@MainActor final class MemosModel: ServiceModel {
    @Published var items: [DataRow] = []
    @Published var original: [String: Any]?
    @Published var content = ""
    @Published var visibility = "PRIVATE"
    @Published var resources: [[String: Any]] = []
    @Published var selectedID: String?
    @Published var editing = false
    @Published var archived = false
    @Published var more = false
    @Published var loaded = false
    @Published var search = ""
    @Published var username = ""
    @Published var cacheTotal = 0
    @Published var cacheCompleted = 0
    @Published var cacheFailed = 0
    @Published var cacheRunning = false
    @Published var cacheVersion = 0
    @Published var localResourceURLs: [String: URL] = [:]
    @Published var loadingResourceKeys = Set<String>()
    private var savedContent = "", savedVisibility = "PRIVATE"
    private var savedResourceIDs: [Int] = []
    var resourceIDs: [Int] { resources.compactMap { ($0["id"] as? NSNumber)?.intValue } }
    var isDirty: Bool { content != savedContent || visibility != savedVisibility || resourceIDs != savedResourceIDs }
    var filtered: [DataRow] {
        guard !search.isEmpty else { return items }
        return items.filter { $0.text("content").localizedCaseInsensitiveContains(search) }
    }
    func assign(_ row: [String: Any]?) {
        original = row; selectedID = (row?["id"] as? NSNumber)?.stringValue
        content = row?["content"] as? String ?? ""; visibility = row?["visibility"] as? String ?? "PRIVATE"
        resources = row?["resourceList"] as? [[String: Any]] ?? []
        savedContent = content; savedVisibility = visibility; savedResourceIDs = resourceIDs; editing = true
    }
    func discardThen(_ action: @escaping () -> Void) {
        guard !busy else { whenIdle { self.discardThen(action) }; return }
        if isDirty { AppModel.shared.confirm("放弃说说编辑？", "未保存的正文和附件关联将被丢弃。已上传到服务端的孤立附件不会被自动删除。", button: "放弃编辑", destructive: true, action: action) } else { action() }
    }
    func newMemo() { discardThen { self.assign(nil); self.archived = false } }
    func select(_ row: DataRow) { guard row.id != selectedID else { return }; discardThen { self.assign(row.data) } }
    private var cachedRowsByArchive: [Bool: [DataRow]] = [:]
    private var cachedLoadedByArchive: [Bool: Bool] = [:]

    func setArchived(_ value: Bool) {
        guard archived != value else { return }
        discardThen {
            let targetState = value ? "ARCHIVED" : "NORMAL"
            let id = UUID()
            self.checkID = id
            self.nextCheck = .distantPast
            self.archived = value
            self.items = self.cachedRowsByArchive[value] ?? []
            self.loaded = self.cachedLoadedByArchive[value] ?? false
            self.more = false
            self.assign(self.items.first?.data)
            self.editing = !self.items.isEmpty
            LBUIRequest("memos.cached", ["state": targetState]) { result, _ in
                guard self.checkID == id, self.archived == value else { return }
                if let list = result?["rows"] as? [[String: Any]] { self.display(list) }
                self.check(manual: false, id: id)
            }
        }
    }
    var nextCheck = Date.distantPast
    var checkID = UUID()
    private var state: String { archived ? "ARCHIVED" : "NORMAL" }
    private var attachmentAccount = UUID()
    func clearAccount() {
        attachmentAccount = UUID(); previewAttachment = nil
        localResourceURLs = [:]; loadingResourceKeys = []
        cachedRowsByArchive = [:]; cachedLoadedByArchive = [:]
        cacheTotal = 0; cacheCompleted = 0; cacheFailed = 0; cacheRunning = false; cacheVersion &+= 1
        checkID = UUID(); nextCheck = .distantPast; items = []; loaded = false
        username = ""; assign(nil); editing = false; more = false
    }
    func receiveCacheProgress(_ info: [String: Any]) {
        cacheTotal = (info["total"] as? NSNumber)?.intValue ?? cacheTotal
        cacheCompleted = (info["completed"] as? NSNumber)?.intValue ?? cacheCompleted
        cacheFailed = (info["failed"] as? NSNumber)?.intValue ?? cacheFailed
        cacheRunning = (info["running"] as? NSNumber)?.boolValue ?? false
        cacheVersion &+= 1
        // Refresh cached URLs for visible resources whenever background downloads complete.
        for res in resources { resolveCachedURL(for: res, downloadIfMissing: false) }
        for item in items.prefix(30) {
            if let list = item.data["resourceList"] as? [[String: Any]] {
                for res in list.prefix(3) { resolveCachedURL(for: res, downloadIfMissing: false) }
            }
        }
    }
    func resourceKey(_ resource: [String: Any]) -> String {
        let id = (resource["id"] as? NSNumber)?.stringValue ?? (resource["id"] as? String) ?? ""
        let updated = (resource["updatedTs"] as? NSNumber)?.stringValue ?? ""
        let size = (resource["size"] as? NSNumber)?.stringValue ?? ""
        let name = (resource["filename"] as? String) ?? (resource["name"] as? String) ?? ""
        return "\(id)|\(updated)|\(size)|\(name)"
    }
    func resolveCachedURL(for resource: [String: Any], downloadIfMissing: Bool = false) {
        let key = resourceKey(resource)
        guard !key.isEmpty else { return }
        if let existing = localResourceURLs[key], FileManager.default.fileExists(atPath: existing.path) { return }
        let account = attachmentAccount
        LBUIRequest("memos.cachedResource", ["resource": resource]) { [weak self] result, _ in
            guard let self, self.attachmentAccount == account else { return }
            if let url = result?["url"] as? URL, url.isFileURL {
                self.localResourceURLs[key] = url
                self.loadingResourceKeys.remove(key)
                return
            }
            guard downloadIfMissing, !self.loadingResourceKeys.contains(key) else { return }
            self.loadingResourceKeys.insert(key)
            LBUIRequest("memos.download", ["resource": resource]) { [weak self] dl, _ in
                guard let self, self.attachmentAccount == account else { return }
                self.loadingResourceKeys.remove(key)
                if let url = dl?["url"] as? URL, url.isFileURL {
                    self.localResourceURLs[key] = url
                }
            }
        }
    }
    private func display(_ list: [[String: Any]]) {
        let parsed = rows(list)
        cachedRowsByArchive[archived] = parsed
        cachedLoadedByArchive[archived] = true
        let changed = !(items.map(\.data) as NSArray).isEqual(to: list)
        if changed { items = parsed }
        loaded = true; more = false
        guard !isDirty, !busy else { return }
        if let selectedID, changed {
            if let fresh = items.first(where: { $0.id == selectedID }) {
                self.assign(fresh.data)
            } else { assign(nil); editing = false }
        }
        if !editing, let first = items.first { assign(first.data) }
    }
    func openLocal() {
        guard !busy, Date() >= nextCheck else { return }
        nextCheck = Date().addingTimeInterval(60)
        let id = UUID(); checkID = id
        let otherArchive = !archived
        let otherState = otherArchive ? "ARCHIVED" : "NORMAL"
        if cachedRowsByArchive[otherArchive] == nil {
            LBUIRequest("memos.cached", ["state": otherState]) { [weak self] res, _ in
                guard let self, let list = res?["rows"] as? [[String: Any]] else { return }
                self.cachedRowsByArchive[otherArchive] = rows(list)
                self.cachedLoadedByArchive[otherArchive] = true
            }
        }
        if loaded { check(manual: false, id: id); return }
        LBUIRequest("memos.cached", ["state": state]) { result, _ in
            guard self.checkID == id else { return }
            if let list = result?["rows"] as? [[String: Any]] { self.display(list) }
            self.check(manual: false, id: id)
        }
    }
    private func check(manual: Bool, id: UUID) {
        LBUIRequest("memos.check", ["state": state, "manual": manual]) { result, error in
            guard self.checkID == id else { return }
            if let error {
                if (error as NSError).code == 401 {
                    self.items = []; self.loaded = false; self.assign(nil); self.editing = false; self.username = ""
                }
                if manual || !self.loaded { self.errors["list"] = error.localizedDescription }
                return
            }
            self.errors["list"] = nil
            self.username = result?["username"] as? String ?? ""
            if let list = result?["rows"] as? [[String: Any]] { self.display(list) }
            LBUIRequest("memos.prefetch", [:]) { info, _ in
                if let info { self.receiveCacheProgress(info) }
            }
        }
    }
    func refresh() {
        guard !busy else { return }
        nextCheck = Date().addingTimeInterval(60)
        let id = UUID(); checkID = id; check(manual: true, id: id)
    }
    func load(more: Bool = false) {
        let id = UUID(); checkID = id; check(manual: false, id: id)
    }
    func save() {
        guard editing, !busy else { return }
        guard isDirty || original == nil else { successes["save"] = "说说没有变化，未发送写入。"; return }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !resources.isEmpty else { errors["save"] = "正文与附件不能同时为空。"; return }
        var args: [String: Any] = ["content": content, "visibility": visibility, "resourceIDs": resourceIDs]
        if let original = original { args["original"] = original }
        let visibilityName = visibility == "PUBLIC" ? "公开" : visibility == "PROTECTED" ? "登录可见" : "仅自己"
        AppModel.shared.confirm(original == nil ? "创建说说？" : "保存说说？", "可见性：\(visibilityName)；附件：\(resources.count) 个。客户端会检查远端原记录，但 legacy API 不具备原子 CAS。", button: "保存到 Memos") {
            self.run("save", "memos.save", args, success: "说说已保存到 Memos。") { self.assign($0); self.load() }
        }
    }
    func update(_ fields: [String: Any], title: String, target: [String: Any]? = nil) {
        guard !busy, let targetRow = target ?? original else { return }
        let targetID = (targetRow["id"] as? NSNumber)?.stringValue
        if targetID == selectedID && isDirty { errors["update"] = "请先保存或放弃正文修改，再执行此操作。"; return }
        AppModel.shared.confirm(title, "仅修改当前说说；不会自动重试结果未知的写入。", button: title) {
            self.run("update", "memos.update", ["original": targetRow, "fields": fields], success: "说说状态已更新。") { updated in
                if self.selectedID == targetID { self.assign(updated) }
                self.load()
            }
        }
    }
    func importFiles(_ urls: [URL]) {
        guard !busy, editing, !urls.isEmpty else { return }
        if urls.count == 1 {
            importFile(urls[0])
            return
        }
        let names = urls.map(\.lastPathComponent).joined(separator: "、")
        AppModel.shared.confirm("上传 \(urls.count) 个附件到 Memos？", "将依次上传：\(names)\n上传后仍需保存说说才能建立关联；取消编辑不会自动删除服务端附件。", button: "全部上传") {
            self.uploadQueue(urls)
        }
    }
    private func uploadQueue(_ urls: [URL]) {
        guard let next = urls.first else { return }
        let remaining = Array(urls.dropFirst())
        run("upload", "memos.upload", ["url": next], success: remaining.isEmpty ? "附件已全部上传；请保存说说以建立关联。" : nil) { resource in
            self.resources.append(resource)
            if !remaining.isEmpty {
                self.uploadQueue(remaining)
            }
        }
    }
    func importFile(_ url: URL) {
        guard !busy, editing else { return }
        AppModel.shared.confirm("上传附件到 Memos？", "将上传 \(url.lastPathComponent)。上传后仍需保存说说才能关联；取消编辑不会自动删除服务端附件。", button: "上传") {
            self.run("upload", "memos.upload", ["url": url], success: "附件已上传；请保存说说以建立关联。") { self.resources.append($0) }
        }
    }
    @Published var previewAttachment: MemoPreviewAttachment?
    func openResource(_ resource: [String: Any], in list: [[String: Any]] = []) {
        let key = resourceKey(resource)
        let name = (resource["filename"] as? String) ?? (resource["name"] as? String) ?? "附件"
        let mime = (resource["type"] as? String ?? "").lowercased()
        let siblings: [MemoPreviewItem] = list.compactMap { item in
            let k = resourceKey(item)
            guard let url = localResourceURLs[k], url.isFileURL else { return nil }
            let n = (item["filename"] as? String) ?? (item["name"] as? String) ?? "附件"
            let m = (item["type"] as? String ?? "").lowercased()
            return MemoPreviewItem(key: k, url: url, name: n, mime: m)
        }
        if let local = localResourceURLs[key], FileManager.default.fileExists(atPath: local.path) {
            let current = MemoPreviewItem(key: key, url: local, name: name, mime: mime)
            let gallery = siblings.contains(where: { $0.key == key }) ? siblings : [current]
            previewAttachment = MemoPreviewAttachment(item: current, gallery: gallery)
            return
        }
        let account = attachmentAccount
        loadingResourceKeys.insert(key)
        LBUIRequest("memos.download", ["resource": resource]) { [weak self] result, error in
            guard let self, self.attachmentAccount == account else { return }
            self.loadingResourceKeys.remove(key)
            if let error { self.errors["download"] = error.localizedDescription; return }
            guard let url = result?["url"] as? URL, url.isFileURL else { return }
            self.localResourceURLs[key] = url
            let current = MemoPreviewItem(key: key, url: url, name: name, mime: mime)
            var gallery = siblings
            if !gallery.contains(where: { $0.key == key }) { gallery.append(current) }
            self.previewAttachment = MemoPreviewAttachment(item: current, gallery: gallery)
        }
    }
    func deleteArchived(_ target: [String: Any]? = nil) {
        guard !busy, let targetRow = target ?? original else { return }
        let targetID = (targetRow["id"] as? NSNumber)?.stringValue
        if targetID == selectedID && isDirty { errors["delete"] = "请先保存或放弃正文修改，再执行此操作。"; return }
        guard targetRow["rowStatus"] as? String == "ARCHIVED" else { return }
        let title = String((targetRow["content"] as? String ?? "这条说说").prefix(40))
        AppModel.shared.confirm("永久删除已归档说说？", "将永久删除「\(title)」及其服务端记录。此操作不可撤销。", button: "永久删除", destructive: true) {
            self.run("delete", "memos.delete", ["original": targetRow], success: "说说已永久删除。") { _ in
                if self.selectedID == targetID { self.assign(nil); self.editing = false }
                self.load()
            }
        }
    }
}

@MainActor final class ConfigurationModel: ServiceModel {
    var nextCheck = Date.distantPast
    var checkID = UUID()
    func openLocal() {
        guard !busy, !isDirty, !showingPreview, Date() >= nextCheck else { return }
        nextCheck = Date().addingTimeInterval(60)
        let id = UUID(); checkID = id
        func check() {
            LBUIRequest("env.load", ["sha": sha, "silent": true]) { result, error in
                guard id == self.checkID, !self.isDirty, !self.busy, !self.showingPreview else { return }
                if let error {
                    if self.baseline.isEmpty { self.errors["load"] = error.localizedDescription }
                    return
                }
                self.errors["load"] = nil
                if let result, result["unchanged"] == nil { self.apply(result) }
            }
        }
        if !baseline.isEmpty { check(); return }
        LBUIRequest("env.cached", [:]) { result, _ in
            guard id == self.checkID, !self.isDirty, !self.busy else { return }
            if let result, result["sha"] != nil { self.apply(result) }
            check()
        }
    }
    private var localProjection = false
    @Published var baseline = ""
    @Published var sha = ""
    @Published var repository = ""
    @Published var sections: [DataRow] = []
    @Published var values: [String: String] = [:]
    @Published var baselineValues: [String: String] = [:]
    @Published var selectedSection = 0
    @Published var search = ""
    @Published var preview = ""
    @Published var showingPreview = false
    var changedKeys: [String] { values.keys.filter { values[$0] != baselineValues[$0] }.sorted() }
    var isDirty: Bool { !changedKeys.isEmpty }
    func dirtyCount(in section: DataRow) -> Int {
        let keys = (section.data["keys"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
        return keys.filter { values[$0] != baselineValues[$0] }.count
    }
    func resetKey(_ key: String) {
        if let base = baselineValues[key] { values[key] = base }
    }
    func apply(_ result: [String: Any]) {
        localProjection = result["localProjection"] as? Bool ?? false
        baseline = result["text"] as? String ?? ""; sha = result["sha"] as? String ?? ""; repository = result["repo"] as? String ?? ""
        values = result["values"] as? [String: String] ?? [:]; baselineValues = values
        sections = (result["sections"] as? [[String: Any]] ?? []).enumerated().map { index, value in
            var copy = value; copy["id"] = String(index); return DataRow(data: copy)
        }
        selectedSection = min(selectedSection, max(0, sections.count - 1)); preview = ""
    }
    func refresh() {
        guard !busy else { return }
        let action = {
            self.checkID = UUID()
            self.run("load", "env.load", ["sha": self.isDirty ? "" : self.sha]) { result in
                if result["unchanged"] == nil { self.apply(result) }
            }
        }
        if isDirty { AppModel.shared.confirm("重新载入并放弃配置修改？", "本地表单修改尚未提交到 main。", button: "放弃并载入", destructive: true, action: action) } else { action() }
    }
    func revert() {
        guard !busy else { return }
        AppModel.shared.confirm("放弃配置修改？", "恢复本次读取的 .env 基准，不会修改远端。", button: "放弃修改", destructive: true) {
            self.values = self.baselineValues; self.preview = ""
        }
    }
    func arguments() -> [String: Any] {
        ["text": baseline, "values": values, "sha": sha, "repo": repository, "localProjection": localProjection, "baselineValues": baselineValues]
    }
    func review() {
        guard isDirty, !busy else { return }
        let args = arguments()
        checkID = UUID()
        run("preview", "env.preview", args) { result in self.preview = result["text"] as? String ?? ""; self.showingPreview = true }
    }
    func commit() {
        guard !busy, !preview.isEmpty else { return }
        let args = arguments(), frozen = preview
        AppModel.shared.confirm("提交 .env 到 main？", "仓库：\(repository)\n修改 \(changedKeys.count) 项公开字段。使用读取时 SHA 检查冲突；提交后等待流水线部署。网络结果未知时请先重新载入核对，不要重复写入。", button: "提交到 main") {
            self.run("commit", "env.save", args, success: "配置已提交到 main，等待站点部署。") { _ in
                self.baseline = frozen; self.baselineValues = self.values; self.showingPreview = false; self.sha = ""
                self.run("load", "env.load") { self.apply($0) }
            }
        }
    }
}
