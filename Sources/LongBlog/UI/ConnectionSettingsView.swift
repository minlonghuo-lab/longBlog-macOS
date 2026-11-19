import SwiftUI
import UniformTypeIdentifiers

struct ConnectionSettingsView: View {
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var posts = AppModel.shared.posts
    @StateObject private var status = ServiceModel()
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var baseline: [String: String] = [:]
    @State private var loadedSettings = false
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.dark.rawValue
    @AppStorage(MenuBarController.storageKey) private var menuBarEnabled = true

    private var dirty: Bool { loadedSettings && values != baseline }
    private var locked: Bool { !loadedSettings || status.busy || app.connectionLocked || app.confirmation != nil }
    private func field(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("服务与连接设置").font(.system(size: 19, weight: .bold))
                    Text("公开地址写入偏好设置；访问令牌仅保存在 macOS Keychain")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.blogMuted)
                }
                Spacer()
                if dirty { StatusBadge(text: "尚未保存", color: .blogAmber, dot: true, pill: true) }
                Button("完成") { close() }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                    .disabled(status.busy)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            HairlineDivider()

            Form {
                Section("站点与证书监控") {
                    TextField("站点 HTTPS URL", text: field("site"))
                    TextField("证书监控域名（英文逗号分隔）", text: field("hosts"))
                    Text("仪表盘将直接探测公开站点构建标记与各域名 TLS 证书剩余有效期。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("GitHub · 文章与 .env") {
                    TextField("仓库 owner/repository", text: field("repo"))
                    SecureField("GitHub Personal Access Token", text: field("githubToken"))
                        .accessibilityLabel("GitHub 令牌")
                    Text("需仓库 Contents 读写权限。令牌仅存入应用 Keychain，绝不写入 .env 或预览页面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("终端留言") {
                    TextField("留言 API HTTPS URL", text: field("inboxURL"))
                    SecureField("站长 owner key", text: field("inboxToken"))
                        .accessibilityLabel("留言站长密钥")
                }
                Section("Memos · legacy API") {
                    TextField("Memos HTTPS 根地址", text: field("memosURL"))
                    SecureField("Memos Access Token", text: field("memosToken"))
                        .accessibilityLabel("Memos 令牌")
                    Text("公开说说镜像与私有 Memos 账户相互独立；保存后可在说说页验证账户。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("本地文章工作区") {
                    HStack(spacing: 10) {
                        Image(systemName: values["customFolder"] == "1" ? "folder.fill" : "internaldrive")
                            .foregroundStyle(Color.blogPeach)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(values["folder"] ?? "Posts").lineLimit(1)
                            if let path = values["folderPath"], !path.isEmpty {
                                Text(path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                        if values["customFolder"] == "1" {
                            Button("在 Finder 中显示") {
                                if let path = values["folderPath"] {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }
                            }
                            Button("恢复默认") { resetFolder() }.disabled(locked)
                        }
                        Button("选择文件夹…") { chooseFolder() }.disabled(locked)
                    }
                    Text("默认使用 Application Support/longBlog/Posts。外部文件夹采用安全作用域书签绑定，不会自动迁移或删除原有文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("外观与桌面体验") {
                    HStack {
                        Text("界面外观")
                        Spacer()
                        BlogSegmentedControl(
                            title: "界面外观",
                            options: AppAppearance.allCases.map { SegmentedOption(value: $0.rawValue, label: $0.title, symbol: $0.symbol) },
                            selection: Binding(
                                get: { appearance },
                                set: { appearance = $0; AppAppearance.apply(AppAppearance(rawValue: $0)) }
                            ),
                            compact: true
                        )
                    }

                    Toggle("在系统菜单栏显示常驻快捷面板", isOn: Binding(
                        get: { menuBarEnabled },
                        set: { enabled in
                            menuBarEnabled = enabled
                            (NSApp.delegate as? LongBlogAppDelegate)?.menuBar.setEnabled(enabled)
                        }
                    ))
                }
                Section("AI 写作辅助") {
                    Text("在文章工作台点击“AI”可独立配置兼容 OpenAI 的 HTTPS 接口、模型名称与 Keychain 密钥。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(locked)

            OperationStatus(model: status)

            HairlineDivider()

            HStack {
                if !loadedSettings {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在读取本地连接设置…").font(.system(size: 12)).foregroundStyle(Color.blogMuted)
                    }
                } else if locked {
                    Text("当前有任务执行中，连接修改暂时锁定。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.blogMuted)
                } else {
                    Text("各服务相互独立；清空对应令牌即可断开该服务。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.blogMuted)
                }
                Spacer()
                Button("保存连接…") { save() }
                    .buttonStyle(BlogPrimaryButtonStyle())
                    .disabled(locked || !dirty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 720, height: 760)
        .foregroundStyle(Color.blogText)
        .background(Color.blogBackground)
        .tint(Color.blogPeach)
        .interactiveDismissDisabled(dirty || status.busy)
        .task {
            guard !loadedSettings else { return }
            status.run("settings", "settings.load") { result in
                let loaded = result.compactMapValues { $0 as? String }
                self.values = loaded
                self.baseline = loaded
                self.loadedSettings = true
            }
        }
    }

    private func close() {
        if dirty {
            app.confirm("放弃尚未保存的连接修改？", "已保存的 Keychain 和服务配置不受影响。", button: "放弃并关闭", destructive: true) { dismiss() }
        } else {
            dismiss()
        }
    }

    private func chooseFolder() {
        guard app.dirtyNames.isEmpty else {
            status.errors["folder"] = "请先保存或放弃编辑中的\(app.dirtyNames.joined(separator: "、"))，再更换工作区。"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.prompt = "选择"; panel.message = "选择用于保存 longBlog 文章的本地文件夹"
        if let path = values["folderPath"], !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
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
        guard app.dirtyNames.isEmpty else {
            status.errors["folder"] = "请先保存或放弃编辑中的\(app.dirtyNames.joined(separator: "、"))，再更换工作区。"
            return
        }
        app.confirm("恢复默认文章目录？", "改回 Application Support/longBlog/Posts。外部文件夹中的文件保持不动。", button: "恢复默认") {
            status.run("folder", "settings.resetFolder", [:], success: "已恢复默认文章目录。") { _ in folderChanged() }
        }
    }

    private func folderChanged() {
        status.run("settings", "settings.load") { result in
            let current = result.compactMapValues { $0 as? String }
            for key in ["folder", "folderPath", "customFolder"] {
                values[key] = current[key]
                baseline[key] = current[key]
            }
            posts.checkID = UUID(); posts.nextCheck = .distantPast
            posts.resetBuffer(); posts.articles = []; posts.staged = []; posts.loaded = false; posts.clearMessages()
            posts.refresh(autoSelectFirst: true)
        }
    }

    private func save() {
        guard !locked else { return }
        guard app.dirtyNames.isEmpty else {
            status.errors["save"] = "请先保存或放弃编辑中的\(app.dirtyNames.joined(separator: "、"))，避免将旧账户的编辑写入新连接。"
            return
        }
        let frozen = values
        app.confirm("保存这些服务连接？", "令牌保存在此 Mac 的钥匙串中。保存后会在后台读取站点状态。", button: "保存连接") {
            status.run("save", "settings.save", frozen, success: "连接已保存，正在更新站点状态。") { _ in
                baseline = frozen
                app.resetConnectionViews()
                app.refreshIfNeeded()
            }
        }
    }
}
