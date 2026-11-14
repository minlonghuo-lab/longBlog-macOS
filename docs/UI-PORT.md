# Native macOS UI port

Status: implementation complete and ready for the parent's first actual macOS compile. This environment has no Swift/macOS SDK, so compile/runtime validation is delegated to the parent CI; no live backend writes were executed.

- `Sources/LongBlog/UI/` is owned by the UI port; do not overwrite.
- **Required bridging header addition:** `#import "UI/LBUIBridge.h"` (or relative include appropriate to your bridging header). The UI adapter uses stable C entry points to avoid ambiguous Objective-C Swift importer spellings; its `.m` must be in the source build.
- Public Swift entry points: `RootView()`, `ConnectionSettingsView()`, `@MainActor AppModel.shared`.
- Parent reader contract: `ReaderView(markdown: String, baseDirectory: URL? = nil)`.
- Parent commands may call `AppModel.shared.newArticle()`, `.newMemo()`, `.save()`, `.review()` on main actor. UI confirms destructive/remote writes and dirty navigation internally.
- UI reads existing ObjC APIs only through the adapter; it does not change Core, build scripts or app entry points.

Final feature / omission notes will be appended when implementation is complete.

## Ready for first parent compile

All five workspace views and `ConnectionSettingsView` are now present. `RootView` routes all seven `longBlog.*` notifications from parent commands, without duplicate keyboardShortcut modifiers.

**Quit integration:** parent `App.swift` already performs application termination checks using `AppModel.shared.dirtyNames` and `connectionLocked`; no additional application delegate is needed. UI installs a main-window `NSWindowDelegate` close guard and forwards unhandled messages to the prior delegate. The optional `confirmDiscardBeforeClose` convenience method is also available but need not be called by the parent.

`confirmDiscardBeforeClose(_ completion: @escaping (Bool) -> Void)` returns false on cancel or while an operation is running. Editors remain in shared observable models across sidebar navigation, so navigation itself does not lose edits. Changing article/memo/session selection, replacing configuration, and closing dirty windows confirms discard. Settings refuses account/workspace changes until dirty editor buffers are saved/discarded; it locks while any service task or frozen review is active.

Unchanged article Save is a no-op (does not rewrite updatedAt); save completion returns the newly resolved per-article directory after title/path changes. Article IO uses a dedicated serial queue and all bridge/model completions are on main. Editor controls are disabled while saving.

## Implemented files

- `AppModel.swift`: `@MainActor AppModel.shared`, operation-scoped observable models, retained dirty snapshots, confirmation and notification command routing.
- `LBUIBridge.h/.m`: two stable C entry points over the existing Objective-C APIs; serial article I/O; no new backend protocol.
- `RootView.swift`: five-section 230-point sidebar, 64-point toolbar, 290–350-point lists, 1050×700 minimum, warm translucent brown/peach palette, accessibility labels.
- `Components.swift`: material panels, chips, explicit operation errors/successes, Markdown text editor, window-close guard.
- `DashboardView.swift`: actual article/public-mirror counts, explicit inbox read, commit/build/mirror status, certificate dates/days, service errors; unavailable values are “—”, never fabricated online status.
- `InboxView.swift`: active sessions, cursor-paginated archived sessions, cursor-based messages, unread marking, contact information, confirmed replies. Retry of identical failed reply text retains messageId.
- `PostsView.swift`: searchable/filterable local list; read/edit title, body, manual summary and tags; unchanged-save no-op; native attachment importer and per-article assets; sync; stage publish/update/unpublish; AI sheet integration with exact draft-snapshot guard.
- `ConfigurationView.swift`: frozen article batch review/commit/revert and grouped, line-preserving public dotenv editing with field diffs/full serialized review and confirmed SHA-guarded main write.
- `MemosView.swift`: explicit legacy identity validation, paginated timeline/search, create/edit/visibility, pin/unpin, archive/restore, Markdown preview, native upload importer, attachment unlink and authenticated cached download/open.
- `ConnectionSettingsView.swift`: separate site/GitHub/inbox/Memos settings and SecureFields; delegates token persistence to existing macOS Keychain APIs and surfaces failures; external workspace picker. HTTPS service URLs reject embedded credentials, query and fragment; site URL does too. AI settings remain in parent AI sheet.

## Integration APIs

```swift
RootView()
ConnectionSettingsView()
AppModel.shared.newArticle()
AppModel.shared.newMemo()
AppModel.shared.save()
AppModel.shared.review()
AppModel.shared.refresh()
AppModel.shared.search()
AppModel.shared.editArticle()
AppModel.shared.dirtyNames       // [String]
AppModel.shared.connectionLocked // Bool
```

The seven `Notification.Name("longBlog.<action>")` command names match those methods. `RootView` handles all of them. Parent owns actual keyboard shortcuts.

Bridge header is already included by parent at `Core/LongBlog-Bridging-Header.h` as `../UI/LBUIBridge.h`. Compile the UI `.m` alongside Core with Core include path. `LBUIConnectionSettings()` returns connection form values, including secrets for SecureFields only: never log this dictionary. `LBUIRequest(_:_:completion:)` starts on main and always completes on main; opaque staged/revert guards remain Foundation objects, never JSON serialized by UI.

Reader calls use `ReaderView(markdown:baseDirectory:)`; explicit HTML articles use `bodyFormat: .html`. A newly saved/renamed article re-resolves its safe physical article directory. Core owns the security-scoped workspace lifetime. Remote Markdown media is rendered only as permitted by the reader's independent security policy.

## Safety and known omissions versus iOS

- No live backend or personal note mutations were performed during implementation. Only source/doc files in the assigned ownership area were created/edited.
- Main/account writes, replies, memo uploads and state changes have explicit native confirmation. Local article saves/imports require user actions. No automatic publish queue, force push, destructive reset, pending replay or remote retry was added.
- Existing pending, conflict, non-force GitHub, byte/resource safety and frozen `revertGuard` checks remain Core's authority. A failed/unknown write is reported rather than silently repeated.
- Active inbox archive **mutation is not exposed** because `LBAPI` has no such method. The “归档” button opens the real archived-session list. Permanent archived-session deletion exists in Core but is intentionally not exposed by this first UI. No fake archive endpoint/button is implemented.
- Article permanent delete and memo permanent delete are intentionally omitted; memo archive/restore and article staged unpublish are the reversible alternatives. Attachments removed from a memo are unlinked only on Save, never silently deleted from the server.
- Existing friend fields are editable in their dotenv group. Adding/removing entire numbered friend groups is deferred to repository editing.
- Manual refresh rather than a new polling/background-notification/menu-bar system; no drag/drop or multiwindow-independent editors. Shared AppModel intentionally represents one retained editing workspace.
- Memos draft buffers survive sidebar changes but are not newly wired to Core's encrypted on-disk draft API. Quit/selection/connection changes protect dirty buffers with confirmation or a save/discard prerequisite.
- Memos preview renders body Markdown; separate attachment rows use authenticated cache downloads/native opening. Inline authenticated attachment images are not rewritten into preview HTML. Article inline PNG/JPEG/GIF/WebP images follow reader capability mapping; unsupported local formats remain attachment links.
- AI body/summary/continuation is wired. Selection-only polishing is not implemented. Returned AI text cannot overwrite an editor changed since the sheet opened.
- Dark theme is intentional for this initial chosen-design port. No fabricated demo rows, deployments, certificate expiry numbers or mock online status.

## Validation performed

Read original and ported `LB.h`, `LBMdStore.h`, `LBMemos.h`; checked adapter selectors against the currently ported headers; checked ReaderView and AIWritingSheet signatures; reviewed bridge/main-queue and serial worker paths; corrected multi-binding property wrappers, unchanged saves, newly resolved asset directory after rename, post-stage/sync/commit snapshot reload, and URL validation. Actual Swift typecheck/AppKit rendering requires parent's macOS CI. No claim of successful local macOS build is made.
