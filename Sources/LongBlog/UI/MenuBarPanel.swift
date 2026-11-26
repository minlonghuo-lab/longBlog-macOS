import SwiftUI
import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    static let storageKey = "lb.menubar.enabled"
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func setupIfEnabled() {
        let args = ProcessInfo.processInfo.arguments
        guard !args.contains("--smoke-test") else { return }
        let enabled = UserDefaults.standard.object(forKey: Self.storageKey) as? Bool ?? true
        setEnabled(enabled)

        let app = AppModel.shared
        Publishers.CombineLatest(app.inbox.$unread, app.posts.$staged)
            .receive(on: RunLoop.main)
            .sink { [weak self] unread, staged in
                self?.updateBadge(unread: unread, staged: staged.count)
            }
            .store(in: &cancellables)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.storageKey)
        if enabled {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.target = self
                button.action = #selector(togglePopover(_:))
                button.imagePosition = .imageLeading
                button.toolTip = "longBlog 快捷面板"
            }
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 364, height: 340)
            popover.contentViewController = NSHostingController(rootView: MenuBarPanelView(closePopover: { [weak self] in
                self?.popover.close()
            }))
            statusItem = item
            updateBadge(unread: AppModel.shared.inbox.unread, staged: AppModel.shared.posts.staged.count)
        } else {
            popover.performClose(nil)
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    private func updateBadge(unread: Int, staged: Int) {
        guard let button = statusItem?.button else { return }
        let symbol = unread > 0 ? "bubble.left.and.exclamationmark.bubble.right.fill" : "terminal"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "longBlog")
        img?.isTemplate = true
        button.image = img
        if unread > 0 {
            button.title = " \(unread)"
        } else if staged > 0 {
            button.title = " ·"
        } else {
            button.title = ""
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if AppModel.shared.dashboard.data.isEmpty && !AppModel.shared.dashboard.busy {
                AppModel.shared.dashboard.openLocal()
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

struct MenuBarPanelView: View {
    var closePopover: () -> Void = {}
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var dashboard = AppModel.shared.dashboard
    @ObservedObject private var inbox = AppModel.shared.inbox
    @ObservedObject private var posts = AppModel.shared.posts

    private var deployShortText: (String, Color) {
        let state = dashboard.data["deployState"] as? String ?? ""
        if state.contains("已是最新") { return ("站点运行中", .blogGreen) }
        if state.contains("等待") { return ("部署构建中", .blogAmber) }
        if !(dashboard.data["build"] as? [String: Any] ?? [:]).isEmpty { return ("站点在线", .blogGreen) }
        return ("尚未核验", .blogMuted)
    }

    private var buildSummary: (String, Color) {
        let build = dashboard.data["build"] as? [String: Any] ?? [:]
        guard let builtAt = build["builtAt"] as? String, !builtAt.isEmpty else {
            return ("尚未读取", .blogMuted)
        }
        let state = dashboard.data["deployState"] as? String ?? ""
        let latest = state.contains("已是最新")
        return ("\(formattedISOBuildTime(builtAt))\(latest ? " · 最新" : "")", latest ? .blogGreen : .blogSecondary)
    }

    private var minCertSummary: (String, Color) {
        let certs = dashboard.data["certs"] as? [String: Any] ?? [:]
        let dates = certs.values.compactMap { $0 as? Date }
        guard let earliest = dates.min() else {
            return (certs.isEmpty ? "尚未读取" : "待检查", .blogMuted)
        }
        let days = Int(earliest.timeIntervalSinceNow / 86400)
        return ("剩 \(days) 天", days > 14 ? .blogGreen : .blogAmber)
    }

    private func openWorkspace(reloadInboxOnFocus: Bool = true, then action: (() -> Void)? = nil) {
        closePopover()
        (NSApp.delegate as? LongBlogAppDelegate)?.showWorkspace(reloadInboxOnFocus: reloadInboxOnFocus)
        guard let action = action else { return }
        DispatchQueue.main.async {
            if app.showingCommandPalette { app.showingCommandPalette = false }
            action()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Text("longBlog").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(deployShortText.1).frame(width: 6.5, height: 6.5)
                    Text(deployShortText.0).font(.system(size: 12, weight: .medium)).foregroundStyle(deployShortText.1)
                }
                Spacer()
                if let refreshed = dashboard.refreshed {
                    Text(relativeTimeLabel(refreshed.timeIntervalSince1970, milliseconds: false))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.blogMuted)
                }
                Button {
                    dashboard.refresh()
                    if inbox.loaded { inbox.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .pointingHandCursor(!dashboard.busy)
                .foregroundStyle(Color.blogMuted)
                .disabled(dashboard.busy)
                .accessibilityLabel("刷新站点状态")
                .help("刷新状态")
            }

            // Inbox preview card (Scheme 4)
            if let unreadRow = inbox.sessions.first(where: { $0.flag("unread") }) {
                let last = unreadRow.data["last"] as? [String: Any] ?? [:]
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("终端留言 · \(inbox.unread) 个未读")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.blogPeachSoft)
                        Spacer()
                        Text(relativeTimeLabel((last["createdAt"] as? NSNumber)?.doubleValue ?? unreadRow.number("createdAt")))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.blogMuted)
                    }
                    Text("访客 \(unreadRow.text("title"))：\(last["text"] as? String ?? "新消息")")
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                        .foregroundStyle(Color.blogText)
                    HStack {
                        Spacer()
                        Button("前往回复 ↩") {
                            openWorkspace(reloadInboxOnFocus: false) {
                                app.openInboxSession(unreadRow.id)
                            }
                        }
                        .buttonStyle(BlogPrimaryButtonStyle(compact: true))
                    }
                }
                .padding(12)
                .background(Color.blogTintPeach, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.blogPeach.opacity(0.32)))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left").foregroundStyle(Color.blogMuted)
                    Text(inbox.loaded ? "终端留言 · 当前无未读消息" : "终端留言 · 点击前往读取")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.blogSecondary)
                    Spacer()
                    Button("查看") {
                        openWorkspace { app.navigate(.inbox) }
                    }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                }
                .padding(11)
                .background(Color.blogSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.blogStroke))
            }

            // 2-column mini status cards
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("线上构建").font(.system(size: 11)).foregroundStyle(Color.blogMuted)
                    Text(buildSummary.0)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(buildSummary.1)
                        .lineLimit(1)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blogSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.blogStroke))

                VStack(alignment: .leading, spacing: 4) {
                    Text("HTTPS 证书").font(.system(size: 11)).foregroundStyle(Color.blogMuted)
                    Text(minCertSummary.0)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(minCertSummary.1)
                        .lineLimit(1)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blogSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.blogStroke))
            }

            // Staged articles bar
            HStack(spacing: 8) {
                Text("待提交文章")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.blogSecondary)
                Text("\(posts.staged.count) 篇")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(posts.staged.isEmpty ? Color.blogMuted : Color.blogPeachSoft)
                Spacer()
                if !posts.staged.isEmpty {
                    Button("审阅提交 ⌘⇧P") {
                        openWorkspace { app.review() }
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.blogPeach)
                } else {
                    Text("工作区共 \(posts.articles.count) 篇")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Color.blogMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.blogSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.blogStroke))

            // Primary actions
            BlogGlassGroup(spacing: 8) {
                Button {
                    openWorkspace()
                } label: {
                    Text("打开 longBlog").frame(maxWidth: .infinity)
                }
                .buttonStyle(BlogPrimaryButtonStyle())

                Button {
                    openWorkspace { app.newArticle() }
                } label: {
                    Image(systemName: "plus").frame(width: 14, height: 16)
                }
                .buttonStyle(BlogSecondaryButtonStyle())
                .accessibilityLabel("新建文章")
                .help("新建文章 ⌘N")

                Button {
                    openWorkspace { app.newMemo() }
                } label: {
                    Image(systemName: "square.and.pencil").frame(width: 14, height: 16)
                }
                .buttonStyle(BlogSecondaryButtonStyle())
                .accessibilityLabel("写说说")
                .help("写说说 ⌘⇧N")
            }
        }
        .padding(16)
        .frame(width: 364)
        .foregroundStyle(Color.blogText)
        .tint(Color.blogPeach)
        .modifier(MenuBarBackdropModifier())
    }
}

private struct MenuBarBackdropModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content
                .background(Color.blogBackground)
        }
    }
}
