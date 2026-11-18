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
    static let lbBackground = lb(light: rgb(250, 245, 238), dark: rgb(39, 31, 27))
    static let lbSidebar = lb(light: rgb(239, 230, 220, 0.78), dark: rgb(46, 36, 31, 0.84))
    static let lbAccent = lb(light: rgb(184, 98, 60), dark: rgb(232, 180, 154))
    static let lbAccentInk = lb(light: rgb(255, 251, 247), dark: rgb(51, 36, 28))
    static let lbAccentSoft = lb(light: rgb(156, 76, 42), dark: rgb(255, 217, 194))
    static let lbText = lb(light: rgb(44, 35, 29), dark: rgb(243, 233, 225))
    static let lbSecondary = lb(light: rgb(96, 82, 71), dark: rgb(217, 204, 194))
    static let lbMuted = lb(light: rgb(132, 117, 105), dark: rgb(168, 154, 143))
    static let lbSurface = lb(light: rgb(255, 255, 255, 0.80), dark: rgb(255, 255, 255, 0.046))
    static let lbSurfaceHover = lb(light: rgb(255, 255, 255, 0.96), dark: rgb(255, 255, 255, 0.08))
    static let lbStroke = lb(light: rgb(65, 44, 28, 0.10), dark: rgb(255, 255, 255, 0.08))
    static let lbStrokeStrong = lb(light: rgb(65, 44, 28, 0.20), dark: rgb(255, 255, 255, 0.18))
    static let lbDivider = lb(light: rgb(65, 44, 28, 0.09), dark: rgb(255, 255, 255, 0.07))
    static let lbField = lb(light: rgb(60, 40, 25, 0.055), dark: rgb(0, 0, 0, 0.24))
    static let lbSlot = lb(light: rgb(60, 40, 25, 0.075), dark: rgb(255, 255, 255, 0.075))
    static let lbSlotActive = lb(light: rgb(255, 255, 255, 0.94), dark: rgb(255, 255, 255, 0.16))
    static let lbEditor = lb(light: rgb(255, 253, 249), dark: rgb(32, 25, 21))
    static let lbCode = lb(light: rgb(120, 86, 60), dark: rgb(218, 194, 165))
    static let lbCodeBackground = lb(light: rgb(120, 86, 60, 0.08), dark: rgb(255, 255, 255, 0.06))
    static let lbLink = lb(light: rgb(46, 108, 158), dark: rgb(134, 190, 234))
    static let lbMath = lb(light: rgb(126, 70, 148), dark: rgb(166, 212, 214))
}

extension Color {
    static let blogBackground = Color(nsColor: .lbBackground)
    static let blogSidebar = Color(nsColor: .lbSidebar)
    static let blogPeach = Color(nsColor: .lbAccent)
    static let blogPeachInk = Color(nsColor: .lbAccentInk)
    static let blogPeachSoft = Color(nsColor: .lbAccentSoft)
    static let blogText = Color(nsColor: .lbText)
    static let blogSecondary = Color(nsColor: .lbSecondary)
    static let blogMuted = Color(nsColor: .lbMuted)
    static let blogSurface = Color(nsColor: .lbSurface)
    static let blogSurfaceHover = Color(nsColor: .lbSurfaceHover)
    static let blogStroke = Color(nsColor: .lbStroke)
    static let blogStrokeStrong = Color(nsColor: .lbStrokeStrong)
    static let blogDivider = Color(nsColor: .lbDivider)
    static let blogField = Color(nsColor: .lbField)
    static let blogSlot = Color(nsColor: .lbSlot)
    static let blogSlotActive = Color(nsColor: .lbSlotActive)
    static let blogEditor = Color(nsColor: .lbEditor)
    static let blogGreen = Color(nsColor: .lb(light: .rgb(38, 132, 82), dark: .rgb(127, 214, 154)))
    static let blogTeal = Color(nsColor: .lb(light: .rgb(44, 126, 132), dark: .rgb(130, 204, 204)))
    static let blogAmber = Color(nsColor: .lb(light: .rgb(184, 114, 28), dark: .rgb(240, 186, 108)))

    // Design-spec semantic metric tints (Scheme 1 Tahoe warm glass)
    static let blogTintPeach = Color(nsColor: .lb(light: .rgb(184, 98, 60, 0.10), dark: .rgb(232, 180, 154, 0.15)))
    static let blogTintTeal = Color(nsColor: .lb(light: .rgb(54, 132, 136, 0.10), dark: .rgb(120, 190, 190, 0.135)))
    static let blogTintPurple = Color(nsColor: .lb(light: .rgb(104, 92, 175, 0.10), dark: .rgb(150, 140, 210, 0.135)))
    static let blogTintRose = Color(nsColor: .lb(light: .rgb(185, 78, 92, 0.10), dark: .rgb(220, 120, 130, 0.135)))
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    var symbol: String { switch self { case .system: return "circle.lefthalf.filled"; case .light: return "sun.max.fill"; case .dark: return "moon.stars.fill" } }
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

// MARK: - Ambient Canvas & Dividers

struct AmbientCanvasBackground: View {
    var body: some View {
        ZStack {
            Color.blogBackground
            RadialGradient(
                colors: [Color.blogPeach.opacity(0.058), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 560
            )
            RadialGradient(
                colors: [Color.blogTeal.opacity(0.038), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 520
            )
        }
        .allowsHitTesting(false)
    }
}

struct HairlineDivider: View {
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(Color.blogDivider)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

// MARK: - Buttons & Segmented Controls

/// Bespoke peach primary button matching the chosen Tahoe warm glass design (`#e8b49a` + `#33241c`).
struct BlogPrimaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, compact: compact)
    }
    private struct PrimaryBody: View {
        let configuration: ButtonStyle.Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(Color.blogPeachInk)
                .padding(.horizontal, compact ? 11 : 14)
                .padding(.vertical, compact ? 5 : 7)
                .background {
                    RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
                        .fill(Color.blogPeach)
                        .brightness(hovering && isEnabled ? 0.05 : 0)
                        .shadow(color: Color.blogPeach.opacity(hovering && isEnabled ? 0.24 : 0.10), radius: hovering ? 8 : 3, y: 2)
                }
                .opacity(isEnabled ? 1 : 0.42)
                .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// Bespoke secondary outline button matching the design spec (`1px` warm stroke + glass hover).
struct BlogSecondaryButtonStyle: ButtonStyle {
    var compact = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, compact: compact, destructive: destructive)
    }
    private struct SecondaryBody: View {
        let configuration: ButtonStyle.Configuration
        let compact: Bool
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            let fg: Color = destructive ? .red : .blogText
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(fg.opacity(hovering ? 1 : 0.9))
                .padding(.horizontal, compact ? 10 : 13)
                .padding(.vertical, compact ? 5 : 7)
                .background(
                    hovering && isEnabled ? (destructive ? Color.red.opacity(0.12) : Color.blogSurfaceHover) : Color.blogSurface,
                    in: RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
                        .strokeBorder(destructive ? Color.red.opacity(0.35) : (hovering && isEnabled ? Color.blogStrokeStrong : Color.blogStroke))
                )
                .opacity(isEnabled ? 1 : 0.42)
                .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct ShortcutCap: View {
    let text: String
    var onPrimary = false
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(onPrimary ? Color.blogPeachInk.opacity(0.72) : Color.blogMuted)
    }
}

struct SegmentedOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var symbol: String? = nil
    var count: Int? = nil
    var id: Value { value }
}

/// Design-spec dark inset slot segmented control with smooth pill selection.
struct BlogSegmentedControl<Value: Hashable>: View {
    let options: [SegmentedOption<Value>]
    @Binding var selection: Value
    var compact = false
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { opt in
                let active = selection == opt.value
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        selection = opt.value
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = opt.symbol {
                            Image(systemName: symbol).font(.system(size: compact ? 11 : 12, weight: active ? .semibold : .regular))
                        }
                        Text(opt.label)
                            .font(.system(size: compact ? 11.5 : 12.5, weight: active ? .semibold : .medium))
                        if let count = opt.count {
                            Text("\(count)")
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(active ? Color.blogPeach : Color.blogMuted)
                        }
                    }
                    .foregroundStyle(active ? Color.blogText : Color.blogMuted)
                    .padding(.horizontal, compact ? 9 : 11)
                    .padding(.vertical, compact ? 4 : 5)
                    .contentShape(Rectangle())
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                                .fill(Color.blogSlotActive)
                                .overlay(RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous).strokeBorder(Color.blogStroke))
                                .matchedGeometryEffect(id: "seg-pill", in: namespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.blogSlot, in: RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous).strokeBorder(Color.blogStroke))
    }
}

// MARK: - Building blocks

struct Panel<Content: View>: View {
    var title: String?
    var symbol: String?
    var tint: Color? = nil
    let content: Content
    init(_ title: String? = nil, symbol: String? = nil, tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.tint = tint; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = title {
                HStack(spacing: 7) {
                    if let symbol = symbol {
                        Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.blogPeach)
                    }
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Color.blogMuted)
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint ?? Color.blogSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.blogStroke))
    }
}

struct StatusBadge: View {
    let text: String
    var color: Color = .blogPeach
    var symbol: String? = nil
    var dot = false
    var pill = false
    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle().fill(color).frame(width: 6, height: 6)
            } else if let symbol = symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(color)
        .lineLimit(1)
        .padding(.horizontal, pill ? 10 : 8)
        .padding(.vertical, pill ? 4 : 2.5)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: pill ? 999 : 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: pill ? 999 : 6, style: .continuous)
                .strokeBorder(color.opacity(pill ? 0.28 : 0.16))
        )
    }
}

/// List row card with hover feedback; used by every master list.
struct CardButtonStyle: ButtonStyle {
    var selected: Bool
    var highlighted = false
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, selected: selected, highlighted: highlighted)
    }
    private struct CardBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let highlighted: Bool
        @State private var hovering = false
        var body: some View {
            let fill: Color = selected
                ? Color.blogPeach.opacity(0.18)
                : (highlighted ? Color.blogPeach.opacity(0.09) : (hovering ? Color.blogSurfaceHover : Color.blogSurface))
            let stroke: Color = selected
                ? Color.blogPeach.opacity(0.46)
                : (highlighted ? Color.blogPeach.opacity(0.28) : (hovering ? Color.blogStrokeStrong : Color.blogStroke))
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(stroke))
                .scaleEffect(configuration.isPressed ? 0.992 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: selected)
        }
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var shortcutHint: String? = "⌘F"
    var onSubmit: () -> Void = {}
    var body: some View {
        let isFocused = focused.wrappedValue
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isFocused ? Color.blogPeach : Color.blogMuted)
            TextField(prompt, text: $text)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = ""; onSubmit() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.blogMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            } else if !isFocused, let hint = shortcutHint {
                Text(hint)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.blogMuted.opacity(0.75))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6.5)
        .background(Color.blogField, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isFocused ? Color.blogPeach.opacity(0.6) : Color.blogStroke)
        )
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}

struct EmptyWorkspace: View {
    let symbol: String, title: String, detail: String
    var settings = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.blogPeach.opacity(0.06)).frame(width: 84, height: 84)
                Circle().fill(Color.blogPeach.opacity(0.12)).frame(width: 60, height: 60)
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.blogPeach)
            }
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Color.blogMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            HStack(spacing: 10) {
                if let actionTitle = actionTitle, let action = action {
                    Button(actionTitle, action: action).buttonStyle(BlogPrimaryButtonStyle())
                }
                if settings {
                    Button("连接设置  ⌘,") { AppModel.shared.showingSettings = true }
                        .buttonStyle(BlogSecondaryButtonStyle())
                        .accessibilityLabel("打开连接设置")
                }
            }
            .padding(.top, 2)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Floating, non-layout-shifting status. Errors stay until dismissed; successes fade (see ServiceModel).
struct OperationStatus: View {
    @ObservedObject var model: ServiceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(model.errors.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.blogAmber)
                    Text(model.errors[key] ?? "")
                        .textSelection(.enabled)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { model.errors[key] = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.blogMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭错误提示")
                }
                .toastBackground(.blogAmber)
            }
            ForEach(model.successes.keys.sorted(), id: \.self) { key in
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.blogGreen)
                    Text(model.successes[key] ?? "")
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }
                .toastBackground(.blogGreen)
            }
            if model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在处理：\(model.running.sorted().map(ServiceModel.label).joined(separator: "、"))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.blogSecondary)
                }
                .toastBackground(.blogPeach)
            }
        }
        .frame(maxWidth: 540)
        .padding(.horizontal, 14)
        .padding(.vertical, model.busy || !model.errors.isEmpty || !model.successes.isEmpty ? 10 : 0)
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: model.successes.count + model.errors.count + model.running.count)
    }
}

private extension View {
    func toastBackground(_ tint: Color) -> some View {
        padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.35)))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
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
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Alerts

enum AlertHost {
    /// The deepest presented sheet of the active workspace window. Never attach confirmation
    /// sheets to a transient status-bar NSPopover window that may be fading out.
    static var window: NSWindow? {
        let workspace = (NSApp.delegate as? LongBlogAppDelegate)?.workspaceWindow
        let candidates: [NSWindow?] = [NSApp.keyWindow, NSApp.mainWindow, workspace]
        var window = candidates.compactMap { $0 }.first { win in
            win.isVisible && win.level == .normal && !NSStringFromClass(type(of: win)).contains("Popover")
        } ?? workspace
        while let sheet = window?.attachedSheet { window = sheet }
        if let w = window, !w.isVisible { return nil }
        return window
    }
    static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
}
