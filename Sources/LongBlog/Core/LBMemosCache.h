#import "LBMemos.h"
NS_ASSUME_NONNULL_BEGIN
extern NSString *const LBMemosCacheDidChange;
@interface LBMemosClient (LocalCache)
// Synchronous protected-cache lookup, only for the verified base/user namespace.
- (nullable NSArray<NSDictionary *> *)cachedState:(NSString *)state;
- (nullable NSURL *)cachedResource:(NSDictionary *)resource;
- (void)invalidateCachedResource:(NSDictionary *)resource;
// Native media transport shares the same explicit 401 invalidation policy.
- (void)requireAuthentication;
// Resource cache stores originals, account-scoped and never in public mirror.
// Called after BOTH complete state snapshots are verified; unchanged originals
// reused, stale/unreferenced cache removed only on a complete successful sync.
- (void)reconcileCacheNormal:(NSArray<NSDictionary *> *)normal archived:(NSArray<NSDictionary *> *)archived;
- (void)prefetchAllResources;
- (NSDictionary *)cacheProgress; // total/completed/failed/running, no private names
@end
NS_ASSUME_NONNULL_END
