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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.captureSmokeWindow()
            }
        }
    }

    private func captureSmokeWindow() {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              view.bounds.width >= 1000, view.bounds.height >= 600,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fputs("Smoke test failed: no laid-out application window.\n", stderr)
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--screenshot"), args.indices.contains(i + 1),
           let png = rep.representation(using: .png, properties: [:]) {
            do { try png.write(to: URL(fileURLWithPath: args[i + 1])) }
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
