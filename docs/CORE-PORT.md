# macOS business-layer integration contract

Status: implementation complete. Baseline: iOS `6245c80`. Public business selectors retain their original names. No UIKit controllers, theme helpers, or iOS application delegates are exported.

**Build requirement: add `-framework UserNotifications`** to the parent's existing Foundation/AppKit/Security/WebKit/UniformTypeIdentifiers framework list. `LBSync.m` uses the modern, macOS-supported notification API; `LB.h` itself imports only Foundation/AppKit.

## Swift/UI contract (stable)

Import `Sources/LongBlog/Core/LongBlog-Bridging-Header.h`. Its final import is `../UI/LBUIBridge.h`, as requested by the UI agent. Existing `LBKeychain.get:` / `set:account:` APIs are unchanged, including for the Swift AI module.

- `LBMdStore.shared`: list/load/save, staging/revert, atomic GitHub article sync/commit; article dictionaries remain unchanged. `saveArticleWithId:title:markdown:summary:publish:tags:error:` and all existing selectors retained.
- `LBEnvFile.parse`, `valueFor:`, `updateValue:forKey:`, `serialize`, `validate`, friend operations retained.
- `LBGitHub.shared`, `.token`, `.configured`; existing Git tree/snapshot/commit APIs retained.
- `LBStore` site URL/repo/certificate-host preferences retained.
- `LBAPI.shared` terminal-chat DTOs and HTTP methods retained.
- `LBMemosClient.shared` and `LBMemosCache.h` methods retained. Authenticated Memos cache remains isolated from public `LBSiteData.memos`.
- `LBSiteData.shared` refresh methods and notifications retained.
- `LBHTTP.image:done:` now returns **NSImage**, not UIImage.
- `LBSiteData.deployState:pending:` color out parameter is **NSColor**, not UIColor. Theme/controllers are not exported.
- `LBMarkdownToHTML`, `LBHTMLToMarkdown`, `LBMemoVisibility`, `LBMemoPlain`, `LBDateText`, `LBRelativeTime`, `LBRemaining` are plain exported functions.
- `LBSync` public methods retained; macOS foreground polling + Foundation background scheduler replace iOS background tasks. Header is Foundation/AppKit only.

Do not assume `.env` commit is complete until its completion handler succeeds. Preserve staged selection dictionaries including opaque revertGuard when reverting. Do not force-push/replay outcome-unknown article transactions. All UI-driven mutable operations should originate on the main thread. Callback APIs are the existing Objective-C block APIs; Swift can use completion closures (no new async/await requirement).

## Storage and permissions

All default persistent local content goes below `Application Support/longBlog` (`Posts`, Memos cache/bindings/drafts). External articles use macOS security-scoped bookmarks; the app shell should grant `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope` when sandboxed. No automatic migration/import from Documents or the iOS keychain.

Keychain service is a distinct macOS namespace: `com.huowenlong.longblog.macos`. Never fall back to the iOS namespace.

## Implementation notes

- `LBEnv.m`, `LBMarkdown.h/.m`, and `LBMemosCache.h` retain the source business logic verbatim. No dummy network or persistence implementations were substituted.
- Article operations retain the original canonical/physical path mapping, single-source Markdown/embedded-HTML handling, timestamps, staged selection guards, verified layout migration, immutable GitHub snapshot, atomic multi-file commits, journaled local revert, and read-only recovery of outcome-unknown transactions. Existing drafts, local edits and shared attachments remain protected by the original policies.
- GitHub keeps frozen repository/credential identities, blob digest verification, redirect rejection, bounded GET-only retries, and non-force ref updates. Mutations are not blindly retried.
- Authenticated Memos retains legacy integer-ID server DTO validation, origin-bound bearer credentials, conflict checks, bounded multipart/file transfers, per-account drafts, offline identity bindings, persistent borrowed original resources, generation/epoch invalidation, serialized cache IO, and two-state verified pruning.
- `LBPlatform.h/.m` centralizes the Application Support root. Private Memos files/directories use macOS POSIX permissions (0600/0700), atomic writes and backup exclusion instead of iOS-only file-protection flags. This is NOT encryption or iOS Data Protection; use FileVault/system account protection where required.
- macOS login Keychain items are non-synchronizing. They use normal login-Keychain unlock/ACL behavior; no iOS accessibility attributes are written. Both owner-key and generic `LBKeychain` storage use `com.huowenlong.longblog.macos`. There is no fallback to iOS credentials and no automatic credential migration.
- External folder creation/renewal uses `NSURLBookmarkCreationWithSecurityScope`; resolution uses `NSURLBookmarkResolutionWithSecurityScope | NSURLBookmarkResolutionWithoutUI`. Security scope is stopped on the exact NSURL instance that started it. Folder changes are rejected while a remote article operation/revert is active. A stored bookmark that cannot resolve retains the original internal-folder fallback behavior; the bookmark is not deleted and the inaccessible external folder is not modified.
- Added `-[LBMdStore initWithLocalFolderURL:error:]`: explicitly supplied existing real local directory, no defaults/bookmark/Keychain/network access during construction. Caller owns any external security scope. Native fixtures use this instead of `.shared` or normal `init`, so they cannot scan or modify real selected notes.
- Certificate expiry uses public macOS `SecCertificateCopyValues` plus `kSecOIDX509V1ValidityNotAfter`; the numeric value is a CFAbsoluteTime (reference-date seconds), not Unix time. System TLS trust evaluation remains unchanged. This avoids relying on the baseline's newer certificate convenience selector.
- `LBSync` retains first-sync notification baseline, unread tracking and main-queue change notifications. Dock badges use AppKit. Background refresh is `NSBackgroundActivityScheduler` (15-minute interval, system-controlled timing), NOT an iOS BGTask or a guarantee to run after app termination. The application shell owns notification authorization and the UserNotifications delegate for click-to-open routing.

## Compile sources

Compile these ten Core translation units with ARC/modules and macOS 14 deployment target:

```text
Sources/LongBlog/Core/LBAPI.m
Sources/LongBlog/Core/LBEnv.m
Sources/LongBlog/Core/LBMarkdown.m
Sources/LongBlog/Core/LBMdStore.m
Sources/LongBlog/Core/LBMemosClient.m
Sources/LongBlog/Core/LBMemosDiskCache.m
Sources/LongBlog/Core/LBPlatform.m
Sources/LongBlog/Core/LBSite.m
Sources/LongBlog/Core/LBSync.m
Sources/LongBlog/Core/LBText.m
```

Also compile the UI agent's `Sources/LongBlog/UI/LBUIBridge.m` and any other parent/reader Objective-C sources. Headers are imported once through the bridging umbrella. CommonCrypto is supplied by macOS libSystem; no separate CommonCrypto framework is needed.

From the repository root, the Core fixture can be built natively with:

```sh
xcrun clang -fobjc-arc -fmodules -mmacosx-version-min=14.0 \
  -I Sources/LongBlog/Core -I Sources/LongBlog/UI \
  Sources/LongBlog/Core/*.m Sources/LongBlog/UI/*.m tests/CoreFixtures.m \
  -framework Foundation -framework AppKit -framework Security \
  -framework UserNotifications -framework UniformTypeIdentifiers -framework WebKit \
  -o /tmp/longblog-core-fixtures
/tmp/longblog-core-fixtures
```

The parent may equivalently link `tests/CoreFixtures.m` with all already-built ObjC objects. Do not include the Swift app entry point in the fixture executable.

## Verification and limits

- Executed the original baseline's offline `test_github_reliability`, `test_md_reliability`, and `test_article_revert2152` suites with their production-source globals redirected to the **macOS copies**. Result: **59 tests enumerated, 58 passed, 1 pre-existing environment-dependent skip**. iOS strict-SDK tests were excluded. These tests compile/execute the actual portable C policy functions and check transaction orchestration; their filesystem simulations are not Objective-C runtime tests.
- `tests/CoreFixtures.m` is an actual native executable with assertions for line-preserving dotenv parsing/editing/validation, friend operations, frontmatter escaping/type guards/embedded-HTML byte preservation, terminal DTO and resource-fingerprint boundaries, draft save/rename/date preservation, unsafe paths/symlink rejection and private file permissions. All writes are beneath a UUID-named system temporary directory, cleaned on exit. It deliberately never calls Keychain/client singletons, network APIs, or default article-store initialization. This avoids all real credentials and user notes.
- Fixture preprocessor validation passed with Clang. Core `.h/.m` source audit found no UIKit/mobile controller/image/color types, mobile background-task framework, iOS-only file-protection flags or Documents-directory fallback.
- This environment has no macOS SDK, so Objective-C/AppKit runtime fixture execution, actual xcrun/Swift compilation, signing/Keychain authorization, sandbox bookmark persistence and real-network integration remain for the parent's macOS CI. They are not claimed as locally verified.
- Legacy Markdown conversion intentionally preserves baseline behavior and is not an HTML sanitizer/CommonMark implementation. Use the dedicated isolated Reader for untrusted previews. Frontmatter remains the original supported subset, not a general YAML parser. Resource URL lookup is intentionally attachment-only (`assets/...` or legacy `/trilium-assets/...`), not an arbitrary local-file resolver.
- UI-local file IO may run on a serialized utility queue; coordinate it with folder changes and remote operations. Existing synchronous save APIs do not acquire a new cross-thread global editor mutex.
- No real notes, real service endpoints, existing Keychain items, Git remote operations, or commits were touched during this port. Temporary port/verification scripts were removed from Core after verification.

