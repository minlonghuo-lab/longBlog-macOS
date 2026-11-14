import SwiftUI
import AppKit

extension Color {
    static let blogBackground = Color(red: 46/255, green: 36/255, blue: 31/255)
    static let blogPeach = Color(red: 232/255, green: 180/255, blue: 154/255)
    static let blogText = Color(red: 243/255, green: 233/255, blue: 225/255)
}
struct Panel<Content: View>: View {
    var title: String?
    let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = title { Text(title).font(.headline) }
            content
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.07)))
    }
}
struct StatusBadge: View {
    let text: String
    var color: Color = .blogPeach
    var body: some View { Text(text).font(.caption.weight(.medium)).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.13), in: Capsule()) }
}
struct EmptyWorkspace: View {
    let symbol: String, title: String, detail: String
    var settings = false
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(Color.blogPeach)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            if settings { Button("打开连接设置") { AppModel.shared.showingSettings = true }.accessibilityLabel("打开连接设置") }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct OperationStatus: View {
    @ObservedObject var model: ServiceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.errors.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(model.errors[key] ?? "").textSelection(.enabled).font(.callout)
                    Spacer()
                    Button { model.errors[key] = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭错误提示")
                }.padding(10).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            }
            ForEach(model.successes.keys.sorted(), id: \.self) { key in
                Label(model.successes[key] ?? "", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green).textSelection(.enabled)
            }
            if model.busy { HStack { ProgressView().controlSize(.small); Text("正在处理：\(model.running.sorted().joined(separator: "、"))").font(.caption).foregroundStyle(.secondary) } }
        }.padding(.horizontal, 14).padding(.vertical, model.busy || !model.errors.isEmpty || !model.successes.isEmpty ? 10 : 0)
    }
}
struct MarkdownEditor: View {
    @Binding var text: String
    var body: some View {
        TextEditor(text: $text).font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden).padding(8)
            .background(.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Markdown 正文编辑器")
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
