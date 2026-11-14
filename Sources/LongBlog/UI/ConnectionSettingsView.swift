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
    @State private var importingFolder = false
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
                    HStack { Text(values["folder"] ?? "Posts"); Spacer(); Button("选择文件夹…") { chooseFolder() }.disabled(locked) }
                    Text("默认使用应用 Documents/Posts。外部文件夹使用安全作用域书签。选择目录不会自动迁移、删除或提交文章。").font(.caption).foregroundStyle(.secondary)
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
        }.frame(width: 720, height: 730).background(Color.blogBackground).preferredColorScheme(.dark).tint(.blogPeach)
            .interactiveDismissDisabled(dirty || status.busy)
            .fileImporter(isPresented: $importingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first {
                    app.confirm("绑定文章工作区？", "所选文件夹将用作本地文章目录。不会自动迁移或上传文件。", button: "绑定") {
                        status.run("folder", "settings.folder", ["url":url], success: "文章工作区已绑定；可在文章板块手动同步。") { _ in
                            let current = LBUIConnectionSettings(); values["folder"] = current["folder"] as? String ?? "Posts"; baseline["folder"] = values["folder"]; posts.refresh()
                        }
                    }
                }
                case .failure(let error): status.errors["folder"] = error.localizedDescription
                }
            }
    }
    private func close() {
        if dirty { app.confirm("放弃尚未保存的连接修改？", "已保存的 Keychain 和服务配置不受影响。", button: "放弃并关闭", destructive: true) { dismiss() } }
        else { dismiss() }
    }
    private func chooseFolder() {
        guard app.dirtyNames.isEmpty else { status.errors["folder"] = "请先保存或放弃编辑中的\(app.dirtyNames.joined(separator: "、"))，再更换工作区。"; return }
        importingFolder = true
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
