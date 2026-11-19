#import "LB.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const LBMdStoreDidChange;

@interface LBMdStore : NSObject

+ (instancetype)shared;
/// Independent explicitly supplied local workspace; no defaults, Keychain,
/// bookmarks, or network are touched. Useful for offline tooling and fixtures.
/// The directory must exist and be a real directory, not a symlink. The caller
/// owns any required external security scope for this instance's lifetime.
- (nullable instancetype)initWithLocalFolderURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;

/// Completion is always on main. Concurrent sync callers coalesce; publish/delete while busy fail with 409.
/// Downloads preserve untracked local files, drafts and locally modified article/sidecar/assets;
/// missing never-tracked assets are still filled for old seeded articles. Remote deletions remove
/// only clean published mirrors; drafts and edits survive. Repository ownership is folder-scoped.
- (nullable NSString *)lastPulledHead; // nil for an unsafe or pending workspace
- (void)syncFromGitHub:(void (^)(NSError * _Nullable error))done;
- (void)forceSyncFromGitHub:(void (^)(NSError * _Nullable error))done;
- (void)publishArticle:(NSString *)noteId done:(void (^)(NSError * _Nullable error))done;
- (void)unpublishArticle:(NSString *)noteId done:(void (^)(NSError * _Nullable error))done;
/// Deletes remote md + html atomically before local removal. Never deletes shared attachments.
- (void)deleteArticle:(NSString *)noteId done:(void (^)(NSError * _Nullable error))done;

/// Root directory where articles are stored (standard .md files).
/// If a security-scoped bookmark is configured, resolves and accesses the external folder;
/// otherwise defaults to the Application Support/longBlog/Posts directory.
@property (nonatomic, readonly) NSURL *articlesFolderURL;

/// Human-readable folder name (e.g. "Posts" or custom folder name).
@property (nonatomic, readonly) NSString *folderDisplayName;

/// Whether an external folder was selected via a user-approved macOS folder picker.
@property (nonatomic, readonly) BOOL isCustomFolder;

/// Save a security-scoped bookmark for an external folder picked by user.
- (BOOL)setFolderURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)outError;

/// Reset back to internal sandbox folder.
- (void)resetFolderToDefault;

/// Scan and return all articles found in articlesFolderURL.
/// Each item is a dictionary with id, slug, title, summary, manualSummary,
/// publish (BOOL), createdAt/updatedAt/publishedAt (ms) and corresponding *String fields,
/// tags, pinned, physical filePath/htmlPath, hasHTMLSidecar. Unpublished never-published
/// notes have publishedAt=0; ordering uses publishedAt or createdAt descending, then ID.
- (NSArray<NSDictionary *> *)listArticles;
/// UI-only metadata index in Application Support. The editor always opens the actual file.
- (NSArray<NSDictionary *> *)listArticlesWithIndexAtURL:(nullable NSURL *)indexURL;
- (nullable NSArray<NSDictionary *> *)cachedArticleListAtURL:(NSURL *)indexURL;
/// Independent read-only scan for background dashboard work. Owns its security
/// scope for the entire scan; never renews or overwrites the selected bookmark.
+ (NSArray<NSDictionary *> *)listArticlesForFolderBookmark:(nullable NSData *)bookmark;

/// Load full article including bodyFormat (default markdown). bodyFormat: html
/// returns the SAME embedded .md body as html; it is not sent through marked.
/// hasHTMLSidecar stays NO and htmlPath empty for embedded HTML. Format is explicit
/// and retained by save/publish; tags in the body never implicitly change format.
/// singleSourceVersion: 1 blocks legacy sync/sidecar resurrection. Old pending
/// transactions require operator review; new single-source pending can recover.
- (nullable NSDictionary *)loadArticle:(NSString *)noteId;

/// Save to 草稿|已发布/<safe title_ID>/index.md. createdAt is written once; updatedAt
/// changes on save; first publishedAt is retained and only set by successful publishing.
- (BOOL)saveArticleWithId:(NSString *)noteId
                    title:(NSString *)title
                 markdown:(NSString *)markdown
                  summary:(nullable NSString *)summary
                  publish:(BOOL)publish
                     tags:(nullable NSArray<NSString *> *)tags
                    error:(NSError * _Nullable * _Nullable)outError;

- (BOOL)saveArticleWithId:(NSString *)noteId
                    title:(NSString *)title
                 markdown:(NSString *)markdown
                  summary:(nullable NSString *)summary
                  publish:(BOOL)publish
                     tags:(nullable NSArray<NSString *> *)tags
         expectedRevision:(NSString *)revision
                savedPost:(NSDictionary * _Nullable * _Nullable)savedPost
                    error:(NSError * _Nullable * _Nullable)outError;

/// Delete local <noteId>.md (and sidecar <noteId>.html if present).
- (BOOL)deleteArticleWithId:(NSString *)noteId error:(NSError * _Nullable * _Nullable)outError;

/// Return local assets directory for a given note (creates it if needed).
- (NSURL *)assetsFolderForNote:(NSString *)noteId;
/// Canonical repository paths map to the current per-article physical directory.
/// Read-only: rejects traversal, symlinks and non-regular files. No directory creation.
- (nullable NSURL *)resourceURLForLocalPath:(NSString *)path;
- (nullable NSURL *)readOnlyAssetURLForNote:(NSString *)noteId filename:(NSString *)filename;
- (nullable NSURL *)articleDirectoryURLForNote:(NSString *)noteId;
/// Verified stage + manifest layout migration; identical existing packages may be
/// adopted, differing packages are never overwritten. Originals remain in hidden
/// backups. Offline tools/migrate_workspace_md.py handles the lossless single-body
/// migration with dry-run, complete journal, verified staging and rollback.
- (BOOL)migrateToArticleFoldersWithError:(NSError * _Nullable * _Nullable)error;

/// Local staging workflow: stage unpublish/publish without immediately calling GitHub API.
- (BOOL)stageUnpublishArticle:(NSString *)noteId error:(NSError * _Nullable * _Nullable)outError;
- (BOOL)stagePublishArticle:(NSString *)noteId error:(NSError * _Nullable * _Nullable)outError;

/// List all locally staged article changes (unpublish, publish, update) against GitHub baseline.
- (NSArray<NSDictionary *> *)stagedArticles;
/// Same as stagedArticles but reuses an already-scanned listArticles result (safe off the main thread).
- (NSArray<NSDictionary *> *)stagedArticlesForArticles:(NSArray<NSDictionary *> *)articles;

/// Commit all staged articles to GitHub in a single atomic commit.
- (void)commitStagedArticles:(NSArray<NSDictionary *> *)staged
                     message:(nullable NSString *)message
                        done:(void (^)(NSError * _Nullable error))done;

/// Revert ONLY this frozen stagedArticles selection (including its opaque revertGuard).
/// Capture the array BEFORE presenting confirmation; changed bytes/state/root/repo fail closed.
/// Async, completion on main, shares the articleTask mutex. Read-only GitHub verification;
/// no commits/pushes, pending recovery or remote revert. Restores tracked bytes only when
/// current remote blob SHAs still match confirmed records. Never-published drafts keep
/// body/attachments and only cancel publish. Untracked attachments/sidecars are retained.
/// Verified before/after payloads and a recovery journal remain in .longblog-revert-<UUID>.json;
/// an interrupted/failed apply blocks another revert for manual review (no silent replay).
- (void)revertStagedArticles:(NSArray<NSDictionary *> *)staged
                      done:(void (^)(NSError * _Nullable error))done;

/// Return the current local baseline commit SHA from .longblog-sync.json.
- (nullable NSString *)currentHeadCommit;

/// Generate a unique 12-char base62 noteId that does not collide with any existing file.
- (NSString *)generateUniqueNoteID;

/// Helper: parse frontmatter and body from a Markdown string.
+ (NSDictionary *)parseFrontmatterAndBody:(NSString *)markdown;

/// Helper: serialize frontmatter and body to a Markdown string.
+ (NSString *)serializeFrontmatter:(NSDictionary *)meta body:(NSString *)body;

@end

NS_ASSUME_NONNULL_END
