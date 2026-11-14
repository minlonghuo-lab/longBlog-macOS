import SwiftUI
import AppKit

@main
struct LongBlogApp: App {
    @NSApplicationDelegateAdaptor(LongBlogAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("longBlog") {
            RootView()
                .frame(minWidth: 1050, minHeight: 680)
                .tint(Color(red: 232 / 255, green: 180 / 255, blue: 154 / 255))
        }
        .defaultSize(width: 1200, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建文章") { post("newArticle") }.keyboardShortcut("n")
                Button("写说说") { post("newMemo") }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .saveItem) {
                Button("保存") { post("save") }.keyboardShortcut("s")
                Button("审阅待提交文章") { post("review") }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("编辑所选文章") { post("editArticle") }.keyboardShortcut("e")
                Button("搜索") { post("search") }.keyboardShortcut("f")
            }
            CommandGroup(after: .toolbar) {
                Button("刷新") { post("refresh") }.keyboardShortcut("r")
            }
        }
        Settings {
            ConnectionSettingsView()
                .frame(minWidth: 600, minHeight: 560)
                .tint(Color(red: 232 / 255, green: 180 / 255, blue: 154 / 255))
        }
    }

    private func post(_ name: String) {
        NotificationCenter.default.post(name: Notification.Name("longBlog." + name), object: nil)
    }
}

final class LongBlogAppDelegate: NSObject, NSApplicationDelegate {
    private var workspaceWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.showWorkspaceIfNeeded()
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--smoke-test"), let i = args.firstIndex(of: "--smoke-section"), args.indices.contains(i + 1) {
                let sections: [String: WorkspaceSection] = ["dashboard": .dashboard, "inbox": .inbox, "posts": .posts, "memos": .memos, "configuration": .configuration]
                if let section = sections[args[i + 1]] { AppModel.shared.navigate(section) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.captureSmokeWindow()
            }
        }
    }

    @MainActor
    private func showWorkspaceIfNeeded() {
        if let existing = NSApp.windows.first(where: {
            ($0.contentView?.bounds.width ?? 0) >= 1000 && ($0.contentView?.bounds.height ?? 0) >= 600
        }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // A handcrafted bundle can receive launch completion before SwiftUI opens
        // its first scene. Retain an explicit native host instead of starting windowless.
        if workspaceWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "longBlog"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 1050, height: 722)
            window.contentView = NSHostingView(rootView: RootView())
            window.center()
            workspaceWindow = window
        }
        workspaceWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWorkspaceIfNeeded() }
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
