import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Actions

enum MarkdownAction: String, CaseIterable, Identifiable {
    case bold, italic, strikethrough, inlineCode, link, image
    case heading1, heading2, heading3, quote, bulletList, orderedList, taskList
    case codeBlock, table, rule, inlineMath, blockMath
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bold: return "粗体"; case .italic: return "斜体"; case .strikethrough: return "删除线"
        case .inlineCode: return "行内代码"; case .link: return "链接"; case .image: return "图片"
        case .heading1: return "一级标题"; case .heading2: return "二级标题"; case .heading3: return "三级标题"
        case .quote: return "引用"; case .bulletList: return "无序列表"; case .orderedList: return "有序列表"
        case .taskList: return "任务列表"; case .codeBlock: return "代码块"; case .table: return "表格"
        case .rule: return "分隔线"; case .inlineMath: return "行内公式"; case .blockMath: return "公式块"
        }
    }
    var symbol: String {
        switch self {
        case .bold: return "bold"; case .italic: return "italic"; case .strikethrough: return "strikethrough"
        case .inlineCode: return "chevron.left.forwardslash.chevron.right"; case .link: return "link"; case .image: return "photo"
        case .heading1: return "1.square"; case .heading2: return "2.square"; case .heading3: return "3.square"
        case .quote: return "text.quote"; case .bulletList: return "list.bullet"; case .orderedList: return "list.number"
        case .taskList: return "checklist"; case .codeBlock: return "curlybraces"; case .table: return "tablecells"
        case .rule: return "minus"; case .inlineMath: return "function"; case .blockMath: return "sum"
        }
    }
    /// Shortcut shown in menus/tooltips. Handled by the text view itself so it works only while editing.
    var shortcut: (key: KeyEquivalent, modifiers: EventModifiers)? {
        switch self {
        case .bold: return ("b", .command); case .italic: return ("i", .command)
        case .strikethrough: return ("x", [.command, .shift]); case .inlineCode: return ("c", [.command, .shift])
        case .link: return ("k", .command); case .image: return ("i", [.command, .shift])
        case .heading1: return ("1", [.command, .option]); case .heading2: return ("2", [.command, .option]); case .heading3: return ("3", [.command, .option])
        case .quote: return ("'", .command); case .bulletList: return ("8", [.command, .shift])
        case .orderedList: return ("7", [.command, .shift]); case .taskList: return ("9", [.command, .shift])
        case .codeBlock: return ("k", [.command, .shift]); case .table: return ("t", [.command, .option])
        case .rule: return ("-", [.command, .option]); case .inlineMath: return ("m", [.command, .option])
        case .blockMath: return ("m", [.command, .option, .shift])
        }
    }
    var shortcutLabel: String {
        guard let s = shortcut else { return "" }
        var out = ""
        if s.modifiers.contains(.control) { out += "⌃" }
        if s.modifiers.contains(.option) { out += "⌥" }
        if s.modifiers.contains(.shift) { out += "⇧" }
        if s.modifiers.contains(.command) { out += "⌘" }
        return out + String(s.key.character).uppercased()
    }
}

/// Bridges SwiftUI toolbars / menus to the live AppKit text view.
final class MarkdownEditorController: ObservableObject {
    weak var textView: MarkdownTextView?
    var onScroll: ((Double) -> Void)?
    var onCursorChange: ((Int, Int) -> Void)?
    func perform(_ action: MarkdownAction) {
        guard let textView = textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.apply(action)
    }
    func insert(_ text: String) {
        guard let textView = textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertBlock(text)
    }
    func focus() {
        guard let textView = textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
    func reveal(location: Int) {
        guard let textView = textView else { return }
        let range = NSRange(location: min(location, (textView.string as NSString).length), length: 0)
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: (textView.string as NSString).lineRange(for: range))
    }
    /// Menu commands target whichever Markdown editor currently has keyboard focus.
    static var focused: MarkdownTextView? {
        var window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
        while let sheet = window?.attachedSheet { window = sheet }
        return window?.firstResponder as? MarkdownTextView
    }
}

// MARK: - Line number gutter

final class MarkdownGutterView: NSRulerView {
    weak var editorView: MarkdownTextView?

    init(scrollView: NSScrollView, textView: MarkdownTextView) {
        self.editorView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 40
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let clipped = dirtyRect.intersection(bounds)
        guard !clipped.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        drawHashMarksAndLabels(in: clipped)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = editorView,
              let layout = textView.layoutManager,
              let container = textView.textContainer,
              let clip = scrollView?.contentView else { return }

        let s = textView.nsString
        guard s.length <= 400_000 else { return }

        let drawRect = rect.intersection(bounds)
        guard !drawRect.isEmpty else { return }

        // Subtle right separator line matching the warm studio gutter, strictly clipped to bounds.
        NSColor.lbMuted.withAlphaComponent(0.12).setFill()
        NSRect(x: bounds.maxX - 1, y: drawRect.minY, width: 1, height: drawRect.height).fill()

        let origin = textView.textContainerOrigin
        let visibleInContainer = clip.bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layout.glyphRange(forBoundingRect: visibleInContainer, in: container)
        let caretLineRange = s.lineRange(for: NSRange(location: min(textView.selectedRange().location, s.length), length: 0))
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(11, textView.highlighter.fontSize * 0.76), weight: .regular)
        let activeFont = NSFont.monospacedDigitSystemFont(ofSize: max(11, textView.highlighter.fontSize * 0.76), weight: .semibold)
        let mutedAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.lbMuted.withAlphaComponent(0.68)]
        let activeAttrs: [NSAttributedString.Key: Any] = [.font: activeFont, .foregroundColor: NSColor.lbAccent]

        if s.length == 0 {
            let label = "1" as NSString
            let size = label.size(withAttributes: activeAttrs)
            let y = convert(NSPoint(x: 0, y: origin.y), from: textView).y + 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y), withAttributes: activeAttrs)
            return
        }

        layout.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, fragmentGlyphRange, _ in
            let charRange = layout.characterRange(forGlyphRange: fragmentGlyphRange, actualGlyphRange: nil)
            let position = textView.linePosition(at: charRange.location)
            let isParagraphStart = position.column == 1
            if isParagraphStart {
                let isActive = NSLocationInRange(charRange.location, caretLineRange) || (caretLineRange.location == charRange.location)
                let attrs = isActive ? activeAttrs : mutedAttrs
                let label = "\(position.line)" as NSString
                let size = label.size(withAttributes: attrs)
                let y = self.convert(NSPoint(x: 0, y: lineRect.minY + origin.y), from: textView).y + max(0, (lineRect.height - size.height) * 0.42)
                label.draw(at: NSPoint(x: self.ruleThickness - size.width - 10, y: y), withAttributes: attrs)
            }
        }

        if layout.extraLineFragmentTextContainer != nil {
            let extraRect = layout.extraLineFragmentRect
            let isActive = textView.selectedRange().location == s.length
            let attrs = isActive ? activeAttrs : mutedAttrs
            let label = "\(textView.linePosition(at: s.length).line)" as NSString
            let size = label.size(withAttributes: attrs)
            let y = convert(NSPoint(x: 0, y: extraRect.minY + origin.y), from: textView).y + max(0, (extraRect.height - size.height) * 0.42)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y), withAttributes: attrs)
        }
    }
}

// MARK: - Text view

final class MarkdownTextView: NSTextView {
    var onImportFiles: (([URL]) -> Void)?
    var highlighter = MarkdownHighlighter()
    var highlightsCurrentLine = true
    private var receivingFileDrag = false {
        didSet { if oldValue != receivingFileDrag { needsDisplay = true } }
    }

    // Formatting shortcuts are handled before the main menu so ⌘B/⌘I/⌘K work even when
    // the menu bar has no matching item; they only fire while this editor is focused.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown, !hasMarkedText() else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        for action in MarkdownAction.allCases {
            guard let s = action.shortcut else { continue }
            var wanted: NSEvent.ModifierFlags = []
            if s.modifiers.contains(.command) { wanted.insert(.command) }
            if s.modifiers.contains(.shift) { wanted.insert(.shift) }
            if s.modifiers.contains(.option) { wanted.insert(.option) }
            if s.modifiers.contains(.control) { wanted.insert(.control) }
            let char = String(s.key.character).lowercased()
            // Shifted digits/punctuation report the base key in charactersIgnoringModifiers on US layouts.
            if flags == wanted && (key == char || event.keyCode == Self.keyCode(for: char)) { apply(action); return true }
        }
        if flags == .command, key == "f" { // In-editor find bar rather than list search.
            let item = NSMenuItem(); item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
            performTextFinderAction(item); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    private static func keyCode(for char: String) -> UInt16? {
        ["1": 18, "2": 19, "3": 20, "7": 26, "8": 28, "9": 25, "-": 27, "'": 39, "`": 50, "t": 17, "m": 46, "k": 40, "x": 7, "i": 34, "b": 11, "c": 8][char]
    }

    // MARK: Editing primitives (all undoable)

    // Index logical lines on demand. An edit invalidates only its line and suffix.
    private var lineStarts = [0]
    private var indexedThrough = 0
    private weak var indexedStorage: NSTextStorage?

    private func lineIndex(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while high - low > 1 {
            let mid = low + (high - low) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid }
        }
        return low
    }

    @objc private func storageDidEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        // The preceding character may now be part of a CRLF pair.
        let index = lineIndex(at: max(0, storage.editedRange.location - 1))
        lineStarts.removeSubrange((index + 1)..<lineStarts.count)
        indexedThrough = lineStarts[index]
    }

    func linePosition(at location: Int) -> (line: Int, column: Int) {
        guard let storage = textStorage else { return (1, 1) }
        if indexedStorage !== storage {
            if let old = indexedStorage { NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: old) }
            indexedStorage = storage
            lineStarts = [0]
            indexedThrough = 0
            NotificationCenter.default.addObserver(self, selector: #selector(storageDidEdit(_:)), name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        let text = storage.mutableString
        let offset = min(max(0, location), text.length)
        while indexedThrough < offset {
            var end = 0, contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: indexedThrough, length: 0))
            if contentsEnd < end { lineStarts.append(end) }
            indexedThrough = end
        }
        let index = lineIndex(at: offset)
        return (index + 1, offset - lineStarts[index] + 1)
    }

    var nsString: NSString { string as NSString }

    @discardableResult
    func replace(_ range: NSRange, with text: String, select: NSRange? = nil) -> Bool {
        guard shouldChangeText(in: range, replacementString: text) else { return false }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(select ?? NSRange(location: range.location + (text as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }

    func insertBlock(_ text: String) {
        let sel = selectedRange()
        var prefix = ""
        if sel.location > 0, nsString.character(at: sel.location - 1) != 10 { prefix = "\n" }
        replace(sel, with: prefix + text)
    }

    func apply(_ action: MarkdownAction) {
        guard isEditable, !hasMarkedText() else { return }
        switch action {
        case .bold: wrap("**", "**", placeholder: "粗体文字")
        case .italic: wrap("*", "*", placeholder: "斜体文字")
        case .strikethrough: wrap("~~", "~~", placeholder: "删除内容")
        case .inlineCode: wrap("`", "`", placeholder: "code")
        case .inlineMath: wrap("$", "$", placeholder: "E=mc^2")
        case .link: insertLink(image: false)
        case .image: insertLink(image: true)
        case .heading1: heading(1)
        case .heading2: heading(2)
        case .heading3: heading(3)
        case .quote: toggleLinePrefix { _ in "> " }
        case .bulletList: toggleLinePrefix { _ in "- " }
        case .orderedList: toggleLinePrefix { "\($0 + 1). " }
        case .taskList: toggleLinePrefix { _ in "- [ ] " }
        case .codeBlock: fenced("```", placeholder: "")
        case .blockMath: fenced("$$", placeholder: "\\int_0^1 x^2\\,dx")
        case .table:
            insertBlock("| 列 1 | 列 2 | 列 3 |\n| --- | --- | --- |\n| 内容 | 内容 | 内容 |\n")
        case .rule: insertBlock("\n---\n\n")
        }
        undoManager?.setActionName(action.title)
    }

    private func wrap(_ open: String, _ close: String, placeholder: String) {
        let sel = selectedRange(), o = (open as NSString).length, c = (close as NSString).length
        // Toggle off when the selection is already wrapped (inside or including markers).
        if sel.location >= o, NSMaxRange(sel) + c <= nsString.length,
           nsString.substring(with: NSRange(location: sel.location - o, length: o)) == open,
           nsString.substring(with: NSRange(location: NSMaxRange(sel), length: c)) == close {
            let inner = nsString.substring(with: sel)
            replace(NSRange(location: sel.location - o, length: sel.length + o + c), with: inner,
                    select: NSRange(location: sel.location - o, length: (inner as NSString).length))
            return
        }
        let selected = nsString.substring(with: sel)
        if sel.length >= o + c, selected.hasPrefix(open), selected.hasSuffix(close) {
            let inner = String(selected.dropFirst(open.count).dropLast(close.count))
            replace(sel, with: inner, select: NSRange(location: sel.location, length: (inner as NSString).length))
            return
        }
        let inner = sel.length > 0 ? selected : placeholder
        replace(sel, with: open + inner + close, select: NSRange(location: sel.location + o, length: (inner as NSString).length))
    }

    private func insertLink(image: Bool) {
        let sel = selectedRange()
        let selected = nsString.substring(with: sel)
        let isURL: (String) -> Bool = { $0.range(of: #"^(https?://|/|\./)\S+$"#, options: .regularExpression) != nil }
        let bang = image ? "!" : ""
        if isURL(selected) {
            let label = image ? "图片描述" : "链接文字"
            replace(sel, with: "\(bang)[\(label)](\(selected))", select: NSRange(location: sel.location + (bang as NSString).length + 1, length: (label as NSString).length))
        } else {
            let label = selected.isEmpty ? (image ? "图片描述" : "链接文字") : selected
            let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = isURL(clipboard) ? clipboard : "https://"
            let text = "\(bang)[\(label)](\(url))"
            let urlStart = sel.location + (bang as NSString).length + (label as NSString).length + 3
            let selection = selected.isEmpty ? NSRange(location: sel.location + (bang as NSString).length + 1, length: (label as NSString).length)
                                             : NSRange(location: urlStart, length: (url as NSString).length)
            replace(sel, with: text, select: selection)
        }
    }

    private func lineRange() -> NSRange {
        var range = nsString.lineRange(for: selectedRange())
        // Exclude the trailing newline so we never touch the next line.
        if range.length > 0, NSMaxRange(range) <= nsString.length, nsString.character(at: NSMaxRange(range) - 1) == 10, range.length > 0 {
            range.length -= 1
        }
        return range
    }

    private func heading(_ level: Int) {
        let range = lineRange()
        let line = nsString.substring(with: range)
        let marker = String(repeating: "#", count: level) + " "
        let stripped = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        let result = line.hasPrefix(marker) ? stripped : marker + stripped
        replace(range, with: result, select: NSRange(location: range.location + (result as NSString).length, length: 0))
    }

    private static let linePrefix = #"^(\s*)(?:[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+|>\s?)"#

    private func toggleLinePrefix(_ make: (Int) -> String) {
        let range = lineRange()
        let lines = nsString.substring(with: range).components(separatedBy: "\n")
        let first = make(0)
        let core: (String) -> String = { $0.replacingOccurrences(of: #"\d+"#, with: "1", options: .regularExpression) }
        let allHave = lines.allSatisfy { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            return core(String(trimmed)).hasPrefix(core(first)) || line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        var index = 0
        let output = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1 { return line }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let body = String(line.dropFirst(indent.count))
            let bare = body.replacingOccurrences(of: Self.linePrefix, with: "", options: .regularExpression)
            defer { index += 1 }
            return allHave ? indent + bare : indent + make(index) + bare
        }.joined(separator: "\n")
        replace(range, with: output, select: lines.count > 1 ? NSRange(location: range.location, length: (output as NSString).length)
                                                            : NSRange(location: range.location + (output as NSString).length, length: 0))
    }

    private func fenced(_ fence: String, placeholder: String) {
        let sel = selectedRange()
        let selected = nsString.substring(with: sel)
        var prefix = ""
        if sel.location > 0, nsString.character(at: sel.location - 1) != 10 { prefix = "\n" }
        let inner = selected.isEmpty ? placeholder : selected
        let text = "\(prefix)\(fence)\n\(inner)\n\(fence)\n"
        let start = sel.location + (prefix as NSString).length + (fence as NSString).length + (selected.isEmpty && fence == "```" ? 0 : 1)
        // For an empty code fence place the caret right after ``` to type the language.
        let selection = selected.isEmpty && fence == "```" ? NSRange(location: start, length: 0) : NSRange(location: start, length: (inner as NSString).length)
        replace(sel, with: text, select: selection)
    }

    // MARK: Typing behaviour

    private static let listPattern = try! NSRegularExpression(pattern: #"^(\s*)(?:([-*+])(\s+)(\[[ xX]\]\s+)?|(\d+)([.)])(\s+)|(>\s?))"#)

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0 else { return super.insertNewline(sender) }
        let caret = selectedRange().location
        let line = nsString.lineRange(for: NSRange(location: caret, length: 0))
        let head = nsString.substring(with: NSRange(location: line.location, length: caret - line.location))
        guard let match = Self.listPattern.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) else {
            // Keep indentation for code and nested content.
            let indent = String(head.prefix { $0 == " " || $0 == "\t" })
            if !indent.isEmpty, !head.trimmingCharacters(in: .whitespaces).isEmpty { replace(selectedRange(), with: "\n" + indent); return }
            return super.insertNewline(sender)
        }
        let h = head as NSString
        let indent = match.range(at: 1).location != NSNotFound ? h.substring(with: match.range(at: 1)) : ""
        let rest = h.substring(from: match.range.length).trimmingCharacters(in: .whitespaces)
        let tailEmpty = nsString.substring(with: NSRange(location: caret, length: NSMaxRange(line) - caret)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if rest.isEmpty && tailEmpty {
            // Empty item: end the list (remove the marker) like every modern editor.
            replace(NSRange(location: line.location, length: caret - line.location), with: "")
            return
        }
        var next: String
        if match.range(at: 2).location != NSNotFound {
            next = h.substring(with: match.range(at: 2)) + h.substring(with: match.range(at: 3))
            if match.range(at: 4).location != NSNotFound { next += "[ ] " }
        } else if match.range(at: 5).location != NSNotFound {
            next = "\((Int(h.substring(with: match.range(at: 5))) ?? 0) + 1)" + h.substring(with: match.range(at: 6)) + h.substring(with: match.range(at: 7))
        } else {
            next = "> "
        }
        replace(selectedRange(), with: "\n" + indent + next)
    }

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else { return super.insertTab(sender) }
        let range = lineRange()
        let text = nsString.substring(with: range)
        let isList = Self.listPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        if selectedRange().length > 0 && text.contains("\n") || isList { shiftLines(by: 1); return }
        replace(selectedRange(), with: "    ")
    }

    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText() else { return super.insertBacktab(sender) }
        shiftLines(by: -1)
    }

    private func shiftLines(by direction: Int) {
        let range = lineRange()
        let lines = nsString.substring(with: range).components(separatedBy: "\n")
        let out = lines.map { line -> String in
            if direction > 0 { return line.isEmpty ? line : "    " + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = min(4, line.prefix { $0 == " " }.count)
            return String(line.dropFirst(spaces))
        }.joined(separator: "\n")
        let caretOffset = selectedRange().location - range.location
        if lines.count == 1 && selectedRange().length == 0 {
            let delta = (out as NSString).length - (nsString.substring(with: range) as NSString).length
            replace(range, with: out, select: NSRange(location: max(range.location, range.location + caretOffset + delta), length: 0))
        } else {
            replace(range, with: out, select: NSRange(location: range.location, length: (out as NSString).length))
        }
    }

    private static let wrappers: [String: String] = ["*": "*", "_": "_", "`": "`", "~": "~", "\"": "\"", "(": ")", "[": "]", "$": "$", "“": "”", "「": "」", "《": "》"]

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Typing a pairing character over a selection wraps it instead of replacing it.
        if let s = string as? String, let close = Self.wrappers[s], !hasMarkedText(),
           replacementRange.location == NSNotFound, selectedRange().length > 0 {
            let sel = selectedRange(), inner = nsString.substring(with: sel)
            replace(sel, with: s + inner + close, select: NSRange(location: sel.location + (s as NSString).length, length: sel.length))
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: Paste & drop

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty, onImportFiles != nil {
            onImportFiles?(urls); return
        }
        if board.string(forType: .string) == nil, onImportFiles != nil,
           let image = NSImage(pasteboard: board), let url = Self.writeTemporaryPNG(image) {
            onImportFiles?([url]); return
        }
        // Pasting a URL over selected text produces a Markdown link.
        if let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           selectedRange().length > 0, !text.contains("\n"), text.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil {
            let sel = selectedRange(), label = nsString.substring(with: sel)
            replace(sel, with: "[\(label)](\(text))")
            return
        }
        pasteAsPlainText(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onImportFiles != nil,
           let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            receivingFileDrag = true
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        receivingFileDrag = false
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        receivingFileDrag = false
        let board = sender.draggingPasteboard
        if onImportFiles != nil,
           let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let point = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: point)
            setSelectedRange(NSRange(location: min(index, nsString.length), length: 0))
            onImportFiles?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if highlightsCurrentLine, window?.firstResponder === self, selectedRange().length == 0,
           let layout = layoutManager, let container = textContainer, nsString.length <= 400_000 {
            let sel = NSRange(location: min(selectedRange().location, nsString.length), length: 0)
            let lineRect: NSRect
            if sel.location == nsString.length && (nsString.length == 0 || nsString.character(at: nsString.length - 1) == 10),
               layout.extraLineFragmentTextContainer != nil {
                lineRect = layout.extraLineFragmentRect
            } else {
                let paraRange = nsString.lineRange(for: sel)
                let glyphRange = layout.glyphRange(forCharacterRange: paraRange, actualCharacterRange: nil)
                lineRect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            }
            if lineRect.height > 0 {
                let band = NSRect(x: 0, y: lineRect.minY + textContainerOrigin.y, width: bounds.width, height: lineRect.height)
                if band.intersects(rect) {
                    NSColor.lbAccent.withAlphaComponent(0.042).setFill()
                    band.fill()
                }
            }
        }
        if receivingFileDrag, let visible = enclosingScrollView?.documentVisibleRect {
            let frame = visible.insetBy(dx: 6, dy: 6)
            let path = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
            NSColor.lbAccent.withAlphaComponent(0.06).setFill()
            path.fill()
            path.lineWidth = 1.5
            let dash: [CGFloat] = [6, 4]
            path.setLineDash(dash, count: 2, phase: 0)
            NSColor.lbAccent.withAlphaComponent(0.7).setStroke()
            path.stroke()
        }
    }

    static func writeTemporaryPNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("longBlog-paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let url = dir.appendingPathComponent("粘贴图片-\(stamp).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    // MARK: Highlighting

    func rehighlight() {
        guard let storage = textStorage, !hasMarkedText() else { return }
        highlighter.apply(to: storage)
        typingAttributes = highlighter.baseAttributes
    }
}

// MARK: - Highlighter

struct MarkdownHighlighter {
    var fontSize: CGFloat = 15
    var monospaced = false

    var baseFont: NSFont { monospaced ? .monospacedSystemFont(ofSize: fontSize, weight: .regular) : .systemFont(ofSize: fontSize) }
    var monoFont: NSFont { .monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular) }
    var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle(); p.lineSpacing = fontSize * 0.42; p.paragraphSpacing = fontSize * 0.25; return p
    }
    var baseAttributes: [NSAttributedString.Key: Any] { [.font: baseFont, .foregroundColor: NSColor.lbText, .paragraphStyle: paragraph] }

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private static let heading = rx(#"^(#{1,6})[ \t]+.*$"#)
    private static let fence = rx(#"^(```|~~~)[^\n]*\n[\s\S]*?^\1[ \t]*$"#)
    private static let blockMath = rx(#"^\$\$[\s\S]*?^\$\$[ \t]*$"#)
    private static let bold = rx(#"(\*\*|__)(?=\S)[^\n]+?(?<=\S)\1"#)
    private static let italic = rx(#"(?<![*\w\\])([*_])(?=[^\s*_])[^\n*_]+?(?<=\S)\1(?![*\w])"#)
    private static let strike = rx(#"~~(?=\S)[^\n]+?(?<=\S)~~"#)
    private static let code = rx(#"(`+)[^`\n]+?\1"#)
    private static let link = rx(#"!?\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let autolink = rx(#"<https?://[^>\s]+>|(?<![(\[])https?://[^\s)<>]+"#)
    private static let quote = rx(#"^[ \t]{0,3}>.*$"#)
    private static let list = rx(#"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#)
    private static let rule = rx(#"^[ \t]{0,3}(?:-[ \t]*){3,}$|^[ \t]{0,3}(?:\*[ \t]*){3,}$"#)
    private static let inlineMath = rx(#"(?<![\\$])\$(?=[^\s$])[^\n$]+?(?<=[^\s\\])\$(?!\$)"#)
    private static let html = rx(#"</?[A-Za-z][^>\n]*>"#)
    private static let table = rx(#"^[ \t]*\|.*\|[ \t]*$"#)

    func apply(to storage: NSTextStorage) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        let muted = NSColor.lbMuted, accent = NSColor.lbAccent
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        // Very large documents only get the cheap base styling to keep typing responsive.
        guard text.length < 400_000 else { storage.endEditing(); return }
        let src = storage.string
        func each(_ r: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) { r.enumerateMatches(in: src, range: full) { m, _, _ in if let m = m { body(m) } } }

        each(Self.heading) { m in
            let level = m.range(at: 1).length
            let scale: CGFloat = [1.5, 1.32, 1.18, 1.08, 1.0, 1.0][min(level, 6) - 1]
            let font = monospaced ? NSFont.monospacedSystemFont(ofSize: fontSize * scale, weight: .bold) : NSFont.systemFont(ofSize: fontSize * scale, weight: .bold)
            storage.addAttributes([.font: font, .foregroundColor: NSColor.lbText], range: m.range)
            storage.addAttribute(.foregroundColor, value: accent.withAlphaComponent(0.75), range: m.range(at: 1))
        }
        each(Self.quote) { m in storage.addAttribute(.foregroundColor, value: muted, range: m.range) }
        each(Self.table) { m in storage.addAttribute(.font, value: monoFont, range: m.range) }
        each(Self.list) { m in storage.addAttributes([.foregroundColor: accent], range: m.range) }
        each(Self.rule) { m in storage.addAttribute(.foregroundColor, value: muted, range: m.range) }
        each(Self.bold) { m in
            storage.applyFontTraits(.boldFontMask, range: m.range)
            storage.addAttribute(.foregroundColor, value: muted, range: NSRange(location: m.range.location, length: 2))
            storage.addAttribute(.foregroundColor, value: muted, range: NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        each(Self.italic) { m in
            storage.addAttribute(.obliqueness, value: 0.16, range: m.range) // CJK fonts have no italic face.
            storage.addAttribute(.foregroundColor, value: muted, range: NSRange(location: m.range.location, length: 1))
            storage.addAttribute(.foregroundColor, value: muted, range: NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        each(Self.strike) { m in storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: muted], range: m.range) }
        each(Self.html) { m in storage.addAttribute(.foregroundColor, value: muted, range: m.range) }
        each(Self.autolink) { m in storage.addAttribute(.foregroundColor, value: NSColor.lbLink, range: m.range) }
        each(Self.link) { m in
            storage.addAttribute(.foregroundColor, value: NSColor.lbLink, range: m.range)
            let s = text.substring(with: m.range) as NSString
            let split = s.range(of: "](")
            if split.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: muted, range: NSRange(location: m.range.location + split.location + 1, length: m.range.length - split.location - 1))
            }
        }
        each(Self.inlineMath) { m in storage.addAttributes([.foregroundColor: NSColor.lbMath, .font: monoFont], range: m.range) }
        each(Self.code) { m in storage.addAttributes([.font: monoFont, .foregroundColor: NSColor.lbCode, .backgroundColor: NSColor.lbCodeBackground], range: m.range) }
        // Block constructs last: they override any inline match inside them.
        each(Self.blockMath) { m in storage.setAttributes(baseAttributes.merging([.font: monoFont, .foregroundColor: NSColor.lbMath]) { $1 }, range: m.range) }
        each(Self.fence) { m in
            storage.setAttributes(baseAttributes.merging([.font: monoFont, .foregroundColor: NSColor.lbCode]) { $1 }, range: m.range)
            let firstLine = text.lineRange(for: NSRange(location: m.range.location, length: 0))
            storage.addAttribute(.foregroundColor, value: muted, range: NSIntersectionRange(firstLine, m.range))
        }
        storage.endEditing()
    }
}

// MARK: - SwiftUI wrapper

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Changing the document identity resets undo history instead of making the swap undoable.
    var documentID: String = ""
    var controller: MarkdownEditorController?
    var editable = true
    var fontSize: CGFloat = 15
    var monospaced = false
    var showLineNumbers = false
    var maxContentWidth: CGFloat? = nil
    var onImportFiles: (([URL]) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.clipsToBounds = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let old = scroll.documentView as! NSTextView
        // Explicit TextKit 1 stack: stable attribute highlighting, find bar and large documents.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: old.frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let textView = MarkdownTextView(frame: old.frame, textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.insertionPointColor = .lbAccent
        textView.textContainerInset = NSSize(width: 24, height: 22)
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Markdown 正文编辑器")
        scroll.documentView = textView

        let gutter = MarkdownGutterView(scrollView: scroll, textView: textView)
        gutter.clipsToBounds = true
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = showLineNumbers

        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didScroll(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didResize(_:)),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        context.coordinator.textView = textView
        context.coordinator.gutter = gutter
        configure(textView, scroll: scroll, context: context, initial: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? MarkdownTextView else { return }
        context.coordinator.parent = self
        configure(textView, scroll: scroll, context: context, initial: false)
    }

    static func applyContentInset(to textView: MarkdownTextView, scroll: NSScrollView?, maxContentWidth: CGFloat?) {
        let baseInset: CGFloat = scroll?.rulersVisible == true ? 18 : 24
        let targetWidth: CGFloat
        if let width = maxContentWidth, let scroll = scroll {
            targetWidth = max(baseInset, (scroll.contentSize.width - width) / 2)
        } else {
            targetWidth = baseInset
        }
        if abs(textView.textContainerInset.width - targetWidth) > 0.5 || abs(textView.textContainerInset.height - 22) > 0.5 {
            textView.textContainerInset = NSSize(width: targetWidth, height: 22)
        }
    }

    private func configure(_ textView: MarkdownTextView, scroll: NSScrollView, context: Context, initial: Bool) {
        controller?.textView = textView
        textView.onImportFiles = onImportFiles
        textView.isEditable = editable
        if scroll.rulersVisible != showLineNumbers {
            scroll.rulersVisible = showLineNumbers
        }
        var styleChanged = false
        if textView.highlighter.fontSize != fontSize || textView.highlighter.monospaced != monospaced {
            textView.highlighter.fontSize = fontSize; textView.highlighter.monospaced = monospaced; styleChanged = true
        }
        Self.applyContentInset(to: textView, scroll: scroll, maxContentWidth: maxContentWidth)
        let coordinator = context.coordinator
        if initial || coordinator.documentID != documentID {
            coordinator.documentID = documentID
            textView.string = text
            textView.undoManager?.removeAllActions(withTarget: textView.textStorage as Any)
            textView.undoManager?.removeAllActions(withTarget: textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scroll(.zero)
            textView.rehighlight()
            coordinator.reportCursor()
            coordinator.gutter?.needsDisplay = true
        } else if textView.string != text, !textView.hasMarkedText() {
            // External change of the same document (AI apply, attachment): keep it undoable.
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            let sel = textView.selectedRange()
            let targetSel = NSRange(location: min(sel.location, (text as NSString).length), length: 0)
            _ = textView.replace(full, with: text, select: targetSel)
            if targetSel.location == 0 { textView.scroll(.zero) }
            textView.rehighlight()
            coordinator.reportCursor()
            coordinator.gutter?.needsDisplay = true
        } else if styleChanged {
            textView.rehighlight()
            coordinator.gutter?.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        weak var textView: MarkdownTextView?
        weak var gutter: MarkdownGutterView?
        var documentID: String?
        private var pendingHighlight: DispatchWorkItem?
        init(_ parent: MarkdownTextEditor) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            gutter?.needsDisplay = true
            // Coalesced, never while the IME is composing. Short posts restyle on the next
            // run-loop turn; long ones (regex cost grows linearly) wait for a typing pause.
            pendingHighlight?.cancel()
            let length = (textView.string as NSString).length
            let delay = length < 12_000 ? 0 : min(0.45, Double(length) / 160_000)
            let work = DispatchWorkItem { [weak self] in
                self?.textView?.rehighlight()
                self?.gutter?.needsDisplay = true
            }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.needsDisplay = true
            gutter?.needsDisplay = true
            reportCursor()
        }

        func reportCursor() {
            guard let textView = textView, let callback = parent.controller?.onCursorChange else { return }
            let position = textView.linePosition(at: textView.selectedRange().location)
            callback(position.line, position.column)
        }

        @objc func didScroll(_ notification: Notification) {
            gutter?.needsDisplay = true
            guard let clip = notification.object as? NSClipView, let doc = clip.documentView else { return }
            let range = doc.frame.height - clip.bounds.height
            parent.controller?.onScroll?(range > 1 ? Double(max(0, min(1, clip.bounds.minY / range))) : 0)
        }

        @objc func didResize(_ notification: Notification) {
            guard let textView = textView else { return }
            MarkdownTextEditor.applyContentInset(to: textView, scroll: textView.enclosingScrollView, maxContentWidth: parent.maxContentWidth)
            gutter?.needsDisplay = true
        }
    }
}

// MARK: - Toolbar & stats

struct MarkdownToolbar: View {
    let controller: MarkdownEditorController
    var compact = false
    var attach: (() -> Void)?
    private var primary: [MarkdownAction] { compact ? [.bold, .italic, .link, .inlineCode, .bulletList, .taskList, .quote] : [.heading1, .heading2, .heading3, .bold, .italic, .strikethrough, .inlineCode, .link, .image, .quote, .bulletList, .orderedList, .taskList, .codeBlock] }
    private var overflow: [MarkdownAction] { MarkdownAction.allCases.filter { !primary.contains($0) } }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(primary) { action in
                ToolbarIcon(symbol: action.symbol, help: "\(action.title)  \(action.shortcutLabel)") { controller.perform(action) }
                if [.heading3, .inlineCode, .image].contains(action) && !compact { Divider().frame(height: 16).padding(.horizontal, 3) }
            }
            Menu {
                ForEach(overflow) { action in Button("\(action.title)\t\(action.shortcutLabel)") { controller.perform(action) } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().editorPointingHand().help("更多格式").accessibilityLabel("更多 Markdown 格式")
            if let attach = attach {
                Divider().frame(height: 16).padding(.horizontal, 3)
                ToolbarIcon(symbol: "paperclip", help: "插入附件 / 图片（也可直接粘贴或拖入编辑器）", action: attach)
            }
        }
    }
}

private extension View {
    /// Local copy so MarkdownTextView remains standalone for EditorFixtures.
    @ViewBuilder func editorPointingHand() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }
}

struct ToolbarIcon: View {
    let symbol: String, help: String, action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 26, height: 24)
                .background(hovering ? Color.blogSurfaceHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain).foregroundStyle(hovering ? Color.blogPeach : Color.blogText.opacity(0.82))
        .onHover { hovering = $0 }.editorPointingHand().help(help).accessibilityLabel(help)
    }
}

enum TextStats {
    /// CJK characters count individually; Latin runs count as words (blog-style 字数).
    static func words(_ text: String) -> Int {
        var count = 0, inWord = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let cjk = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v)
            if cjk { count += 1; inWord = false }
            else if CharacterSet.alphanumerics.contains(scalar) { if !inWord { count += 1; inWord = true } }
            else { inWord = false }
        }
        return count
    }
    static func readingMinutes(_ words: Int) -> Int { max(1, Int((Double(words) / 400).rounded(.up))) }
    static func headings(_ text: String) -> [(level: Int, title: String, location: Int)] {
        var result: [(Int, String, Int)] = []
        var location = 0, inFence = false
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            else if !inFence, line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6, line.dropFirst(level).first == " ", !title.isEmpty { result.append((level, title, location)) }
            }
            location += length + 1
        }
        return result
    }
}
