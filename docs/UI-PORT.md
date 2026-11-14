# Native UI integration contract (implementation in progress)

- `Sources/LongBlog/UI/` is owned by the UI port; do not overwrite.
- **Required bridging header addition:** `#import "UI/LBUIBridge.h"` (or relative include appropriate to your bridging header). The UI adapter uses stable C entry points to avoid ambiguous Objective-C Swift importer spellings; its `.m` must be in the source build.
- Public Swift entry points: `RootView()`, `ConnectionSettingsView()`, `@MainActor AppModel.shared`.
- Parent reader contract: `ReaderView(markdown: String, baseDirectory: URL? = nil)`.
- Parent commands may call `AppModel.shared.newArticle()`, `.newMemo()`, `.save()`, `.review()` on main actor. UI confirms destructive/remote writes and dirty navigation internally.
- UI reads existing ObjC APIs only through the adapter; it does not change Core, build scripts or app entry points.

Final feature / omission notes will be appended when implementation is complete.

## Ready for first parent compile

All five workspace views and `ConnectionSettingsView` are now present. `RootView` routes all seven `longBlog.*` notifications from parent commands, without duplicate keyboardShortcut modifiers.

**Quit integration:** UI installs an `NSWindowDelegate` close guard (forwarding to prior delegate) for the main window. Please add to parent `LongBlogAppDelegate`:

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task { @MainActor in
        AppModel.shared.confirmDiscardBeforeClose { allow in
            sender.reply(toApplicationShouldTerminate: allow)
        }
    }
    return .terminateLater
}
```

`confirmDiscardBeforeClose(_ completion: @escaping (Bool) -> Void)` returns false on cancel or while an operation is running. Editors remain in shared observable models across sidebar navigation, so navigation itself does not lose edits. Changing article/memo/session selection, replacing configuration, and closing dirty windows confirms discard. Settings refuses account/workspace changes until dirty editor buffers are saved/discarded; it locks while any service task or frozen review is active.

Unchanged article Save is a no-op (does not rewrite updatedAt); save completion returns the newly resolved per-article directory after title/path changes. Article IO uses a dedicated serial queue and all bridge/model completions are on main. Editor controls are disabled while saving.
