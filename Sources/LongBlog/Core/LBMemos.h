#import "LB.h"

NS_ASSUME_NONNULL_BEGIN
extern NSString *const LBMemosDidChange;
// Server DTOs retain legacy integer ids/second timestamps, but all values are
// validated at the transport boundary. Never mix these authenticated rows with
// the public LBSiteData mirror.
@interface LBMemosClient : NSObject
+ (instancetype)shared;
@property (nonatomic, copy) NSString *baseURL;
@property (nonatomic, copy, nullable) NSString *token;
@property (nonatomic, readonly, nullable) NSDictionary *user;
@property (nonatomic, readonly) NSUInteger generation;
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, readonly) BOOL configured;
@property (nonatomic, readonly) BOOL authenticationRequired;
- (BOOL)configureBaseURL:(NSString *)base token:(nullable NSString *)token;
- (void)validate:(void (^)(NSDictionary *_Nullable user, NSError *_Nullable error))done;
- (void)listState:(NSString *)state text:(NSString *)text tag:(NSString *)tag offset:(NSUInteger)offset
            done:(void (^)(NSArray<NSDictionary *> *_Nullable rows, BOOL more, NSError *_Nullable error))done;
// Legacy personal snapshot without limit; either the entire validated state or error.
- (void)allState:(NSString *)state text:(NSString *)text tag:(NSString *)tag
           done:(void (^)(NSArray<NSDictionary *> *_Nullable rows, NSError *_Nullable error))done;
// Lightweight check: fetches only 1 latest memo to check if cloud changed before doing full sync.
- (void)checkLatestMemoState:(NSString *)state done:(void (^)(NSDictionary *_Nullable latest, NSError *_Nullable error))done;
- (void)tags:(void (^)(NSArray<NSString *> *_Nullable tags, NSError *_Nullable error))done;
- (void)memo:(NSNumber *)identifier done:(void (^)(NSDictionary *_Nullable memo, NSError *_Nullable error))done;
// original=nil creates; otherwise save checks original against a fresh remote
// copy before PATCH. No atomic server CAS exists; never claim perfect locking.
- (void)saveOriginal:(nullable NSDictionary *)original content:(NSString *)content visibility:(NSString *)visibility
        resourceIDs:(NSArray<NSNumber *> *)ids done:(void (^)(NSDictionary *_Nullable memo, NSError *_Nullable error))done;
- (void)updateMemo:(NSDictionary *)memo fields:(NSDictionary *)fields done:(void (^)(NSDictionary *_Nullable memo, NSError *_Nullable error))done;
// Performs a single DELETE only after verifying the remote row is ARCHIVED.
// Timeouts are outcome-unknown, never automatically repeated.
- (void)deleteArchived:(NSDictionary *)memo done:(void (^)(NSError *_Nullable error))done;
// Upload one file, <=32MiB. Cancellation of the returned task is supported.
- (nullable NSURLSessionTask *)uploadFile:(NSURL *)file filename:(NSString *)filename type:(NSString *)type
    progress:(nullable void (^)(double fraction))progress done:(void (^)(NSDictionary *_Nullable resource, NSError *_Nullable error))done;
- (void)deleteResource:(NSNumber *)identifier done:(void (^)(NSError *_Nullable error))done;
// Only same-origin HTTPS gets the Bearer header; redirects are rejected.
// Returned files are BORROWED protected persistent originals owned by the cache;
// consumers must never delete them. Shared downloads can return nil task so a
// view cannot cancel a transfer used by another view. reset cancels network work.
- (nullable NSURLSessionTask *)downloadResource:(NSDictionary *)resource
    done:(void (^)(NSURL *_Nullable localFile, NSError *_Nullable error))done;
- (void)reset;
// drafts are scoped to connection/account+memo id, protected local storage;
// text/visibility/resourceIDs only, never a token. No automatic publish queue.
- (nullable NSDictionary *)draftForMemo:(nullable NSNumber *)identifier;
- (BOOL)saveDraft:(NSDictionary *)draft forMemo:(nullable NSNumber *)identifier;
- (void)removeDraftForMemo:(nullable NSNumber *)identifier;
@end

NSString *LBMemoVisibility(NSString *value);
NSString *LBMemoPlain(NSString *markdown);
NS_ASSUME_NONNULL_END
