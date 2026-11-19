import SwiftUI
import AppKit

@main
struct LongBlogApp: App {
    @NSApplicationDelegateAdaptor(LongBlogAppDelegate.self) private var delegate
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.dark.rawValue

    // The workspace window is owned by the AppDelegate (exactly one, never restored twice).
    // SwiftUI contributes the menu bar only.
    var body: some Scene {
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("连接设置…") { post("settings") }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("新建文章") { post("newArticle") }.keyboardShortcut("n")
                Button("写说说") { post("newMemo") }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("命令面板 / 快速跳转…") { post("commandPalette") }.keyboardShortcut("p")
            }
            CommandGroup(after: .saveItem) {
                Button("保存") { post("save") }.keyboardShortcut("s")
                Button("审阅待提交文章…") { post("review") }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("切换阅读 / 编辑") { post("editArticle") }.keyboardShortcut("e")
                Button("搜索") { post("search") }.keyboardShortcut("f")
                Button("专注写作模式") { post("toggleFocus") }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("格式") {
                ForEach(MarkdownAction.allCases) { action in
                    let button = Button(action.title) {
                        guard !AppModel.activeTextInputHasMarkedText else { return }
                        if let editor = MarkdownEditorController.focused {
                            editor.apply(action)
                        } else if action == .link {
                            post("commandPalette")
                        }
                    }
                    if let s = action.shortcut { button.keyboardShortcut(s.key, modifiers: s.modifiers) } else { button }
                    if [.image, .heading3, .taskList, .rule].contains(action) { Divider() }
                }
            }
            CommandGroup(before: .toolbar) {
                Button("命令面板…") { post("commandPalette") }
                Button("显示 / 隐藏侧边栏") { post("toggleSidebar") }.keyboardShortcut("\\", modifiers: .command)
                Divider()
                Button("仪表盘") { post("nav.dashboard") }.keyboardShortcut("1")
                Button("留言") { post("nav.inbox") }.keyboardShortcut("2")
                Button("文章") { post("nav.posts") }.keyboardShortcut("3")
                Button("说说") { post("nav.memos") }.keyboardShortcut("4")
                Button("站点配置") { post("nav.configuration") }.keyboardShortcut("5")
                Divider()
                Button("阅读文章") { post("layout.read") }.keyboardShortcut("r", modifiers: [.command, .option])
                Button("仅编辑") { post("layout.edit") }.keyboardShortcut("e", modifiers: [.command, .option])
                Button("编辑 + 实时预览") { post("layout.split") }.keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
                Picker("外观", selection: Binding(get: { appearance }, set: { appearance = $0; AppAppearance.apply(AppAppearance(rawValue: $0)) })) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Button("刷新") { post("refresh") }.keyboardShortcut("r")
                Divider()
            }
            CommandGroup(before: .windowList) {
                Button("longBlog 主窗口") { (NSApp.delegate as? LongBlogAppDelegate)?.showWorkspace() }.keyboardShortcut("0")
                Divider()
            }
        }
    }

    private func post(_ name: String) {
        NotificationCenter.default.post(name: Notification.Name("longBlog." + name), object: nil)
    }
}

final class LongBlogAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var workspaceWindow: NSWindow?
    private var suppressNextInboxFocusReload = false
    @MainActor let menuBar = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--smoke-test") && args.contains("--smoke-light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        } else if args.contains("--smoke-test") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else {
            AppAppearance.apply()
        }
        _ = AppModel.shared // installs the single menu-command router
        showWorkspace()
        menuBar.setupIfEnabled()

        if args.contains("--smoke-test"), let i = args.firstIndex(of: "--smoke-section"), args.indices.contains(i + 1) {
            let sections: [String: WorkspaceSection] = [
                "dashboard": .dashboard, "inbox": .inbox, "posts": .posts,
                "memos": .memos, "configuration": .configuration
            ]
            if let section = sections[args[i + 1]] { AppModel.shared.navigate(section) }
        }
        // Smoke-only: open an unsaved draft filled from a local Markdown file to render the editor.
        if args.contains("--smoke-test"), let i = args.firstIndex(of: "--smoke-markdown"), args.indices.contains(i + 1),
           let text = try? String(contentsOfFile: args[i + 1], encoding: .utf8) {
            AppModel.shared.newArticle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let lines = text.components(separatedBy: "\n")
                AppModel.shared.posts.draft.title = lines.first?.replacingOccurrences(of: "# ", with: "") ?? "示例"
                AppModel.shared.posts.draft.markdown = lines.dropFirst().joined(separator: "\n")
                AppModel.shared.posts.draft.tags = "控制理论, LaTeX, 非线性系统"
                AppModel.shared.posts.draft.summary = "汇总非线性系统分析的核心公式：状态空间描述、雅可比矩阵线性化与 Lyapunov 稳定性判据。"
                if args.contains("--smoke-read") { AppModel.shared.posts.editing = false }
                if args.contains("--smoke-focus") { AppModel.shared.focusMode = true }
            }
        }
        if args.contains("--smoke-test") && args.contains("--smoke-palette") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                AppModel.shared.showingCommandPalette = true
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if args.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                self.captureSmokeWindow()
            }
        }
    }

    @MainActor
    func showWorkspace(reloadInboxOnFocus: Bool = true) {
        if workspaceWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "longBlog"
            window.titleVisibility = .visible
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.tabbingMode = .disallowed
            window.minSize = NSSize(width: 1020, height: 660)
            window.backgroundColor = .lbBackground
            let host = NSHostingController(rootView: RootView())
            host.preferredContentSize = NSSize(width: 1280, height: 800)
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
            if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                window.setFrameAutosaveName("LongBlogWorkspace")
            }
            window.delegate = self
            workspaceWindow = window
        }
        if !reloadInboxOnFocus { suppressNextInboxFocusReload = true }
        workspaceWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if workspaceWindow?.isKeyWindow == true { suppressNextInboxFocusReload = false }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let app = AppModel.shared
        if app.connectionLocked {
            let alert = NSAlert(); alert.messageText = "操作尚未完成"; alert.informativeText = "请等待当前读取或写入结束，避免关闭时失去结果。"; alert.runModal(); return false
        }
        guard !app.dirtyNames.isEmpty else { return true }
        let alert = NSAlert(); alert.messageText = "仍有未保存的修改"; alert.informativeText = app.dirtyNames.joined(separator: "、") + "尚未保存。关闭后可从主窗口继续编辑，退出应用前仍需保存。"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "保留并关闭")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowDidBecomeKey(_ notification: Notification) {
        let reload = !suppressNextInboxFocusReload
        suppressNextInboxFocusReload = false
        AppModel.shared.inbox.workspaceFocusChanged(true, reload: reload)
    }

    func windowDidResignKey(_ notification: Notification) {
        AppModel.shared.inbox.workspaceFocusChanged(false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWorkspace() }
        return true
    }

    private func captureSmokeWindow() {
        let args = ProcessInfo.processInfo.arguments
        let screenshot: URL? = args.firstIndex(of: "--screenshot").flatMap { i in
            args.indices.contains(i + 1) ? URL(fileURLWithPath: args[i + 1]) : nil
        }
        // Hosted runners may have a smaller virtual display than a user's Mac.
        // Record actual window geometry; do not confuse display constraints with no window.
        let diagnostics: [String: Any] = [
            "windows": NSApp.windows.map { ["class": NSStringFromClass(type(of: $0)), "visible": $0.isVisible,
                "frame": NSStringFromRect($0.frame), "contentBounds": NSStringFromRect($0.contentView?.bounds ?? .zero)] as [String: Any] },
            "screens": NSScreen.screens.map { NSStringFromRect($0.frame) }
        ]
        if let destination = screenshot?.appendingPathExtension("json"),
           let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destination)
        }
        guard let view = NSApp.windows.first(where: {
            $0.isVisible && ($0.contentView?.bounds.width ?? 0) >= 400 && ($0.contentView?.bounds.height ?? 0) >= 300
        })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fputs("Smoke test failed: no laid-out application window.\n", stderr)
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let destination = screenshot, let png = rep.representation(using: .png, properties: [:]) {
            do { try png.write(to: destination) }
            catch { fputs("Smoke screenshot write failed.\n", stderr); exit(1) }
        }
        print("Smoke test: native macOS window created and rendered.")
        exit(0)
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        if model.connectionLocked {
            let alert = NSAlert()
            alert.messageText = "仍有操作进行中"
            alert.informativeText = "请等待保存或服务请求结束后再退出。结果不明的远端提交会由 Core 保留核验记录。"
            alert.addButton(withTitle: "返回应用")
            alert.runModal()
            return .terminateCancel
        }
        guard !model.dirtyNames.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出并放弃未保存内容？"
        alert.informativeText = "尚有未保存内容：" + model.dirtyNames.joined(separator: "、") + "。关闭窗口会保留内存编辑，但退出应用将丢弃这些未保存编辑。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "放弃并退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    // Keep the ordinary macOS application menu alive after the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
