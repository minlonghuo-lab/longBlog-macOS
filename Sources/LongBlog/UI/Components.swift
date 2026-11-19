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
    static let blogDanger = Color(nsColor: .lb(light: .rgb(198, 56, 56), dark: .rgb(245, 118, 118)))

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

// MARK: - Liquid Glass Helpers (macOS 26+ official Apple Liquid Glass, macOS 14–15 warm fallback)

/// Groups adjacent toolbar or action-bar controls in Apple's official `GlassEffectContainer` on macOS 26+.
struct BlogGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    let content: Content
    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                HStack(spacing: spacing) {
                    content
                }
            }
        } else {
            HStack(spacing: spacing) {
                content
            }
        }
        #else
        HStack(spacing: spacing) {
            content
        }
        #endif
    }
}

extension View {
    /// Applies official Apple interactive Liquid Glass on macOS 26+ (no fake opaque overlay or double stroke),
    /// with a warm translucent fallback on macOS 14–15.
    @ViewBuilder
    func blogGlassControl(
        cornerRadius: CGFloat = 10,
        capsule: Bool = false,
        interactive: Bool = true,
        tint: Color? = nil,
        fallbackFill: Color = .blogSurface,
        fallbackStroke: Color = .blogStroke
    ) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let baseGlass: Glass = {
                var g = Glass.regular
                if let tint { g = g.tint(tint) }
                if interactive { g = g.interactive() }
                return g
            }()
            if capsule {
                self.glassEffect(baseGlass, in: Capsule())
            } else {
                self.glassEffect(baseGlass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            if capsule {
                self
                    .background(fallbackFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(fallbackStroke))
            } else {
                self
                    .background(fallbackFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(fallbackStroke))
            }
        }
        #else
        if capsule {
            self
                .background(fallbackFill, in: Capsule())
                .overlay(Capsule().strokeBorder(fallbackStroke))
        } else {
            self
                .background(fallbackFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(fallbackStroke))
        }
        #endif
    }
}

// MARK: - Official Liquid Glass Buttons (macOS 26+ .glassProminent / .glass)

/// Primary CTA button: uses Apple's official `.buttonStyle(.glassProminent)` with warm peach tint on macOS 26+.
struct BlogPrimaryButtonStyle: PrimitiveButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label
                    .foregroundStyle(Color.blogPeachInk)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(compact ? .small : .regular)
            .tint(.blogPeach)
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
        } else {
            Button(configuration)
                .buttonStyle(LegacyPrimaryButtonStyle(compact: compact))
        }
        #else
        Button(configuration)
            .buttonStyle(LegacyPrimaryButtonStyle(compact: compact))
        #endif
    }
}

private struct LegacyPrimaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        LegacyBody(configuration: configuration, compact: compact)
    }
    private struct LegacyBody: View {
        let configuration: ButtonStyle.Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(Color.blogPeachInk)
                .padding(.horizontal, compact ? 12 : 15)
                .padding(.vertical, compact ? 5.5 : 7)
                .background {
                    Capsule()
                        .fill(Color.blogPeach)
                        .brightness(hovering && isEnabled ? 0.05 : 0)
                        .shadow(color: Color.blogPeach.opacity(hovering && isEnabled ? 0.24 : 0.10), radius: hovering ? 8 : 3, y: 2)
                }
                .opacity(isEnabled ? 1 : 0.42)
                .scaleEffect(configuration.isPressed && isEnabled ? 0.975 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Secondary / destructive button: uses Apple's official neutral `.buttonStyle(.glass)` on macOS 26+.
struct BlogSecondaryButtonStyle: PrimitiveButtonStyle {
    var compact = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label
                    .foregroundStyle(destructive ? Color.blogDanger : Color.blogText)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(compact ? .small : .regular)
            .tint(nil)
            .font(.system(size: compact ? 12 : 13, weight: .medium))
        } else {
            Button(configuration)
                .buttonStyle(LegacySecondaryButtonStyle(compact: compact, destructive: destructive))
        }
        #else
        Button(configuration)
            .buttonStyle(LegacySecondaryButtonStyle(compact: compact, destructive: destructive))
        #endif
    }
}

private struct LegacySecondaryButtonStyle: ButtonStyle {
    var compact = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        LegacyBody(configuration: configuration, compact: compact, destructive: destructive)
    }
    private struct LegacyBody: View {
        let configuration: ButtonStyle.Configuration
        let compact: Bool
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            let fg: Color = destructive ? .red : .blogText
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(fg.opacity(hovering ? 1 : 0.92))
                .padding(.horizontal, compact ? 11 : 14)
                .padding(.vertical, compact ? 5.5 : 7)
                .background(
                    hovering && isEnabled ? (destructive ? Color.red.opacity(0.12) : Color.blogSurfaceHover) : Color.blogSurface,
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(destructive ? Color.red.opacity(0.38) : (hovering && isEnabled ? Color.blogStrokeStrong : Color.blogStroke))
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
            .foregroundStyle(onPrimary ? Color.blogPeachInk.opacity(0.75) : Color.blogMuted)
    }
}

// MARK: - Window toolbar

enum WorkspaceToolbarMetrics {
    // Unified height for all top-toolbar controls on macOS 26+.
    static let height: CGFloat = 34
    static let trailingInset: CGFloat = 22
}

/// Icon-only action in the unified window toolbar.
struct ToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration)
    }
    private struct BodyView: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            let base = configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.blogText)
                .frame(width: WorkspaceToolbarMetrics.height, height: WorkspaceToolbarMetrics.height)
                .contentShape(Circle())
            Group {
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    base
                        .background(Circle().fill(Color.blogSurface.opacity(hovering ? 0.9 : 0.5)))
                        .glassEffect(.regular.interactive(), in: Circle())
                        .overlay(Circle().strokeBorder(Color.blogStrokeStrong, lineWidth: 0.7))
                } else {
                    base
                        .background(hovering ? Color.blogSurfaceHover : Color.blogSurface, in: Circle())
                        .overlay(Circle().strokeBorder(Color.blogStrokeStrong, lineWidth: 0.8))
                }
                #else
                base
                    .background(hovering ? Color.blogSurfaceHover : Color.blogSurface, in: Circle())
                    .overlay(Circle().strokeBorder(Color.blogStrokeStrong, lineWidth: 0.8))
                #endif
            }
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Labeled action in the unified window toolbar.
struct ToolbarPillButtonStyle: ButtonStyle {
    var prominent = true
    var minWidth: CGFloat = 118
    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration, prominent: prominent, minWidth: minWidth)
    }
    private struct BodyView: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        let minWidth: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            let fg: Color = prominent
                ? (isEnabled ? Color.blogPeachInk : Color.blogMuted)
                : Color.blogText
            let base = configuration.label
                .font(.system(size: 12.5, weight: prominent ? .semibold : .medium))
                .foregroundStyle(fg)
                .padding(.horizontal, 14)
                .frame(minWidth: minWidth, minHeight: WorkspaceToolbarMetrics.height, maxHeight: WorkspaceToolbarMetrics.height)
                .contentShape(Capsule())
            Group {
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    if prominent {
                        base
                            .background(
                                Capsule().fill(isEnabled ? Color.blogPeach.opacity(0.88) : Color.blogSurface)
                            )
                            .glassEffect(
                                isEnabled ? .regular.tint(.blogPeach).interactive() : .regular,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isEnabled ? Color.white.opacity(0.28) : Color.blogStroke,
                                    lineWidth: 0.75
                                )
                            )
                    } else {
                        base
                            .background(Capsule().fill(Color.blogSurface.opacity(hovering ? 0.9 : 0.55)))
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.blogStrokeStrong, lineWidth: 0.75))
                    }
                } else {
                    legacyPill(base: base)
                }
                #else
                legacyPill(base: base)
                #endif
            }
            .opacity(isEnabled ? 1 : (prominent ? 0.58 : 0.45))
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }

        @ViewBuilder
        private func legacyPill<V: View>(base: V) -> some View {
            if prominent {
                base
                    .background(isEnabled ? Color.blogPeach : Color.blogSurface, in: Capsule())
                    .overlay(Capsule().strokeBorder(isEnabled ? Color.white.opacity(0.22) : Color.blogStroke))
            } else {
                base
                    .background(hovering ? Color.blogSurfaceHover : Color.blogSurface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.blogStrokeStrong))
            }
        }
    }
}

struct SegmentedOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var symbol: String? = nil
    var count: Int? = nil
    var id: Value { value }
}

private struct SegmentFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct SegmentTrackSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 { value = next }
    }
}

/// The iOS workspace tabs use UIKit's system tab bar. On Mac the moving lens
/// uses SwiftUI glass, with a magnified copy of the labels under the pointer.
struct BlogSegmentedControl<Value: Hashable>: View {
    let options: [SegmentedOption<Value>]
    @Binding var selection: Value
    var compact = false
    var onLightSurface = false
    var toolbarSized = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var segmentFrames: [Int: CGRect] = [:]
    @State private var trackSize: CGSize = .zero
    @State private var isDragging = false
    @State private var dragCenterX: CGFloat? = nil
    @State private var dragGrabOffset: CGFloat = 0
    @State private var dragStretch: CGFloat = 1.0
    @State private var lastDragX: CGFloat? = nil
    @State private var didCaptureGrab = false
    @State private var hoveredIndex: Int? = nil
    @State private var pendingIndex: Int? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var tracking = false

    private var selectedIndex: Int {
        options.firstIndex(where: { $0.value == selection }) ?? 0
    }

    private var activeVisualIndex: Int {
        if isDragging {
            return hoveredIndex ?? selectedIndex
        }
        return pendingIndex ?? selectedIndex
    }

    /// Interpolates both center X and width smoothly across segments so dragging never jumps or stalls.
    private var currentLensFrame: CGRect {
        let targetIdx = activeVisualIndex
        let fallback = segmentFrames[targetIdx] ?? segmentFrames[selectedIndex] ?? .zero
        guard isDragging, let rawX = dragCenterX, options.count > 0, fallback.width > 0 else {
            return fallback
        }
        let sorted = (0..<options.count).compactMap { idx -> (Int, CGRect)? in
            guard let f = segmentFrames[idx], f.width > 0 else { return nil }
            return (idx, f)
        }
        guard let first = sorted.first?.1, let last = sorted.last?.1 else { return fallback }

        let minCenter = first.midX
        let maxCenter = last.midX
        let clampedCenter: CGFloat
        if rawX < minCenter {
            let over = minCenter - rawX
            clampedCenter = minCenter - (1 - exp(-over / 26)) * 5.0
        } else if rawX > maxCenter {
            let over = rawX - maxCenter
            clampedCenter = maxCenter + (1 - exp(-over / 26)) * 5.0
        } else {
            clampedCenter = rawX
        }

        var interpWidth = fallback.width
        if sorted.count >= 2 {
            if clampedCenter <= first.midX {
                interpWidth = first.width
            } else if clampedCenter >= last.midX {
                interpWidth = last.width
            } else {
                for i in 0..<(sorted.count - 1) {
                    let a = sorted[i].1
                    let b = sorted[i + 1].1
                    if clampedCenter >= a.midX && clampedCenter <= b.midX {
                        let span = max(1, b.midX - a.midX)
                        let t = (clampedCenter - a.midX) / span
                        interpWidth = a.width + (b.width - a.width) * t
                        break
                    }
                }
            }
        }
        return CGRect(x: clampedCenter - interpWidth / 2, y: first.minY, width: interpWidth, height: first.height)
    }

    /// Expanded droplet loupe frame when pressing/dragging — extends above & below the capsule track like iOS 26.
    private var activeLoupeRect: CGRect {
        let base = currentLensFrame
        guard base.width > 1 && base.height > 1 else { return base }
        let extraW: CGFloat = base.width * (0.16 + (reduceMotion ? 0 : dragStretch - 1))
        let baseExtraH: CGFloat = toolbarSized ? 7.5 : (compact ? 11.5 : 14.0)
        let extraH: CGFloat = baseExtraH / sqrt(max(0.92, dragStretch))
        return CGRect(
            x: base.minX - extraW / 2,
            y: base.minY - extraH / 2,
            width: base.width + extraW,
            height: base.height + extraH
        )
    }

    var body: some View {
        let frame = currentLensFrame
        let loupe = activeLoupeRect
        let trackPad: CGFloat = toolbarSized ? 3.5 : 3.0

        let trackContent = ZStack(alignment: .topLeading) {
            // Resting pill (visible when not dragging)
            if frame.width > 1 && frame.height > 1 {
                restingPillView
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .opacity(isDragging ? 0 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.82), value: activeVisualIndex)
                    .animation(.easeOut(duration: 0.12), value: isDragging)
                    .allowsHitTesting(false)
            }

            // Base segment labels row (measures each segment frame)
            segmentsRow(inLoupe: false)
                .mask {
                    if isDragging {
                        // Clear only the pixels under the lens. A label that straddles
                        // its edge stays readable on both sides.
                        Rectangle().overlay(alignment: .topLeading) {
                            Capsule().frame(width: loupe.width, height: loupe.height)
                                .offset(x: loupe.minX, y: loupe.minY)
                                .blendMode(.destinationOut)
                        }.compositingGroup()
                    } else {
                        Rectangle()
                    }
                }
        }
        .coordinateSpace(name: "lb-seg-track")
        .padding(trackPad)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: SegmentTrackSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(SegmentFrameKey.self) { next in
            if framesChangedSignificantly(segmentFrames, next) {
                segmentFrames = next
            }
        }
        .onPreferenceChange(SegmentTrackSizeKey.self) { next in
            if abs(trackSize.width - next.width) > 0.5 || abs(trackSize.height - next.height) > 0.5 {
                trackSize = next
            }
        }
        .onChange(of: selection) { _, _ in
            pendingIndex = nil
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--smoke-loupe") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    if let f0 = segmentFrames[0], let f1 = segmentFrames[1] {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
                            isDragging = true
                            dragCenterX = f0.midX + (f1.midX - f0.midX) * 0.36
                            hoveredIndex = 0
                            dragStretch = 1.05
                        }
                    }
                }
            }
        }
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($tracking) { _, tracking, _ in tracking = true }
                .onChanged { value in
                    guard isEnabled, !segmentFrames.isEmpty else { return }
                    let localX = value.location.x - trackPad
                    let startLocalX = value.startLocation.x - trackPad
                    if !didCaptureGrab {
                        didCaptureGrab = true
                        pendingIndex = nil
                        if let selFrame = segmentFrames[selectedIndex],
                           selFrame.insetBy(dx: -4, dy: -8).contains(CGPoint(x: startLocalX, y: selFrame.midY)) {
                            dragGrabOffset = startLocalX - selFrame.midX
                        } else {
                            dragGrabOffset = 0
                        }
                        // Activate optical Liquid Glass droplet loupe immediately on press-and-hold!
                        withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.76)) {
                            isDragging = true
                        }
                        let initialCenter = (nearestIndex(for: startLocalX) == selectedIndex)
                            ? (segmentFrames[selectedIndex]?.midX ?? startLocalX)
                            : startLocalX
                        dragCenterX = initialCenter
                        lastDragX = initialCenter
                        hoveredIndex = nearestIndex(for: initialCenter) ?? selectedIndex
                        return
                    }

                    let effectiveX = localX - dragGrabOffset
                    if let prev = lastDragX {
                        let speed = abs(effectiveX - prev)
                        dragStretch = 1.0 + min(0.11, speed * 0.0065)
                    }
                    lastDragX = effectiveX
                    dragCenterX = effectiveX
                    if let nearest = nearestIndex(for: effectiveX), nearest != hoveredIndex {
                        hoveredIndex = nearest
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                }
                .onEnded { value in
                    let x = value.location.x - trackPad - dragGrabOffset
                    let target = nearestIndex(for: x) ?? hoveredIndex ?? selectedIndex
                    let wasHorizontalSlide = abs(value.translation.width) > 3
                    let releaseBounds = CGRect(origin: .zero, size: trackSize)
                        .insetBy(dx: -12, dy: -28)
                    let validRelease = wasHorizontalSlide || releaseBounds.contains(value.location)
                    if isEnabled && validRelease {
                        pendingIndex = target
                    }
                    finishTracking()
                    guard isEnabled, validRelease,
                          options.indices.contains(target),
                          options[target].value != selection else {
                        pendingIndex = nil
                        return
                    }
                    selection = options[target].value
                }
        )
        .onChange(of: tracking) { _, active in
            if !active && isDragging { finishTracking() }
        }
        .opacity(isEnabled ? 1 : 0.48)

        trackContent
            .frame(height: toolbarSized ? WorkspaceToolbarMetrics.height : nil)
            .background(
                Capsule().fill(onLightSurface ? Color.black.opacity(0.065) : Color.blogSlot)
            )
            .overlay(
                Capsule().strokeBorder(onLightSurface ? Color.black.opacity(0.08) : Color.blogStrokeStrong.opacity(0.85))
            )
            // iOS 26 Refractive Liquid Glass Droplet Loupe floats ABOVE the track bounds without vertical clipping
            .overlay(alignment: .topLeading) {
                if isDragging && loupe.width > 1 && loupe.height > 1 {
                    iOSLiquidGlassLoupe(loupe: loupe, baseFrame: frame, trackPad: trackPad)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .zIndex(isDragging ? 20 : 0)
            .fixedSize()
    }

    @ViewBuilder
    private func segmentsRow(inLoupe: Bool, tintOverride: Color? = nil) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.element.id) { idx, opt in
                let active = idx == activeVisualIndex
                let fg: Color = {
                    if let tintOverride { return tintOverride }
                    if inLoupe {
                        return onLightSurface ? Color(nsColor: .rgb(156, 76, 42)) : Color.blogPeachSoft
                    }
                    return labelColor(active: active)
                }()
                HStack(spacing: 5) {
                    if let symbol = opt.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: compact ? 11 : 12, weight: (inLoupe || active) ? .semibold : .medium))
                    }
                    Text(opt.label)
                        .font(.system(size: compact ? 11.5 : 12.5, weight: (inLoupe || active) ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if let count = opt.count {
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(
                                tintOverride ?? ((active || inLoupe) ? Color.blogPeach : Color.blogMuted)
                            )
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(fg)
                .padding(.horizontal, compact ? 10 : 12)
                .padding(.vertical, compact ? 4.5 : 5.5)
                .frame(height: toolbarSized ? WorkspaceToolbarMetrics.height - 7 : nil)
                .contentShape(Capsule())
                .background {
                    if !inLoupe {
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: SegmentFrameKey.self,
                                value: [idx: geo.frame(in: .named("lb-seg-track"))]
                            )
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(opt.label)
                .accessibilityAction { if isEnabled { selection = opt.value } }
                .accessibilityAddTraits(opt.value == selection ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func finishTracking() {
        didCaptureGrab = false
        dragGrabOffset = 0
        lastDragX = nil
        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.82)) {
            isDragging = false
            dragCenterX = nil
            dragStretch = 1
            hoveredIndex = nil
        }
    }

    private func iOSLiquidGlassLoupe(loupe: CGRect, baseFrame: CGRect, trackPad: CGFloat) -> some View {
        let rowWidth = max(1, trackSize.width - 2 * trackPad)
        let anchor = UnitPoint(x: min(0.95, max(0.05, baseFrame.midX / rowWidth)), y: 0.5)
        let loupeOffsetX = trackPad + loupe.minX
        let loupeOffsetY = trackPad + loupe.minY
        let lens = Capsule().frame(width: loupe.width, height: loupe.height)
            .offset(x: loupeOffsetX, y: loupeOffsetY)

        return ZStack(alignment: .topLeading) {
            // 1. Clear refractive Liquid Glass droplet body (macOS 26+ Glass.clear.interactive())
            Group {
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    Capsule()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(onLightSurface ? 0.14 : 0.03),
                                    Color.blogPeach.opacity(onLightSurface ? 0.14 : 0.12),
                                    Color.white.opacity(onLightSurface ? 0.26 : 0.18)
                                ],
                                center: .center,
                                startRadius: 2,
                                endRadius: max(22, loupe.width * 0.58)
                            )
                        )
                        .glassEffect(.clear.interactive(), in: Capsule())
                } else {
                    Capsule().fill(.regularMaterial)
                }
                #else
                Capsule().fill(.regularMaterial)
                #endif
            }
            .frame(width: loupe.width, height: loupe.height)
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            .offset(x: loupeOffsetX, y: loupeOffsetY)

            // 2. Optical magnified + chromatic-dispersed segment row clipped strictly to the droplet
            // Anisotropic cylindrical/droplet lens magnification (y: 1.16, x: 1.045) keeps text continuous across left/right edges.
            ZStack(alignment: .topLeading) {
                if !reduceMotion {
                    segmentsRow(inLoupe: true, tintOverride: Color(nsColor: .rgb(72, 232, 255)).opacity(0.50))
                        .scaleEffect(x: 1.06, y: 1.18, anchor: anchor)
                        .offset(x: -0.9, y: -0.45)
                        .blur(radius: 0.3)

                    segmentsRow(inLoupe: true, tintOverride: Color(nsColor: .rgb(255, 134, 66)).opacity(0.52))
                        .scaleEffect(x: 1.03, y: 1.135, anchor: anchor)
                        .offset(x: 0.9, y: 0.45)
                        .blur(radius: 0.3)
                }

                segmentsRow(inLoupe: true)
                    .scaleEffect(x: reduceMotion ? 1 : 1.045, y: reduceMotion ? 1 : 1.16, anchor: anchor)
            }
            .padding(trackPad)
            .mask(alignment: .topLeading) { lens }

            // 3. Prismatic chromatic dispersion rim & top/bottom curved glass caustics (matching iOS 26 image.png)
            ZStack {
                Capsule()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                Color(nsColor: .rgb(255, 146, 76, 0.88)),
                                Color(nsColor: .rgb(255, 232, 128, 0.85)),
                                Color(nsColor: .rgb(74, 234, 255, 0.90)),
                                Color(nsColor: .rgb(190, 152, 255, 0.72)),
                                Color.white.opacity(0.95),
                                Color(nsColor: .rgb(74, 234, 255, 0.88)),
                                Color(nsColor: .rgb(255, 224, 120, 0.82)),
                                Color(nsColor: .rgb(255, 146, 76, 0.88))
                            ],
                            center: .center
                        ),
                        lineWidth: 1.75
                    )
                    .blur(radius: 0.4)

                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.92),
                                Color.white.opacity(0.22),
                                Color.blogPeach.opacity(0.45),
                                Color.white.opacity(0.85)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.95
                    )

                Capsule()
                    .inset(by: 1.5)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .rgb(110, 238, 255, 0.55)),
                                .clear,
                                .clear,
                                Color(nsColor: .rgb(255, 172, 102, 0.55))
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.05
                    )
            }
            .frame(width: loupe.width, height: loupe.height)
            .offset(x: loupeOffsetX, y: loupeOffsetY)
        }
        .frame(width: trackSize.width, height: trackSize.height, alignment: .topLeading)
        .transaction { tx in
            if isDragging {
                tx.animation = nil
            }
        }
    }

    @ViewBuilder
    private var restingPillView: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(onLightSurface ? Color.white.opacity(0.55) : Color.blogSlotActive.opacity(0.42))
                .glassEffect(.regular.tint(Color.blogPeach.opacity(0.14)).interactive(), in: Capsule())
        } else {
            Capsule()
                .fill(onLightSurface ? Color.white.opacity(0.88) : Color.blogSlotActive)
                .overlay(Capsule().strokeBorder(Color.blogStroke.opacity(0.75)))
        }
        #else
        Capsule()
            .fill(onLightSurface ? Color.white.opacity(0.88) : Color.blogSlotActive)
            .overlay(Capsule().strokeBorder(Color.blogStroke.opacity(0.75)))
        #endif
    }

    private func labelColor(active: Bool) -> Color {
        if onLightSurface {
            return active ? Color(nsColor: .rgb(47, 38, 31)) : Color(nsColor: .rgb(122, 107, 96))
        }
        return active ? Color.blogText : Color.blogMuted
    }

    private func nearestIndex(for x: CGFloat) -> Int? {
        if let hit = segmentFrames.first(where: { x >= $0.value.minX && x < $0.value.maxX }) {
            return hit.key
        }
        return segmentFrames.min(by: { abs($0.value.midX - x) < abs($1.value.midX - x) })?.key
    }

    private func framesChangedSignificantly(_ lhs: [Int: CGRect], _ rhs: [Int: CGRect]) -> Bool {
        guard lhs.count == rhs.count else { return true }
        for (k, a) in lhs {
            guard let b = rhs[k] else { return true }
            if abs(a.minX - b.minX) > 0.5 || abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5 {
                return true
            }
        }
        return false
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
    var toolbarSized = false
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
        .padding(.horizontal, 12)
        .padding(.vertical, toolbarSized ? 0 : 6)
        .frame(height: toolbarSized ? WorkspaceToolbarMetrics.height : nil)
        .blogGlassControl(
            capsule: true,
            interactive: true,
            tint: isFocused ? Color.blogPeach.opacity(0.14) : nil,
            fallbackFill: .blogField,
            fallbackStroke: isFocused ? Color.blogPeach.opacity(0.6) : .blogStroke
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
    @ViewBuilder
    func toastBackground(_ tint: Color) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            padding(.horizontal, 14)
                .padding(.vertical, 9.5)
                .glassEffect(.regular.tint(tint.opacity(0.22)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.35)))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        #else
        padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.35)))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        #endif
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
