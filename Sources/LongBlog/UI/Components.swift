import SwiftUI
import AppKit

// MARK: - Theme

extension NSColor {
    /// Appearance-aware colour; resolves at draw time for light / dark windows.
    static func lb(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
    static let lbBackground = lb(light: rgb(250, 246, 241), dark: rgb(39, 31, 27))
    static let lbSidebar = lb(light: rgb(240, 232, 223, 0.72), dark: rgb(46, 36, 31, 0.78))
    static let lbAccent = lb(light: rgb(184, 98, 60), dark: rgb(232, 180, 154))
    static let lbText = lb(light: rgb(47, 38, 32), dark: rgb(243, 233, 225))
    static let lbMuted = lb(light: rgb(122, 108, 96), dark: rgb(178, 163, 151))
    static let lbSurface = lb(light: rgb(255, 255, 255, 0.78), dark: rgb(255, 255, 255, 0.045))
    static let lbSurfaceHover = lb(light: rgb(255, 255, 255, 1), dark: rgb(255, 255, 255, 0.075))
    static let lbStroke = lb(light: rgb(60, 40, 25, 0.10), dark: rgb(255, 255, 255, 0.08))
    static let lbField = lb(light: rgb(60, 40, 25, 0.06), dark: rgb(0, 0, 0, 0.18))
    static let lbEditor = lb(light: rgb(255, 253, 250), dark: rgb(33, 26, 23))
    static let lbCode = lb(light: rgb(120, 86, 60), dark: rgb(214, 190, 160))
    static let lbCodeBackground = lb(light: rgb(120, 86, 60, 0.08), dark: rgb(255, 255, 255, 0.06))
    static let lbLink = lb(light: rgb(48, 110, 160), dark: rgb(130, 185, 230))
    static let lbMath = lb(light: rgb(128, 72, 150), dark: rgb(205, 160, 230))
}

extension Color {
    static let blogBackground = Color(nsColor: .lbBackground)
    static let blogSidebar = Color(nsColor: .lbSidebar)
    static let blogPeach = Color(nsColor: .lbAccent)
    static let blogText = Color(nsColor: .lbText)
    static let blogMuted = Color(nsColor: .lbMuted)
    static let blogSurface = Color(nsColor: .lbSurface)
    static let blogSurfaceHover = Color(nsColor: .lbSurfaceHover)
    static let blogStroke = Color(nsColor: .lbStroke)
    static let blogField = Color(nsColor: .lbField)
    static let blogEditor = Color(nsColor: .lbEditor)
    static let blogGreen = Color(nsColor: .lb(light: .rgb(46, 139, 87), dark: .rgb(134, 205, 150)))
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    static let storageKey = "lb.appearance"
    static var current: AppAppearance { AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .dark }
    /// NSApp-level appearance also themes alerts, sheets, open panels and the Settings window.
    static func apply(_ value: AppAppearance? = nil) {
        let value = value ?? current
        UserDefaults.standard.set(value.rawValue, forKey: storageKey)
        switch value {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Building blocks

struct Panel<Content: View>: View {
    var title: String?
    var symbol: String?
    let content: Content
    init(_ title: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.symbol = symbol; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = title {
                HStack(spacing: 8) {
                    if let symbol = symbol { Image(systemName: symbol).foregroundStyle(Color.blogPeach) }
                    Text(title).font(.headline)
                }
            }
            content
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blogSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.blogStroke))
    }
}

struct StatusBadge: View {
    let text: String
    var color: Color = .blogPeach
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let symbol = symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.medium)).foregroundStyle(color).lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 3).background(color.opacity(0.14), in: Capsule())
    }
}

/// List row card with hover feedback; used by every master list.
struct CardButtonStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View { CardBody(configuration: configuration, selected: selected) }
    private struct CardBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(selected ? Color.blogPeach.opacity(0.16) : (hovering ? Color.blogSurfaceHover : Color.blogSurface),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Color.blogPeach.opacity(0.55) : Color.blogStroke))
                .scaleEffect(configuration.isPressed ? 0.99 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focused).onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = ""; onSubmit() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.blogField, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.blogStroke))
    }
}

struct EmptyWorkspace: View {
    let symbol: String, title: String, detail: String
    var settings = false
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Color.blogPeach)
                .frame(width: 68, height: 68).background(Color.blogPeach.opacity(0.12), in: Circle())
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            if settings { Button("打开连接设置") { AppModel.shared.showingSettings = true }.accessibilityLabel("打开连接设置") }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Floating, non-layout-shifting status. Errors stay until dismissed; successes fade (see ServiceModel).
struct OperationStatus: View {
    @ObservedObject var model: ServiceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.errors.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(model.errors[key] ?? "").textSelection(.enabled).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { model.errors[key] = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭错误提示")
                }.toastBackground(.orange)
            }
            ForEach(model.successes.keys.sorted(), id: \.self) { key in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.blogGreen)
                    Text(model.successes[key] ?? "").font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }.toastBackground(.green)
            }
            if model.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在处理：\(model.running.sorted().map(ServiceModel.label).joined(separator: "、"))").font(.caption).foregroundStyle(.secondary) }
                    .toastBackground(.gray)
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 14).padding(.vertical, model.busy || !model.errors.isEmpty || !model.successes.isEmpty ? 10 : 0)
        .animation(.easeOut(duration: 0.18), value: model.successes.count + model.errors.count + model.running.count)
    }
}
private extension View {
    func toastBackground(_ tint: Color) -> some View {
        padding(.horizontal, 12).padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Drag the window from custom title areas (the window uses a transparent full-size titlebar).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = material; view.blendingMode = .behindWindow; view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { nsView.material = material }
}

// MARK: - Alerts

enum AlertHost {
    /// The deepest presented sheet of the active window. Starting a sheet on a window that
    /// already shows one (e.g. the main window under the Settings sheet) QUEUES the alert
    /// invisibly until that sheet closes, which looked like a frozen app.
    static var window: NSWindow? {
        var window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
        while let sheet = window?.attachedSheet { window = sheet }
        if let w = window, !w.isVisible { return nil }
        return window
    }
    static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
}

/// Blocks window close / application termination when retained editor buffers are dirty.
struct WindowCloseGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { let view = GuardView(); return view }
    func updateNSView(_ view: NSView, context: Context) {}
    final class GuardView: NSView, NSWindowDelegate {
        weak var previous: NSWindowDelegate?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window = window, window.delegate !== self { previous = window.delegate; window.delegate = self }
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let app = AppModel.shared
            if app.connectionLocked {
                let alert = NSAlert(); alert.messageText = "操作尚未完成"; alert.informativeText = "请等待当前读取或写入结束，避免关闭时失去结果。"; alert.runModal(); return false
            }
            guard !app.dirtyNames.isEmpty else { return previous?.windowShouldClose?(sender) ?? true }
            let alert = NSAlert(); alert.messageText = "仍有未保存的修改"; alert.informativeText = app.dirtyNames.joined(separator: "、") + "尚未保存。关闭窗口将丢失编辑缓冲区。"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃并关闭")
            return alert.runModal() == .alertSecondButtonReturn
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || (previous?.responds(to: selector) ?? false) }
        override func forwardingTarget(for selector: Selector!) -> Any? { previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector) }
    }
}
