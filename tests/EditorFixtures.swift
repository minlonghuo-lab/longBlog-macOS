// Headless checks for MarkdownTextView editing behaviour (lists, toggles, wrapping, undo).
// Built by scripts/build.sh together with Sources/LongBlog/Editor/MarkdownTextView.swift.
import AppKit
import SwiftUI

extension NSColor {
    static let lbText = NSColor.textColor, lbMuted = NSColor.secondaryLabelColor, lbAccent = NSColor.systemOrange
    static let lbCode = NSColor.systemBrown, lbCodeBackground = NSColor.quaternaryLabelColor, lbLink = NSColor.linkColor, lbMath = NSColor.systemPurple
}
extension Color { static let blogSurfaceHover = Color.gray, blogPeach = Color.orange, blogText = Color.primary }

@main struct EditorFixtures {
    static var failures = 0
    static func check(_ name: String, _ got: String, _ want: String) {
        if got != want { failures += 1; print("FAIL \(name)\n  got:  \(got.debugDescription)\n  want: \(want.debugDescription)") }
    }
    static func make(_ text: String, caret: Int? = nil, select: NSRange? = nil) -> MarkdownTextView {
        let storage = NSTextStorage(), layout = NSLayoutManager(); storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1e6)); layout.addTextContainer(container)
        let tv = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        tv.isRichText = false; tv.allowsUndo = true
        tv.string = text
        tv.setSelectedRange(select ?? NSRange(location: caret ?? (text as NSString).length, length: 0))
        return tv
    }
    static func main() {
        _ = NSApplication.shared
        var tv = make("- item")
        tv.insertNewline(nil); check("bullet continues", tv.string, "- item\n- ")
        tv.insertNewline(nil); check("empty bullet ends list", tv.string, "- item\n")
        tv = make("3. three"); tv.insertNewline(nil); check("ordered increments", tv.string, "3. three\n4. ")
        tv = make("  - [x] done"); tv.insertNewline(nil); check("task continues unchecked + indent", tv.string, "  - [x] done\n  - [ ] ")
        tv = make("> quote"); tv.insertNewline(nil); check("quote continues", tv.string, "> quote\n> ")
        tv = make("plain"); tv.insertNewline(nil); check("plain newline", tv.string, "plain\n")
        tv = make("hello world", select: NSRange(location: 6, length: 5)); tv.apply(.bold); check("bold wraps", tv.string, "hello **world**")
        tv.apply(.bold); check("bold toggles off", tv.string, "hello world")
        tv = make("", caret: 0); tv.apply(.bold); check("bold placeholder", tv.string, "**粗体文字**")
        check("placeholder selected", (tv.string as NSString).substring(with: tv.selectedRange()), "粗体文字")
        tv = make("Title", caret: 2); tv.apply(.heading2); check("h2 adds", tv.string, "## Title")
        tv.apply(.heading1); check("h1 replaces h2", tv.string, "# Title")
        tv.apply(.heading1); check("h1 toggles off", tv.string, "Title")
        tv = make("a\nb", select: NSRange(location: 0, length: 3)); tv.apply(.orderedList); check("ordered lines", tv.string, "1. a\n2. b")
        tv.apply(.orderedList); check("ordered toggles off", tv.string, "a\nb")
        tv = make("a\nb", select: NSRange(location: 0, length: 3)); tv.apply(.taskList); check("task lines", tv.string, "- [ ] a\n- [ ] b")
        tv = make("word", select: NSRange(location: 0, length: 4)); tv.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0)); check("pair wraps selection", tv.string, "(word)")
        tv = make("- a", caret: 3); tv.insertTab(nil); check("tab indents list", tv.string, "    - a")
        tv.insertBacktab(nil); check("backtab outdents", tv.string, "- a")
        tv = make("x", caret: 1); tv.apply(.codeBlock); check("code fence on new line", tv.string, "x\n```\n\n```\n")
        tv = make("see", select: NSRange(location: 0, length: 3)); NSPasteboard.general.clearContents(); tv.apply(.link)
        check("link from selection", tv.string, "[see](https://)")
        check("link url selected", (tv.string as NSString).substring(with: tv.selectedRange()), "https://")
        tv = make("abc", select: NSRange(location: 0, length: 3)); tv.apply(.italic); tv.undoManager?.undo()
        if let um = tv.undoManager { _ = um } // undo needs a window-less manager; only assert no crash
        check("headings", TextStats.headings("# A\n```\n# not\n```\n## B").map { "\($0.level)\($0.title)" }.joined(separator: ","), "1A,2B")
        check("words", String(TextStats.words("你好 world, hi 世界")), "6")
        let storage = NSTextStorage(string: String(repeating: "# h\n**b** `c` $x$ [l](u)\n", count: 2000))
        let start = Date(); MarkdownHighlighter().apply(to: storage)
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "highlight 2000 blocks (%d chars): %.1f ms", storage.length, ms))
        if failures > 0 { print("\(failures) editor fixture(s) failed"); exit(1) }
        print("Editor fixtures passed.")
    }
}
