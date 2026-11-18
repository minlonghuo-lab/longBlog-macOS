// LongBlog Inbox — shared declarations.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const LBDefaultAPIBase;
extern NSString *const LBRefreshTaskID;
extern NSString *const LBSyncDidChange;        // posted on main queue after every sync
extern NSString *const LBOpenSessionRequest;   // userInfo[@"sessionId"]

#pragma mark - Data
@interface LBMessage : NSObject
@property (nonatomic, copy) NSString *mid, *sender, *text;
@property (nonatomic) long long createdAt;
@property (nonatomic) NSInteger sequence;
@property (nonatomic) BOOL pending, failed;
+ (nullable instancetype)fromJSON:(NSDictionary *)d;
- (BOOL)fromVisitor;
@end

@interface LBSession : NSObject
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic) long long createdAt, expiresAt;
@property (nonatomic) BOOL archived;
@property (nonatomic) long long archivedAt, archiveExpiresAt;
@property (nonatomic) NSInteger sequence, lastUserSequence;
@property (nonatomic, strong) LBMessage *last;
+ (nullable instancetype)fromJSON:(NSDictionary *)d;
- (NSString *)shortId;
@end

#pragma mark - API (owner key lives in the Keychain only)
@interface LBAPI : NSObject
+ (instancetype)shared;
@property (nonatomic, copy) NSString *baseURL;
@property (nonatomic, copy, nullable) NSString *ownerKey;
@property (nonatomic, readonly) NSUInteger connectionRevision;
- (void)noteCredentialChange;
- (BOOL)configured;
- (void)fetchSessions:(void (^)(NSArray<LBSession *> *_Nullable s, NSError *_Nullable e))done;
- (void)fetchArchivedSessions:(nullable NSString *)cursor
                        done:(void (^)(NSArray<LBSession *> *_Nullable sessions, NSString *_Nullable nextCursor, NSError *_Nullable e))done;
- (void)deleteArchivedSession:(NSString *)sid done:(void (^)(NSError *_Nullable error))done;
- (void)fetchSessionContact:(NSString *)sid done:(void (^)(NSDictionary *_Nullable contact, NSError *_Nullable error))done;
- (void)fetchArchivedMessages:(NSString *)sid after:(NSInteger)cursor
                         done:(void (^)(NSArray<LBMessage *> *_Nullable messages, NSInteger cursor, NSError *_Nullable e))done;
- (void)fetchMessages:(NSString *)sid after:(NSInteger)cursor
                 done:(void (^)(NSArray<LBMessage *> *_Nullable m, NSInteger cursor, NSError *_Nullable e))done;
- (void)reply:(NSString *)sid messageId:(NSString *)mid text:(NSString *)text
         done:(void (^)(LBMessage *_Nullable m, NSError *_Nullable e))done;
+ (NSString *)randomHex:(NSUInteger)bytes;
@end

#pragma mark - Sync engine: polling, unread state, local notifications
@interface LBSync : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSArray<LBSession *> *sessions;
@property (nonatomic, readonly, nullable) NSError *lastError;
@property (nonatomic, readonly, nullable) NSDate *lastSync;
@property (nonatomic, copy, nullable) NSString *activeSession; // no banners for the open chat
- (void)refresh:(nullable void (^)(BOOL newData))done;
- (BOOL)isUnread:(LBSession *)s;
- (NSInteger)unreadCount;
- (void)markRead:(NSString *)sid upTo:(NSInteger)userSequence;
- (void)startForegroundPolling;
- (void)stopForegroundPolling;
- (void)scheduleBackgroundRefresh;
- (void)resetBaseline;
@end

NSString *LBRelativeTime(long long ms);
NSString *LBRemaining(long long expiresAtMs);

#pragma mark - Site management (dashboard / posts / shuoshuo / site config)
extern NSString *const LBSiteDataDidChange;

@interface LBKeychain : NSObject
+ (nullable NSString *)get:(NSString *)account;
+ (void)set:(nullable NSString *)value account:(NSString *)account;
@end

/// Non-secret preferences.
@interface LBStore : NSObject
+ (NSString *)siteURL;            // https://huowenlong.com
+ (void)setSiteURL:(NSString *)v;
+ (NSString *)repo;               // owner/name
+ (void)setRepo:(NSString *)v;
+ (NSArray<NSString *> *)certHosts;
+ (void)setCertHosts:(NSString *)commaSeparated;
@end

@interface LBHTTP : NSObject
+ (void)JSON:(NSString *)method url:(NSURL *)url headers:(nullable NSDictionary *)headers body:(nullable NSDictionary *)body
        done:(void (^)(id _Nullable json, NSInteger status, NSError *_Nullable e))done;
+ (void)certificateExpiry:(NSString *)host done:(void (^)(NSDate *_Nullable expiry, NSError *_Nullable e))done;
+ (void)image:(NSURL *)url done:(void (^)(NSImage *_Nullable img))done;
@end

@interface LBGitHub : NSObject
+ (instancetype)shared;
+ (void)noteCredentialChange;
@property (nonatomic, copy, nullable) NSString *token; // Keychain
- (BOOL)configured;
/// Frozen repository + Keychain credential for an entire asynchronous operation.
- (instancetype)initWithRepository:(NSString *)repository;
@property (nonatomic, readonly) NSString *repository;
- (void)getData:(NSString *)path ref:(NSString *)ref done:(void (^)(NSData *_Nullable data, NSString *_Nullable sha, NSError *_Nullable e))done;
- (void)getBlobData:(NSString *)sha done:(void (^)(NSData *_Nullable data, NSError *_Nullable e))done;
/// Immutable main snapshot: head, treeSHA, files (path -> Git tree entry). Truncation is an error.
- (void)articleSnapshot:(void (^)(NSDictionary *_Nullable snapshot, NSError *_Nullable e))done;
/// NSData writes / NSNull deletions. Creates blobs, one tree + commit, then non-force ref update.
- (void)commitChanges:(NSDictionary<NSString *, id> *)changes snapshot:(NSDictionary *)snapshot message:(NSString *)message
                 done:(void (^)(NSDictionary *_Nullable result, NSError *_Nullable e))done;
/// prepared runs synchronously on main BEFORE PATCH. Atomically persist pending
/// {repository,credentialID,base,commit,shas}; return NO to stop without updating the ref.
/// Pending must survive errors/account changes until a read-only recovery confirms it.
- (void)commitChanges:(NSDictionary<NSString *, id> *)changes snapshot:(NSDictionary *)snapshot message:(NSString *)message
             prepared:(BOOL (^_Nullable)(NSDictionary *pending, NSError *_Nullable *_Nullable error))prepared
                 done:(void (^)(NSDictionary *_Nullable result, NSError *_Nullable e))done;
/// Required before recovering persisted pending. Random Keychain credentialID
/// binds to the original token era without persisting the token or its hash.
/// NO means preserve pending and require manual reconciliation, never replay it.
- (BOOL)matchesPendingIdentity:(NSDictionary *)pending;
/// Pure GET recovery: {state:applied|unchanged|conflict,head}. Applied includes a
/// descendant of desired commit. Unchanged is NOT permission to resend a write.
/// Unknown=-2; identity changed=-999. Never force, rebase or recreate the article.
- (void)confirmCommit:(NSString *)commit base:(NSString *)base
                 done:(void (^)(NSDictionary *_Nullable result, NSError *_Nullable e))done;
- (void)getFile:(NSString *)path ref:(NSString *)ref done:(void (^)(NSString *_Nullable text, NSString *_Nullable sha, NSError *_Nullable e))done;
- (void)getFile:(NSString *)path done:(void (^)(NSString *_Nullable text, NSString *_Nullable sha, NSError *_Nullable e))done;
- (void)putFile:(NSString *)path text:(NSString *)text sha:(NSString *)sha message:(NSString *)message
           done:(void (^)(NSString *_Nullable commitSha, NSError *_Nullable e))done;
- (void)deleteFile:(NSString *)path sha:(nullable NSString *)sha message:(NSString *)message
              done:(void (^)(NSError *_Nullable e))done;
- (void)headCommit:(void (^)(NSDictionary *_Nullable commit, NSError *_Nullable e))done;
@end

@interface LBEnvLine : NSObject
@property (nonatomic, copy) NSString *raw;
@property (nonatomic, copy, nullable) NSString *key, *value;
@end

/// Line-preserving editor for the site's `.env` (dotenv as read by Vite).
/// Untouched lines are written back byte-for-byte; edited lines become KEY=<quoted>.
@interface LBEnvFile : NSObject
+ (instancetype)parse:(NSString *)text;
@property (nonatomic, readonly) NSMutableArray<LBEnvLine *> *lines;
- (nullable NSString *)valueFor:(NSString *)key;
/// Returns an error message, or nil on success.
- (nullable NSString *)updateValue:(NSString *)value forKey:(NSString *)key;
- (NSString *)serialize;
- (NSDictionary<NSString *, NSString *> *)values;
/// [{title, help, keys:[{key, help}], friends:BOOL}]
- (NSArray<NSDictionary *> *)sections;
- (NSArray<NSNumber *> *)friendIndexes;
- (NSInteger)addFriend;
- (void)removeFriend:(NSInteger)index;
- (NSArray<NSString *> *)validate;
+ (NSString *)labelFor:(NSString *)key;
+ (BOOL)isBoolean:(NSString *)key;
@end

@interface LBSiteData : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly, nullable) NSArray<NSDictionary *> *posts;   // newest first
@property (nonatomic, readonly, nullable) NSArray<NSDictionary *> *memos;   // newest first
@property (nonatomic, readonly, nullable) NSDictionary *memosVersion;
@property (nonatomic, readonly, nullable) NSString *envText, *envSha;
@property (nonatomic, readonly, nullable) NSDictionary *head;   // sha, message, date, url
@property (nonatomic, readonly, nullable) NSDictionary *build;  // commit, builtAt
@property (nonatomic, readonly) NSDictionary<NSString *, id> *certs; // host -> NSDate | NSError
@property (nonatomic, readonly) NSDictionary<NSString *, NSError *> *errors;
- (void)resetConnection;
- (void)refreshAll:(nullable void (^)(void))done;
- (void)refreshPosts:(nullable void (^)(void))done;
- (void)refreshMemos:(nullable void (^)(void))done;
- (void)refreshEnv:(nullable void (^)(void))done;
- (void)refreshDeploy:(nullable void (^)(void))done;
- (void)didCommitEnv:(NSString *)text commit:(NSString *)commitSha;
/// Human-readable deploy state; *pending is YES while a build is expected.
- (NSString *)deployState:(NSColor *__nullable *__nullable)color pending:(BOOL *__nullable)pending;
@end

NSString *LBDateText(NSDate *date);

NS_ASSUME_NONNULL_END
