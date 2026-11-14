#import <Foundation/Foundation.h>

// Internal, non-secret namespace. All mutable state is main-queue confined;
// file IO runs on one utility serial queue. URLs are borrowed, never UI-owned.
@interface LBMemosDiskCache : NSObject
@property (nonatomic, readonly) NSNumber *userID;
@property (nonatomic, readonly) NSDictionary<NSString *, NSArray *> *snapshots;
+ (NSString *)fingerprint:(NSDictionary *)resource;
// Private protected binding uses SHA256(base + SHA256(exact credential)); no
// plaintext credential is persisted. Loading a binding NEVER validates writes.
+ (void)loadBindingForBase:(NSString *)base token:(NSString *)token done:(void (^)(NSNumber *uid))done;
+ (void)saveBindingForBase:(NSString *)base token:(NSString *)token userID:(NSNumber *)uid done:(void (^)(NSError *error))done;
+ (void)revokeBindingForBase:(NSString *)base token:(NSString *)token;
- (instancetype)initWithBase:(NSString *)canonicalBase userID:(NSNumber *)userID;
// Retire this instance immediately without deleting persistent data. Instances
// for the same namespace share one serial IO queue across reset/replacement.
- (void)invalidate;
- (void)load:(void (^)(NSError *error))done;
- (void)replaceState:(NSString *)state rows:(NSArray *)rows done:(void (^)(NSError *error))done;
// Atomic two-state commit; prune only if this commit succeeds.
- (void)reconcileNormal:(NSArray *)normal archived:(NSArray *)archived done:(void (^)(NSError *error))done;
- (void)patchMemo:(NSDictionary *)memo deletedID:(NSNumber *)identifier done:(void (^)(NSError *error))done;
- (NSURL *)resourceURL:(NSDictionary *)resource;
- (void)invalidateResource:(NSDictionary *)resource done:(void (^)(void))done;
- (void)checkCapacityForResource:(NSDictionary *)resource done:(void (^)(NSError *error))done;
// Takes ownership of the staging file even on failure; atomically installs it.
- (void)installFile:(NSURL *)file resource:(NSDictionary *)resource isCurrent:(BOOL (^)(void))isCurrent done:(void (^)(NSURL *url, NSError *error))done;
@end
