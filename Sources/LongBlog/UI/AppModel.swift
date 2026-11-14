import SwiftUI
import AppKit
import Combine

struct DataRow: Identifiable {
    let data: [String: Any]
    var id: String { if let id = data["id"] as? String { return id }; return (data["id"] as? NSNumber)?.stringValue ?? UUID().uuidString }
    func text(_ key: String) -> String { data[key] as? String ?? "" }
    func flag(_ key: String) -> Bool { (data[key] as? NSNumber)?.boolValue ?? false }
    func number(_ key: String) -> Double { (data[key] as? NSNumber)?.doubleValue ?? 0 }
}
func rows(_ value: Any?) -> [DataRow] { (value as? [[String: Any]] ?? []).map { DataRow(data: $0) } }
func dateLabel(_ value: Double, milliseconds: Bool = true) -> String {
    guard value > 0 else { return "—" }
    return Date(timeIntervalSince1970: value / (milliseconds ? 1000 : 1)).formatted(date: .abbreviated, time: .shortened)
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
            if let error = error { self.errors[key] = error.localizedDescription; return }
            if let success = success { self.successes[key] = success }
            done(result ?? [:])
        }
    }
    func clearMessages() { errors = [:]; successes = [:] }
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
        switch self { case .dashboard: return "square.grid.2x2"; case .inbox: return "bubble.left.and.bubble.right"; case .posts: return "doc.text"; case .memos: return "quote.bubble"; case .configuration: return "slider.horizontal.3" }
    }
}
@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var section: WorkspaceSection = .dashboard
    @Published var confirmation: PendingConfirmation?
    @Published var showingSettings = false
    @Published var showingReview = false
    @Published var searchRequested = UUID()
    let dashboard = DashboardModel()
    let posts = PostsModel()
    let inbox = InboxModel()
    let memos = MemosModel()
    let configuration = ConfigurationModel()
    private init() {}
    var connectionLocked: Bool { posts.busy || inbox.busy || memos.busy || configuration.busy || dashboard.busy || showingReview || confirmation != nil }
    func resetConnectionViews() {
        posts.resetBuffer(); posts.articles = []; posts.staged = []; posts.loaded = false; posts.clearMessages()
        inbox.sessions = []; inbox.messages = []; inbox.selected = nil; inbox.contact = nil; inbox.reply = ""; inbox.failedReply = nil; inbox.loaded = false; inbox.unread = 0; inbox.clearMessages()
        memos.assign(nil); memos.items = []; memos.editing = false; memos.loaded = false; memos.username = ""; memos.clearMessages()
        configuration.baseline = ""; configuration.sha = ""; configuration.values = [:]; configuration.baselineValues = [:]; configuration.sections = []; configuration.clearMessages()
        dashboard.data = [:]; dashboard.refreshed = nil; dashboard.clearMessages()
    }
    /// Parent AppDelegate may use this for applicationShouldTerminate(.terminateLater).
    func confirmDiscardBeforeClose(_ completion: @escaping (Bool) -> Void) {
        if connectionLocked {
            let alert = NSAlert(); alert.messageText = "操作尚未完成"; alert.informativeText = "请等待当前操作结束后再退出。"; alert.runModal(); completion(false); return
        }
        guard !dirtyNames.isEmpty else { completion(true); return }
        let alert = NSAlert(); alert.messageText = "仍有未保存的修改"; alert.informativeText = dirtyNames.joined(separator: "、") + "尚未保存。退出将丢失编辑缓冲区。"
        alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃并退出")
        let finish: (NSApplication.ModalResponse) -> Void = { completion($0 == .alertSecondButtonReturn) }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
    var dirtyNames: [String] {
        var result: [String] = []
        if posts.isDirty { result.append("文章") }; if memos.isDirty { result.append("说说") }
        if configuration.isDirty { result.append("站点配置") }; if !inbox.reply.isEmpty { result.append("回复") }
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
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }
    func navigate(_ target: WorkspaceSection) { section = target; refreshIfNeeded() }
    // Editors are retained across section switches. Selection changes are separately confirmed.
    func refreshIfNeeded() {
        switch section {
        case .dashboard: if dashboard.data.isEmpty { dashboard.refresh() }
        case .posts: if !posts.loaded { posts.refresh() }
        case .inbox: if !inbox.loaded { inbox.refresh() }
        case .memos: if !memos.loaded { memos.refresh() }
        case .configuration: if configuration.baseline.isEmpty { configuration.refresh() }
        }
    }
    func newArticle() { navigate(.posts); posts.newArticle() }
    func newMemo() { navigate(.memos); memos.newMemo() }
    func save() {
        switch section { case .posts: posts.save(); case .memos: memos.save(); case .configuration: configuration.review(); default: break }
    }
    func review() { navigate(.posts); posts.review() }
    func refresh() {
        switch section { case .dashboard: dashboard.refresh(); case .posts: posts.refresh(); case .inbox: inbox.refresh(); case .memos: memos.refresh(); case .configuration: configuration.refresh() }
    }
    func editArticle() { navigate(.posts); posts.editing = true }
    func search() { searchRequested = UUID() }
    func route(_ name: String) {
        switch name { case "newArticle": newArticle(); case "newMemo": newMemo(); case "save": save(); case "review": review(); case "refresh": refresh(); case "search": search(); case "editArticle": editArticle(); default: break }
    }
}

@MainActor final class DashboardModel: ServiceModel {
    @Published var data: [String: Any] = [:]
    @Published var refreshed: Date?
    func refresh() { run("dashboard", "site.refresh") { self.data = $0; self.refreshed = Date() } }
}

struct PostDraft: Equatable {
    var id = "", title = "", markdown = "", summary = "", tags = "", published = false, bodyFormat = "markdown"
    var directory: URL?
    init() {}
    init(_ row: [String: Any]) {
        id = row["id"] as? String ?? ""; title = row["title"] as? String ?? ""
        markdown = row["markdown"] as? String ?? ""; summary = row["manualSummary"] as? String ?? row["summary"] as? String ?? ""
        tags = (row["tags"] as? [String] ?? []).joined(separator: ", ")
        published = (row["publish"] as? NSNumber)?.boolValue ?? false
        directory = row["directory"] as? URL; bodyFormat = row["bodyFormat"] as? String ?? "markdown"
    }
    var arguments: [String: Any] { ["id":id, "title":title, "markdown":markdown, "summary":summary, "publish":published, "tags":tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }] }
}
@MainActor final class PostsModel: ServiceModel {
    @Published var articles: [DataRow] = []
    @Published var staged: [[String: Any]] = []
    @Published var draft = PostDraft()
    @Published var editing = false
    @Published var filter = "全部"
    @Published var search = ""
    @Published var folder = "Posts"
    @Published var loaded = false
    @Published var frozenReview: [[String: Any]] = []
    @Published var commitMessage = "Update articles from longBlog macOS"
    private var saved = PostDraft()
    var isDirty: Bool { draft != saved }
    var filtered: [DataRow] { articles.filter { (filter == "全部" || ($0.flag("publish") ? filter == "已发布" : filter == "草稿")) && (search.isEmpty || $0.text("title").localizedCaseInsensitiveContains(search) || $0.text("summary").localizedCaseInsensitiveContains(search)) } }
    func resetBuffer() { draft = PostDraft(); saved = draft; editing = false; frozenReview = [] }
    func refresh() { run("list", "posts.list") { self.articles = rows($0["rows"]); self.staged = $0["staged"] as? [[String: Any]] ?? []; self.folder = $0["folder"] as? String ?? "Posts"; self.loaded = true } }
    func discardThen(_ action: @escaping () -> Void) {
        guard !busy else { return }
        if isDirty { AppModel.shared.confirm("放弃未保存的文章修改？", "当前编辑缓冲区将被替换。本地已保存文件不受影响。", button: "放弃修改", destructive: true, action: action) } else { action() }
    }
    func select(_ row: DataRow) {
        guard row.id != draft.id else { return }
        discardThen { self.run("load", "posts.load", ["id":row.id]) { self.draft = PostDraft($0); self.saved = self.draft; self.editing = false } }
    }
    func newArticle() { discardThen { self.run("new", "posts.new") { self.draft = PostDraft($0); self.saved = self.draft; self.editing = true } } }
    func save(after: (() -> Void)? = nil) {
        guard !busy, !draft.id.isEmpty else { return }
        guard isDirty else { successes["save"] = "文章没有变化，未重写文件或 updatedAt。"; after?(); return }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errors["save"] = "请填写文章标题。"; return }
        let frozen = draft
        run("save", "posts.save", frozen.arguments, success: "文章已保存到本地；线上内容尚未改变。") { result in
            self.draft = PostDraft(result); self.saved = self.draft; self.refresh(); after?()
        }
    }
    func stage(_ publish: Bool) {
        guard !draft.id.isEmpty, !busy else { return }
        let id = draft.id
        let apply = { self.run("stage", "posts.stage", ["id":id, "publish":publish], success: publish ? "已暂存发布；请审阅后批量提交。" : "已暂存下架；线上尚未改变。") { _ in self.refresh() } }
        if isDirty { save(after: apply) } else { apply() }
    }
    func sync() {
        guard !busy else { return }
        AppModel.shared.confirm("同步 GitHub 文章？", "下载 main 的文章和附件。Core 会保留本地草稿、修改和待确认事务；不会自动提交。", button: "同步") {
            self.run("sync", "posts.sync", success: "GitHub 同步完成；本地修改已保留。") { _ in self.refresh() }
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
            self.run("commit", "posts.commit", ["rows":frozen, "message":message], success: "文章批次已提交。部署仍需等待流水线。") { _ in AppModel.shared.showingReview = false; self.refresh() }
        }
    }
    func revert() {
        let frozen = frozenReview.isEmpty ? staged : frozenReview
        guard !frozen.isEmpty, !busy else { return }
        AppModel.shared.confirm("撤销这 \(frozen.count) 项暂存？", "Core 将验证冻结的 revertGuard 与远端基准。已跟踪的本地改动可能被还原；从未发布的草稿和未跟踪附件保留。不会创建远端提交。", button: "撤销暂存", destructive: true) {
            self.run("revert", "posts.revert", ["rows":frozen], success: "冻结选择的暂存变更已撤销。") { _ in
                AppModel.shared.showingReview = false; self.refresh()
                if !self.draft.id.isEmpty { let id = self.draft.id; self.run("load", "posts.load", ["id":id]) { self.draft = PostDraft($0); self.saved = self.draft } }
            }
        }
    }
    func importFile(_ url: URL) {
        guard !busy, !draft.id.isEmpty else { return }
        let id = draft.id
        run("attachment", "posts.import", ["id":id, "url":url], success: "附件已复制到文章资源目录；请保存文章并审阅提交。") { result in
            guard self.draft.id == id, let path = result["path"] as? String else { return }
            let name = (result["filename"] as? String ?? "附件").replacingOccurrences(of: "]", with: "\\]")
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let image = ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].contains(url.pathExtension.lowercased())
            self.draft.markdown += "\n\(image ? "!" : "")[\(name)](\(encoded))\n"
            self.draft.directory = result["directory"] as? URL
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
    @Published var contact: [String: Any]?
    @Published var archiveCursor = ""
    @Published var messageCursor = 0
    @Published var failedReply: (id: String, text: String)?
    private var selectionRevision = UUID()
    var filtered: [DataRow] { sessions.filter { search.isEmpty || $0.text("title").localizedCaseInsensitiveContains(search) || (($0.data["last"] as? [String: Any])?["text"] as? String ?? "").localizedCaseInsensitiveContains(search) } }
    func refresh(more: Bool = false) {
        var args: [String: Any] = [:]; if more && !archiveCursor.isEmpty { args["cursor"] = archiveCursor }
        run("sessions", archived ? "inbox.archives" : "inbox.list", args) { result in
            self.sessions = more ? self.sessions + rows(result["rows"]) : rows(result["rows"])
            self.archiveCursor = result["cursor"] as? String ?? ""; self.unread = (result["unread"] as? NSNumber)?.intValue ?? 0; self.loaded = true
        }
    }
    func setArchived(_ value: Bool) {
        guard value != archived, !busy else { return }
        let action = { self.archived = value; self.selected = nil; self.messages = []; self.reply = ""; self.failedReply = nil; self.contact = nil; self.selectionRevision = UUID(); self.sessions = []; self.refresh() }
        if !reply.isEmpty { AppModel.shared.confirm("放弃未发送的回复？", "切换会话列表会清除回复输入。", button: "放弃回复", destructive: true, action: action) } else { action() }
    }
    func select(_ row: DataRow) {
        guard !busy, selected?.id != row.id else { return }
        let action = { self.selected = row; self.messages = []; self.reply = ""; self.failedReply = nil; self.contact = nil; self.messageCursor = 0; self.selectionRevision = UUID(); self.loadMessages() }
        if !reply.isEmpty { AppModel.shared.confirm("放弃未发送的回复？", "回复内容不会发送或保存。", button: "放弃回复", destructive: true, action: action) } else { action() }
    }
    func loadMessages() {
        guard let selected = selected else { return }; let revision = selectionRevision
        run("messages", "inbox.messages", ["id":selected.id, "archived":archived, "cursor":messageCursor]) { result in
            guard self.selectionRevision == revision else { return }
            let incoming = rows(result["rows"]); let existing = Set(self.messages.map(\.id))
            self.messages += incoming.filter { !existing.contains($0.id) }
            self.messages.sort { $0.number("sequence") < $1.number("sequence") }
            self.messageCursor = (result["cursor"] as? NSNumber)?.intValue ?? self.messageCursor
            if !self.archived { self.run("read", "inbox.read", ["id":selected.id, "sequence":selected.data["lastUserSequence"] ?? 0]) }
        }
    }
    func fetchContact() {
        guard let selected = selected else { return }; let revision = selectionRevision
        run("contact", "inbox.contact", ["id":selected.id]) { if revision == self.selectionRevision { self.contact = $0 } }
    }
    func send() {
        guard !busy, !archived, let selected = selected else { return }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        let messageID = failedReply?.text == text ? failedReply!.id : UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        AppModel.shared.confirm("发送回复？", "发送到会话 \(selected.text("title"))。\n\n\(text)", button: "发送") {
            self.failedReply = (messageID, text)
            self.run("reply", "inbox.reply", ["id":selected.id, "messageID":messageID, "text":text], success: "回复已发送。") { result in
                self.reply = ""; self.failedReply = nil
                let row = DataRow(data: result); if !self.messages.contains(where: { $0.id == row.id }) { self.messages.append(row) }
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
    private var savedContent = "", savedVisibility = "PRIVATE"
    private var savedResourceIDs: [Int] = []
    var resourceIDs: [Int] { resources.compactMap { ($0["id"] as? NSNumber)?.intValue } }
    var isDirty: Bool { content != savedContent || visibility != savedVisibility || resourceIDs != savedResourceIDs }
    func assign(_ row: [String: Any]?) {
        original = row; selectedID = (row?["id"] as? NSNumber)?.stringValue
        content = row?["content"] as? String ?? ""; visibility = row?["visibility"] as? String ?? "PRIVATE"
        resources = row?["resourceList"] as? [[String: Any]] ?? []
        savedContent = content; savedVisibility = visibility; savedResourceIDs = resourceIDs; editing = true
    }
    func discardThen(_ action: @escaping () -> Void) {
        guard !busy else { return }
        if isDirty { AppModel.shared.confirm("放弃说说编辑？", "未保存的正文和附件关联将被丢弃。已上传到服务端的孤立附件不会被自动删除。", button: "放弃编辑", destructive: true, action: action) } else { action() }
    }
    func newMemo() { discardThen { self.assign(nil); self.archived = false } }
    func select(_ row: DataRow) { guard row.id != selectedID else { return }; discardThen { self.assign(row.data) } }
    func setArchived(_ value: Bool) { guard archived != value else { return }; discardThen { self.archived = value; self.assign(nil); self.editing = false; self.refresh() } }
    func refresh() {
        guard !busy else { return }
        run("identity", "memos.validate") { user in
            self.username = user["nickname"] as? String ?? user["username"] as? String ?? ""
            self.load()
        }
    }
    func load(more: Bool = false) {
        let offset = more ? items.count : 0
        run("list", "memos.list", ["state":archived ? "ARCHIVED" : "NORMAL", "text":search, "offset":offset]) { result in
            self.items = more ? self.items + rows(result["rows"]) : rows(result["rows"])
            self.more = (result["more"] as? NSNumber)?.boolValue ?? false; self.loaded = true
        }
    }
    func save() {
        guard editing, !busy else { return }
        guard isDirty || original == nil else { successes["save"] = "说说没有变化，未发送写入。"; return }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !resources.isEmpty else { errors["save"] = "正文与附件不能同时为空。"; return }
        var args: [String: Any] = ["content":content, "visibility":visibility, "resourceIDs":resourceIDs]
        if let original = original { args["original"] = original }
        let visibilityName = visibility == "PUBLIC" ? "公开" : visibility == "PROTECTED" ? "登录可见" : "仅自己"
        AppModel.shared.confirm(original == nil ? "创建说说？" : "保存说说？", "可见性：\(visibilityName)；附件：\(resources.count) 个。客户端会检查远端原记录，但 legacy API 不具备原子 CAS。", button: "保存到 Memos") {
            self.run("save", "memos.save", args, success: "说说已保存到 Memos。") { self.assign($0); self.load() }
        }
    }
    func update(_ fields: [String: Any], title: String) {
        guard !busy, let original = original else { return }
        guard !isDirty else { errors["update"] = "请先保存或放弃正文修改，再执行此操作。"; return }
        AppModel.shared.confirm(title, "仅修改当前说说；不会自动重试结果未知的写入。", button: title) {
            self.run("update", "memos.update", ["original":original, "fields":fields], success: "说说状态已更新。") { self.assign($0); self.load() }
        }
    }
    func importFile(_ url: URL) {
        guard !busy, editing else { return }
        AppModel.shared.confirm("上传附件到 Memos？", "将上传 \(url.lastPathComponent)。上传后仍需保存说说才能关联；取消编辑不会自动删除服务端附件。", button: "上传") {
            self.run("upload", "memos.upload", ["url":url], success: "附件已上传；请保存说说以建立关联。") { self.resources.append($0) }
        }
    }
    func openResource(_ resource: [String: Any]) {
        run("download", "memos.download", ["resource":resource]) { if let url = $0["url"] as? URL { NSWorkspace.shared.open(url) } }
    }
}

@MainActor final class ConfigurationModel: ServiceModel {
    @Published var baseline = ""
    @Published var sha = ""
    @Published var repository = ""
    @Published var sections: [DataRow] = []
    @Published var values: [String: String] = [:]
    @Published var baselineValues: [String: String] = [:]
    @Published var selectedSection = 0
    @Published var preview = ""
    @Published var showingPreview = false
    var changedKeys: [String] { values.keys.filter { values[$0] != baselineValues[$0] }.sorted() }
    var isDirty: Bool { !changedKeys.isEmpty }
    func apply(_ result: [String: Any]) {
        baseline = result["text"] as? String ?? ""; sha = result["sha"] as? String ?? ""; repository = result["repo"] as? String ?? ""
        values = result["values"] as? [String: String] ?? [:]; baselineValues = values
        sections = (result["sections"] as? [[String: Any]] ?? []).enumerated().map { index, value in var copy = value; copy["id"] = String(index); return DataRow(data: copy) }
        selectedSection = min(selectedSection, max(0, sections.count - 1)); preview = ""
    }
    func refresh() {
        guard !busy else { return }
        let action = { self.run("load", "env.load") { self.apply($0) } }
        if isDirty { AppModel.shared.confirm("重新载入并放弃配置修改？", "本地表单修改尚未提交到 main。", button: "放弃并载入", destructive: true, action: action) } else { action() }
    }
    func revert() { guard !busy else { return }; AppModel.shared.confirm("放弃配置修改？", "恢复本次读取的 .env 基准，不会修改远端。", button: "放弃修改", destructive: true) { self.values = self.baselineValues; self.preview = "" } }
    func arguments() -> [String: Any] { ["text":baseline, "values":values, "sha":sha, "repo":repository] }
    func review() {
        guard isDirty, !busy else { return }
        let args = arguments()
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
