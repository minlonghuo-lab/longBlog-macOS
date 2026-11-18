import SwiftUI
import UniformTypeIdentifiers

struct ConnectionSettingsView: View {
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var posts = AppModel.shared.posts
    @ObservedObject private var inbox = AppModel.shared.inbox
    @ObservedObject private var memos = AppModel.shared.memos
    @ObservedObject private var configuration = AppModel.shared.configuration
    @ObservedObject private var dashboard = AppModel.shared.dashboard
    @StateObject private var status = ServiceModel()
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String]
    @State private var baseline: [String: String]
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.dark.rawValue
    init() {
        let current = LBUIConnectionSettings().compactMapValues { $0 as? String }
        _values = State(initialValue: current); _baseline = State(initialValue: current)
    }
    private var dirty: Bool { values != baseline }
    private var locked: Bool { status.busy || app.connectionLocked || app.confirmation != nil }
    private func field(_ key: String) -> Binding<String> { Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("连接设置").font(.title2.bold()); Spacer(); if dirty { StatusBadge(text: "尚未保存") }; Button("完成") { close() }.disabled(status.busy) }.padding(22)
            Divider()
            Form {
                Section("站点") {
                    TextField("站点 HTTPS URL", text: field("site"))
                    TextField("证书域名（逗号分隔）", text: field("hosts"))
                    Text("这里只存储公开地址；仪表盘数据来自真实网络读取。").font(.caption).foregroundStyle(.secondary)
                }
                Section("GitHub · 文章与 .env") {
                    TextField("仓库 owner/repository", text: field("repo"))
                    SecureField("GitHub personal access token", text: field("githubToken")).accessibilityLabel("GitHub 令牌")
                    Text("令牌仅存储在应用 Keychain。需仓库 Contents 读写权限；不会写入 .env 或 HTML。").font(.caption).foregroundStyle(.secondary)
                }
                Section("终端留言") {
                    TextField("留言 API HTTPS URL", text: field("inboxURL"))
                    SecureField("站长 owner key", text: field("inboxToken")).accessibilityLabel("留言站长密钥")
                }
                Section("Memos · legacy API") {
                    TextField("Memos HTTPS 根地址", text: field("memosURL"))
                    SecureField("Memos access token", text: field("memosToken")).accessibilityLabel("Memos 令牌")
                    Text("本站公开说说镜像与 Memos 私有账户分离。请保存后显式验证账户；401 不会自动重试。").font(.caption).foregroundStyle(.secondary)
                }
                Section("文章工作区") {
                    HStack(spacing: 10) {
                        Image(systemName: values["customFolder"] == "1" ? "folder.fill" : "internaldrive").foregroundStyle(Color.blogPeach)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(values["folder"] ?? "Posts").lineLimit(1)
                            if let path = values["folderPath"], !path.isEmpty {
                                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        if values["customFolder"] == "1" {
                            Button("在 Finder 中显示") { if let path = values["folderPath"] { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                            Button("恢复默认") { resetFolder() }.disabled(locked)
                        }
                        Button("选择文件夹…") { chooseFolder() }.disabled(locked)
                    }
                    Text("默认使用 Application Support/longBlog/Posts。外部文件夹使用安全作用域书签。选择目录不会自动迁移、删除或提交文章；建议选择空目录或此前由 longBlog 同步的目录。").font(.caption).foregroundStyle(.secondary)
                }
                Section("外观") {
                    Picker("界面外观", selection: Binding(get: { appearance }, set: { appearance = $0; AppAppearance.apply(AppAppearance(rawValue: $0)) })) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented)
                }
                Section("AI 写作") {
                    Text("在文章编辑器点“AI 写作”，独立设置 HTTPS 接口、模型和 Keychain 密钥。生成结果只有在编辑快照未变化时才能应用。").font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(locked)
            OperationStatus(model: status)
            Divider()
            HStack {
                if locked { Text("当前操作未结束，连接修改暂时锁定。").font(.caption).foregroundStyle(.secondary) }
                else { Text("各服务独立连接；清空令牌可断开对应服务。").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("保存连接…") { save() }.buttonStyle(.borderedProminent).disabled(locked || !dirty)
            }.padding(18)
        }.frame(width: 720, height: 760).background(Color.blogBackground).tint(.blogPeach)
            .interactiveDismissDisabled(dirty || status.busy)
    }
    private func close() {
        if dirty { app.confirm("放弃尚未保存的连接修改？", "已保存的 Keychain 和服务配置不受影响。", button: "放弃并关闭", destructive: true) { dismiss() } }
        else { dismiss() }
    }
    /// Native open panel attached to the Settings sheet itself. SwiftUI's fileImporter
    /// inside a sheet, followed by an alert on the (sheet-covered) main window, queued the
    /// confirmation invisibly and left the whole UI locked — the reported folder "hang".
    private func chooseFolder() {
        guard app.dirtyNames.isEmpty else { status.errors["folder"] = "请先保存或放弃编辑中的\(app.dirtyNames.joined(separator: "、"))，再更换工作区。"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.prompt = "选择"; panel.message = "选择用于保存 longBlog 文章的本地文件夹"
        if let path = values["folderPath"], !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            // Let the panel finish closing before presenting the confirmation sheet.
            DispatchQueue.main.async { confirmFolder(url) }
        }
        if let host = AlertHost.window { panel.beginSheetModal(for: host, completionHandler: handle) } else { handle(panel.runModal()) }
    }
    private func confirmFolder(_ url: URL) {
        app.confirm("绑定文章工作区？", "\(url.path)\n\n所选文件夹将用作本地文章目录。不会自动迁移或上传文件；首次同步前请备份。", button: "绑定") {
            status.run("folder", "settings.folder", ["url": url], success: "文章工作区已绑定；可在文章板块手动同步。") { _ in folderChanged() }
        }
    }
    private func resetFolder() {
        guard app.dirtyNames.isEmpty else { status.errors["folder"] = "请先保存或放弃编辑中的\(app.dirtyNames.joined(separator: "、"))，再更换工作区。"; return }
        app.confirm("恢复默认文章目录？", "改回 Application Support/longBlog/Posts。外部文件夹中的文件保持不动。", button: "恢复默认") {
            status.run("folder", "settings.resetFolder", [:], success: "已恢复默认文章目录。") { _ in folderChanged() }
        }
    }
    private func folderChanged() {
        let current = LBUIConnectionSettings().compactMapValues { $0 as? String }
        for key in ["folder", "folderPath", "customFolder"] { values[key] = current[key]; baseline[key] = current[key] }
        // Drop every buffer that belonged to the previous folder before listing the new one.
        posts.resetBuffer(); posts.articles = []; posts.staged = []; posts.loaded = false; posts.clearMessages()
        posts.refresh()
    }
    private func save() {
        guard !locked else { return }
        guard app.dirtyNames.isEmpty else { status.errors["save"] = "请先保存或放弃编辑中的\(app.dirtyNames.joined(separator: "、"))，避免将旧账户的编辑写入新连接。"; return }
        let frozen = values
        app.confirm("保存这些服务连接？", "站点与仓库偏好写入本地配置，三个服务令牌分别存入 Keychain。不会自动发布内容或验证网络连接。", button: "保存连接") {
            status.run("save", "settings.save", frozen, success: "连接已保存。请到各板块显式刷新 / 验证；尚未声明任何服务在线。") { _ in
                baseline = frozen; app.resetConnectionViews()
            }
        }
    }
}
