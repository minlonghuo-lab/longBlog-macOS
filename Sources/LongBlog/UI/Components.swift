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

extension View {
    /// Shows the pointing-hand cursor on interactive buttons, cards and modules.
    @ViewBuilder
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(enabled ? .link : .default)
        } else {
            self.modifier(LegacyPointingHandModifier(enabled: enabled))
        }
    }
}

private struct LegacyPointingHandModifier: ViewModifier {
    let enabled: Bool
    @State private var pushed = false
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside && enabled {
                    if !pushed {
                        NSCursor.pointingHand.push()
                        pushed = true
                    }
                } else if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

// Common actions delegate drawing, interaction and focus to the system button styles,
// tinted to match the warm espresso & peach palette across the entire app.
struct BlogPrimaryButtonStyle: PrimitiveButtonStyle {
    var compact = false
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, compact: compact, large: large)
    }

    private struct PrimaryBody: View {
        let configuration: PrimitiveButtonStyle.Configuration
        let compact: Bool
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let size: ControlSize = large ? .large : (compact ? .small : .regular)
            Group {
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    Button(role: configuration.role, action: configuration.trigger) {
                        configuration.label
                            .foregroundStyle(Color.blogPeachInk)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(size)
                    .tint(Color.blogPeach)
                } else {
                    Button(role: configuration.role, action: configuration.trigger) {
                        configuration.label
                            .foregroundStyle(Color.blogPeachInk)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(size)
                    .tint(Color.blogPeach)
                }
                #else
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label
                        .foregroundStyle(Color.blogPeachInk)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(size)
                .tint(Color.blogPeach)
                #endif
            }
            .pointingHandCursor(isEnabled)
        }
    }
}

struct BlogSecondaryButtonStyle: PrimitiveButtonStyle {
    var compact = false
    var large = false
    var destructive = false
    var shape: ButtonBorderShape = .capsule

    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, compact: compact, large: large, destructive: destructive, shape: shape)
    }

    private struct SecondaryBody: View {
        let configuration: PrimitiveButtonStyle.Configuration
        let compact: Bool
        let large: Bool
        let destructive: Bool
        let shape: ButtonBorderShape
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let size: ControlSize = large ? .large : (compact ? .small : .regular)
            let fg: Color = destructive ? .blogDanger : .blogText
            Group {
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    Button(role: configuration.role, action: configuration.trigger) {
                        configuration.label
                            .foregroundStyle(fg)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(shape)
                    .controlSize(size)
                    .tint(destructive ? Color.blogDanger.opacity(0.22) : nil)
                } else {
                    Button(role: configuration.role, action: configuration.trigger) {
                        configuration.label
                            .foregroundStyle(fg)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(shape)
                    .controlSize(size)
                    .tint(destructive ? .blogDanger : nil)
                }
                #else
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label
                        .foregroundStyle(fg)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(shape)
                .controlSize(size)
                .tint(destructive ? .blogDanger : nil)
                #endif
            }
            .pointingHandCursor(isEnabled)
        }
    }
}

extension View {
    @ViewBuilder func nativeActionStyle(prominent: Bool = false, shape: ButtonBorderShape = .capsule) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
                    .buttonBorderShape(shape)
                    .tint(Color.blogPeach)
                    .foregroundStyle(Color.blogPeachInk)
                    .pointingHandCursor()
            } else {
                buttonStyle(.glass)
                    .buttonBorderShape(shape)
                    .tint(nil)
                    .foregroundStyle(Color.blogText)
                    .pointingHandCursor()
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
                    .buttonBorderShape(shape)
                    .tint(Color.blogPeach)
                    .foregroundStyle(Color.blogPeachInk)
                    .pointingHandCursor()
            } else {
                buttonStyle(.bordered)
                    .buttonBorderShape(shape)
                    .tint(nil)
                    .foregroundStyle(Color.blogText)
                    .pointingHandCursor()
            }
        }
        #else
        if prominent {
            buttonStyle(.borderedProminent)
                .buttonBorderShape(shape)
                .tint(Color.blogPeach)
                .foregroundStyle(Color.blogPeachInk)
                .pointingHandCursor()
        } else {
            buttonStyle(.bordered)
                .buttonBorderShape(shape)
                .tint(nil)
                .foregroundStyle(Color.blogText)
                .pointingHandCursor()
        }
        #endif
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

struct SegmentedOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var symbol: String? = nil
    var count: Int? = nil
    var id: Value { value }
}

private struct SegmentFrameKey<Value: Hashable>: PreferenceKey {
    static var defaultValue: [Value: CGRect] { [:] }
    static func reduce(value: inout [Value: CGRect], nextValue: () -> [Value: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Concentric capsule segmented control: both the outer track and the inner active/hover pills
/// use true `Capsule()` geometry with a uniform 3pt inset so corner curvature aligns seamlessly.
/// Supports both click switching and press-and-drag continuous sliding along the track.
struct BlogSegmentedControl<Value: Hashable>: View {
    let title: String
    let options: [SegmentedOption<Value>]
    @Binding var selection: Value
    var compact = false

    @State private var frames: [Value: CGRect] = [:]
    @State private var hoveredValue: Value? = nil
    @State private var isPressing = false
    @State private var isDragging = false
    @State private var dragStartValue: Value? = nil
    @State private var dragStartOriginX: CGFloat = 0
    @State private var dragGrabOffset: CGFloat = 0
    @State private var dragPointerX: CGFloat? = nil
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var orderedFrames: [(value: Value, rect: CGRect)] {
        options.compactMap { opt in
            guard let r = frames[opt.value], r.width > 0 else { return nil }
            return (opt.value, r)
        }.sorted { $0.rect.midX < $1.rect.midX }
    }

    private func valueAt(x: CGFloat) -> Value? {
        let items = orderedFrames
        guard !items.isEmpty else { return nil }
        if let hit = items.first(where: { x >= $0.rect.minX && x <= $0.rect.maxX }) {
            return hit.value
        }
        return items.min(by: { abs($0.rect.midX - x) < abs($1.rect.midX - x) })?.value
    }

    private var activePillRect: CGRect? {
        let items = orderedFrames
        guard let first = items.first?.rect, let last = items.last?.rect else { return nil }

        if isDragging, let pointerX = dragPointerX {
            // Interpolate width and position continuously between adjacent segment centers
            // while keeping the pill strictly inside the concentric 3pt-inset track bounds.
            let clampedX = min(max(pointerX, first.midX), last.midX)
            if items.count == 1 {
                return first
            }
            for i in 0..<(items.count - 1) {
                let a = items[i].rect
                let b = items[i + 1].rect
                if clampedX >= a.midX && clampedX <= b.midX {
                    let span = max(b.midX - a.midX, 1)
                    let t = (clampedX - a.midX) / span
                    let w = a.width + (b.width - a.width) * t
                    let rawMinX = clampedX - w / 2
                    let minX = min(max(rawMinX, first.minX), last.maxX - w)
                    return CGRect(x: minX, y: a.minY, width: w, height: a.height)
                }
            }
            return clampedX <= first.midX ? first : last
        }

        return frames[selection] ?? first
    }

    private var displaySelection: Value {
        if isDragging, let x = dragPointerX, let over = valueAt(x: x) {
            return over
        }
        return selection
    }

    var body: some View {
        let pill = activePillRect
        let highlighted = displaySelection

        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option.value == highlighted
                let isHovered = !isDragging && hoveredValue == option.value && !isSelected

                HStack(spacing: 5) {
                    if let symbol = option.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: compact ? 11 : 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.blogPeach : Color.blogSecondary)
                    }
                    Text(option.label)
                        .font(.system(size: compact ? 12 : 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.blogText : (isHovered ? Color.blogText.opacity(0.92) : Color.blogSecondary))
                    if let count = option.count {
                        Text("\(count)")
                            .font(.system(size: compact ? 11 : 11.5, weight: isSelected ? .semibold : .medium).monospacedDigit())
                            .foregroundStyle(isSelected ? Color.blogPeachSoft : Color.blogMuted)
                    }
                }
                .padding(.horizontal, compact ? 11 : 13)
                .padding(.vertical, compact ? 4.5 : 6)
                .contentShape(Capsule())
                .background {
                    if isHovered && isEnabled {
                        Capsule()
                            .fill(Color.blogSurfaceHover)
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: SegmentFrameKey<Value>.self,
                            value: [option.value: geo.frame(in: .named("seg-track"))]
                        )
                    }
                )
                .onHover { inside in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        if inside {
                            hoveredValue = option.value
                        } else if hoveredValue == option.value {
                            hoveredValue = nil
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(option.label)
                .accessibilityValue(option.count.map { "\($0) 项" } ?? "")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
                .accessibilityAction {
                    guard isEnabled, selection != option.value else { return }
                    withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.84)) {
                        selection = option.value
                    }
                }
            }
        }
        .background(alignment: .topLeading) {
            if let pill {
                Capsule()
                    .fill(Color.blogSlotActive)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                Color.blogPeach.opacity(isPressing ? 0.48 : 0.35),
                                lineWidth: 0.8
                            )
                    )
                    .shadow(
                        color: .black.opacity(isPressing ? 0.22 : 0.14),
                        radius: isPressing ? 3.5 : 2,
                        y: isPressing ? 1.5 : 1
                    )
                    .scaleEffect(isPressing && !reduceMotion ? 1.025 : 1.0)
                    .frame(width: pill.width, height: pill.height)
                    .offset(x: pill.minX, y: pill.minY)
                    .animation(
                        reduceMotion ? nil : (
                            isDragging
                                ? .interactiveSpring(response: 0.14, dampingFraction: 0.88)
                                : .spring(response: 0.26, dampingFraction: 0.84)
                        ),
                        value: pill
                    )
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressing)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "seg-track")
        .onPreferenceChange(SegmentFrameKey<Value>.self) { updated in
            frames = updated
        }
        .contentShape(Capsule())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("seg-track"))
                .onChanged { value in
                    guard isEnabled else { return }
                    if !isPressing {
                        isPressing = true
                        let startVal = valueAt(x: value.startLocation.x) ?? selection
                        dragStartValue = startVal
                        dragStartOriginX = value.startLocation.x
                        if startVal == selection, let currentRect = frames[selection] {
                            dragGrabOffset = value.startLocation.x - currentRect.midX
                        } else {
                            dragGrabOffset = 0
                        }
                    }
                    if abs(value.location.x - dragStartOriginX) > 3 || isDragging {
                        isDragging = true
                        dragPointerX = value.location.x - dragGrabOffset
                    }
                }
                .onEnded { value in
                    guard isEnabled else {
                        isPressing = false
                        isDragging = false
                        dragPointerX = nil
                        return
                    }
                    let finalX = isDragging ? (value.location.x - dragGrabOffset) : value.location.x
                    let target = valueAt(x: finalX) ?? dragStartValue ?? selection
                    withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.84)) {
                        isPressing = false
                        isDragging = false
                        dragGrabOffset = 0
                        dragPointerX = nil
                        if selection != target {
                            selection = target
                        }
                    }
                }
        )
        .padding(3)
        .background(
            Capsule()
                .fill(Color.blogSlot)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.blogStrokeStrong, lineWidth: 0.8)
        )
        .pointingHandCursor(isEnabled)
        .fixedSize()
        .focusable()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { key in
            let segments = orderedFrames
            guard isEnabled, key.modifiers.isEmpty,
                  let current = segments.firstIndex(where: { $0.value == selection }) else { return .ignored }
            let next = current + (key.key == .rightArrow ? 1 : -1)
            if segments.indices.contains(next) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    selection = segments[next].value
                }
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
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
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.992 : 1)
                .onHover { hovering = $0 }
                .pointingHandCursor()
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
        }
    }
}

struct SearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    let focusRequest: UUID
    var borderless = false
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.sendsWholeSearchString = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if borderless {
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let requested = context.coordinator.parent.focusRequest != focusRequest
        context.coordinator.parent = self
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        if field.stringValue != text && (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
        if requested { field.window?.makeFirstResponder(field) }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }
        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSSearchField { parent.text = field.stringValue }
        }
        @objc func submit(_ field: NSSearchField) {
            parent.text = field.stringValue
            parent.onSubmit()
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    .pointingHandCursor()
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
                .accessibilityElement(children: .combine)
                .toastBackground(.blogGreen)
            }
            if model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在处理：\(model.running.sorted().map(ServiceModel.label).joined(separator: "、"))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.blogSecondary)
                }
                .accessibilityElement(children: .combine)
                .toastBackground(.blogPeach)
            }
        }
        .frame(maxWidth: 540)
        .padding(.horizontal, 14)
        .padding(.vertical, model.busy || !model.errors.isEmpty || !model.successes.isEmpty ? 10 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.84), value: model.successes.count + model.errors.count + model.running.count)
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
