#import "LBMemosDiskCache.h"
#import <CommonCrypto/CommonDigest.h>
#import "LBPlatform.h"
#import <math.h>

static const unsigned long long LBCFileCap = 32ULL * 1024 * 1024;
static const unsigned long long LBCMetadataCap = 32ULL * 1024 * 1024;
// No silent eviction or arbitrary total quota: ALL originals are requested.
// Reserve space for concurrent staging/atomic metadata replacement.
static const unsigned long long LBCReserve = 72ULL * 1024 * 1024;
static NSError *LBCErr(NSString *message) {
  return [NSError errorWithDomain:@"LBMemosCacheError" code:1101 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSString *LBCHash(NSString *s) {
  NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding]; unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(d.bytes, (CC_LONG)d.length, digest); NSMutableString *out = [NSMutableString string];
  for (NSUInteger i = 0; i < sizeof(digest); i++) [out appendFormat:@"%02x", digest[i]];
  return out;
}
static BOOL LBCProtect(NSURL *url) { return LBProtectLocalURL(url, NULL); }

static BOOL LBCInteger(id value, BOOL positive) {
  if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
  double n = [value doubleValue];
  return isfinite(n) && floor(n) == n && n >= (positive ? 1 : 0) && n <= 9007199254740991.0;
}
static BOOL LBCRows(id rows, NSNumber *uid, NSString *state) {
  if (![rows isKindOfClass:NSArray.class] || [rows count] > 10000 || ![@[@"NORMAL", @"ARCHIVED"] containsObject:state]) return NO;
  NSMutableSet *ids = [NSMutableSet set];
  for (id row in rows) {
    if (![row isKindOfClass:NSDictionary.class] || ![row[@"creatorId"] isEqual:uid] || ![row[@"rowStatus"] isEqual:state] || !LBCInteger(row[@"id"], YES) || [ids containsObject:row[@"id"]] || ![row[@"content"] isKindOfClass:NSString.class] || ![row[@"resourceList"] isKindOfClass:NSArray.class] || ![@[@"PRIVATE", @"PROTECTED", @"PUBLIC"] containsObject:row[@"visibility"]] || ![row[@"pinned"] isKindOfClass:NSNumber.class] || !([row[@"pinned"] isEqual:@0] || [row[@"pinned"] isEqual:@1])) return NO;
    for (NSString *field in @[@"createdTs", @"updatedTs", @"displayTs"]) if (!LBCInteger(row[field], NO)) return NO;
    [ids addObject:row[@"id"]]; NSMutableSet *resources = [NSMutableSet set];
    for (id resource in row[@"resourceList"]) {
      if (![resource isKindOfClass:NSDictionary.class] || ![resource[@"creatorId"] isEqual:uid] || !LBCInteger(resource[@"createdTs"], NO) || ![LBMemosDiskCache fingerprint:resource] || [resources containsObject:resource[@"id"]]) return NO;
      [resources addObject:resource[@"id"]];
    }
  }
  return YES;
}
@interface LBMemosDiskCache ()
@property (nonatomic, readwrite) NSNumber *userID;
@property (nonatomic, readwrite) NSDictionary<NSString *, NSArray *> *snapshots;
@property NSURL *root;
@property NSURL *files;
@property NSURL *metadata;
@property dispatch_queue_t io;
@property NSMutableSet<NSString *> *available;
@property BOOL metadataDirty;
@property NSUInteger revision;
// Atomic: main retires an instance while namespace IO may be executing.
@property (atomic) BOOL invalidated;
@end
@implementation LBMemosDiskCache
+ (dispatch_queue_t)queueForNamespace:(NSString *)namespace {
  static NSMutableDictionary<NSString *, dispatch_queue_t> *queues;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ queues = [NSMutableDictionary dictionary]; });
  // Process-wide registry: serializes old/new instances of the SAME root.
  // No waiting on IO/main here; install's main validation cannot deadlock.
  @synchronized (queues) {
    dispatch_queue_t queue = queues[namespace];
    if (!queue) {
      queue = dispatch_queue_create("com.longblog.memos.cache.io", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
      queues[namespace] = queue;
    }
    return queue;
  }
}
- (void)invalidate {
  NSAssert(NSThread.isMainThread, @"Main queue confinement");
  self.invalidated = YES;
  self.snapshots = @{}; [self.available removeAllObjects];
}
- (NSError *)lifecycleError {
  return self.invalidated ? LBCErr(@"缓存上下文已改变，已取消旧账户的本地操作。") : nil;
}
+ (dispatch_queue_t)bindingQueue {
  static dispatch_queue_t queue; static dispatch_once_t once;
  dispatch_once(&once, ^{ queue = dispatch_queue_create("com.longblog.memos.cache.binding", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
  return queue;
}
+ (NSURL *)bindingURLForBase:(NSString *)base token:(NSString *)token {
  if (!base.length || !token.length) return nil;
  NSURL *support = LBApplicationSupportURL();
  NSURL *directory = [support URLByAppendingPathComponent:@"MemosCacheBindings-v1" isDirectory:YES];
  NSString *key = LBCHash([NSString stringWithFormat:@"%@\n%@", base, LBCHash(token)]);
  return [directory URLByAppendingPathComponent:[key stringByAppendingString:@".json"]];
}
+ (void)loadBindingForBase:(NSString *)base token:(NSString *)token done:(void (^)(NSNumber *))done {
  NSURL *url = [self bindingURLForBase:base token:token];
  dispatch_async([self bindingQueue], ^{
    NSDictionary *attrs = url ? [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL] : nil;
    id raw = nil;
    if ([attrs[NSFileType] isEqual:NSFileTypeRegular] && [attrs[NSFileSize] unsignedLongLongValue] <= 1024) {
      NSData *data = [NSData dataWithContentsOfURL:url options:0 error:NULL]; raw = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    }
    NSNumber *uid = [raw isKindOfClass:NSDictionary.class] && [raw[@"version"] isEqual:@1] && [raw[@"userID"] isKindOfClass:NSNumber.class] ? raw[@"userID"] : nil;
    if (uid && (CFGetTypeID((__bridge CFTypeRef)uid) == CFBooleanGetTypeID() || uid.doubleValue < 1 || uid.doubleValue > 9007199254740991.0 || uid.doubleValue != (double)uid.unsignedLongLongValue)) uid = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ done(uid); });
  });
}
+ (void)saveBindingForBase:(NSString *)base token:(NSString *)token userID:(NSNumber *)uid done:(void (^)(NSError *))done {
  NSURL *url = [self bindingURLForBase:base token:token];
  dispatch_async([self bindingQueue], ^{
    NSURL *directory = url.URLByDeletingLastPathComponent; NSFileManager *fm = NSFileManager.defaultManager;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"userID":uid} options:0 error:NULL];
    BOOL ok = url && [fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL] && LBCProtect(directory) && [data writeToURL:url options:NSDataWritingAtomic error:NULL] && LBCProtect(url);
    NSError *error = ok ? nil : LBCErr(@"离线身份绑定保存失败，下次启动需联网验证后读取缓存。");
    dispatch_async(dispatch_get_main_queue(), ^{ done(error); });
  });
}
+ (void)revokeBindingForBase:(NSString *)base token:(NSString *)token {
  NSURL *url = [self bindingURLForBase:base token:token]; if (!url) return;
  dispatch_async([self bindingQueue], ^{ [NSFileManager.defaultManager removeItemAtURL:url error:NULL]; });
}
+ (NSString *)fingerprint:(NSDictionary *)r {
  // Legacy server uses second timestamps; equal metadata cannot prove equal
  // bytes if the server replaces content within the same second/size/name.
  if (![r isKindOfClass:NSDictionary.class]) return nil;
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *key in @[@"id", @"creatorId", @"size", @"updatedTs", @"type", @"filename"]) {
    id v = r[key]; if (!v || v == NSNull.null) return nil;
    if ([key isEqual:@"type"] || [key isEqual:@"filename"]) { if (![v isKindOfClass:NSString.class]) return nil; }
    else if (!LBCInteger(v, [key isEqual:@"id"] || [key isEqual:@"creatorId"])) return nil;
    [parts addObject:v];
  }
  if (![r[@"id"] unsignedLongLongValue] || ![r[@"creatorId"] unsignedLongLongValue]) return nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:parts options:0 error:NULL];
  return data ? LBCHash([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]) : nil;
}
- (instancetype)initWithBase:(NSString *)base userID:(NSNumber *)uid {
  if ((self = [super init])) {
    _userID = uid; _snapshots = @{}; _available = [NSMutableSet set];
    _io = [self.class queueForNamespace:LBCHash([NSString stringWithFormat:@"%@\n%@", base, uid])];
    NSURL *support = LBApplicationSupportURL();
    NSURL *parent = [support URLByAppendingPathComponent:@"MemosCache-v1" isDirectory:YES];
    _root = [parent URLByAppendingPathComponent:LBCHash([NSString stringWithFormat:@"%@\n%@", base, uid]) isDirectory:YES];
    _files = [_root URLByAppendingPathComponent:@"originals" isDirectory:YES];
    _metadata = [_root URLByAppendingPathComponent:@"snapshot.json"];
  } return self;
}
- (NSError *)prepare {
  if (self.invalidated) return [self lifecycleError];
  NSFileManager *fm = NSFileManager.defaultManager;
  if (![fm createDirectoryAtURL:self.files withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL] || !LBCProtect(self.root.URLByDeletingLastPathComponent) || !LBCProtect(self.root) || !LBCProtect(self.files)) return LBCErr(@"无法创建受保护的本地缓存，请检查存储空间或解锁设备。");
  return nil;
}
- (NSURL *)URLForResource:(NSDictionary *)resource {
  NSString *key = [self.class fingerprint:resource];
  if (!key) return nil;
  NSString *ext = [resource[@"filename"] pathExtension].lowercaseString;
  NSCharacterSet *bad = NSCharacterSet.alphanumericCharacterSet.invertedSet;
  // Keep only a short ASCII extension for native QuickLook/media type sniffing;
  // no attachment basename, remote path, token or account name enters paths.
  if (!ext.length || ext.length > 12 || [ext rangeOfCharacterFromSet:bad].location != NSNotFound || ![ext canBeConvertedToEncoding:NSASCIIStringEncoding]) ext = @"blob";
  return [self.files URLByAppendingPathComponent:[key stringByAppendingPathExtension:ext]];
}
- (void)load:(void (^)(NSError *))done {
  dispatch_async(self.io, ^{
    NSError *error = [self prepare]; NSDictionary *snapshot = @{}; NSMutableSet *available = [NSMutableSet set];
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:self.metadata.path error:NULL];
    if (!error && attrs) {
      if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || [attrs[NSFileSize] unsignedLongLongValue] > LBCMetadataCap) error = LBCErr(@"本地缓存索引无效，请重新同步。");
      else {
        NSData *data = [NSData dataWithContentsOfURL:self.metadata options:0 error:NULL];
        id raw = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([raw isKindOfClass:NSDictionary.class] && [raw[@"version"] isEqual:@1] && [raw[@"userID"] isEqual:self.userID] && [raw[@"states"] isKindOfClass:NSDictionary.class]) {
          NSMutableDictionary *valid = [NSMutableDictionary dictionary];
          for (NSString *state in @[@"NORMAL", @"ARCHIVED"]) {
            id rows = raw[@"states"][state];
            if (rows) { if (!LBCRows(rows, self.userID, state)) { error = LBCErr(@"本地缓存账户或格式校验失败，请重新同步。"); break; } valid[state] = rows; }
          }
          if (!error) snapshot = valid;
        } else error = LBCErr(@"本地缓存索引不可读，请重新同步。");
      }
    }
    if (!error) for (NSArray *rows in snapshot.allValues) for (NSDictionary *memo in rows) for (NSDictionary *r in memo[@"resourceList"]) {
      NSString *key = [self.class fingerprint:r]; NSURL *url = [self URLForResource:r];
      NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL];
      NSURL *invalid = [self.files URLByAppendingPathComponent:[key stringByAppendingString:@".invalid"]];
      if (![NSFileManager.defaultManager fileExistsAtPath:invalid.path] && [a[NSFileType] isEqual:NSFileTypeRegular] && [a[NSFileSize] isEqual:r[@"size"]] && [a[NSFileSize] unsignedLongLongValue] <= LBCFileCap) [available addObject:key];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ NSError *finalError = [self lifecycleError] ?: error; if (!finalError) { self.snapshots = snapshot; self.available = available; } done(finalError); });
  });
}
- (void)commit:(NSDictionary *)states prune:(BOOL)prune done:(void (^)(NSError *))done {
  // Invocations are main-queue serialized; snapshots are optimistic in-memory,
  // durable writes ordered on io. A disk error remains visible to the caller.
  if (self.invalidated) { done([self lifecycleError]); return; }
  BOOL writeNeeded = self.metadataDirty || ![self.snapshots isEqual:states];
  self.snapshots = states; self.metadataDirty = YES; NSUInteger revision = ++self.revision;
  dispatch_async(self.io, ^{
    NSError *error = [self prepare];
    if (!error && writeNeeded) {
      NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"userID":self.userID, @"states":states} options:0 error:NULL];
      if (self.invalidated) error = [self lifecycleError];
      if (!error && (!data || data.length > LBCMetadataCap || ![data writeToURL:self.metadata options:NSDataWritingAtomic error:NULL] || !LBCProtect(self.metadata))) error = LBCErr(@"正文缓存保存失败，请检查存储空间后重新同步。");
    }
    NSMutableSet *removed = [NSMutableSet set];
    if (self.invalidated) error = [self lifecycleError];
    if (!error && prune) {
      NSMutableSet *keep = [NSMutableSet set];
      for (NSArray *rows in states.allValues) for (NSDictionary *memo in rows) for (NSDictionary *r in memo[@"resourceList"]) [keep addObject:[self.class fingerprint:r]];
      NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.files includingPropertiesForKeys:nil options:0 error:NULL];
      for (NSURL *url in files) {
        if (self.invalidated) { error = [self lifecycleError]; break; }
        NSString *key = url.lastPathComponent.stringByDeletingPathExtension;
        if (![keep containsObject:key]) { if ([NSFileManager.defaultManager removeItemAtURL:url error:NULL]) [removed addObject:key]; else error = LBCErr(@"过期附件本地清理失败，请重试同步。"); }
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ NSError *finalError = [self lifecycleError] ?: error; if (!self.invalidated) { [self.available minusSet:removed]; if (revision == self.revision && !error) self.metadataDirty = NO; } done(finalError); });
  });
}
- (void)replaceState:(NSString *)state rows:(NSArray *)rows done:(void (^)(NSError *))done {
  if (self.invalidated) { done([self lifecycleError]); return; }
  if (!LBCRows(rows, self.userID, state)) { done(LBCErr(@"缓存快照账户或格式无效。")); return; }
  NSMutableDictionary *states = [self.snapshots mutableCopy]; states[state] = [rows copy];
  if (!self.metadataDirty && [self.snapshots isEqual:states]) { done(nil); return; }
  [self commit:states prune:NO done:done];
}
- (void)reconcileNormal:(NSArray *)normal archived:(NSArray *)archived done:(void (^)(NSError *))done {
  if (self.invalidated) { done([self lifecycleError]); return; }
  if (!LBCRows(normal, self.userID, @"NORMAL") || !LBCRows(archived, self.userID, @"ARCHIVED")) { done(LBCErr(@"完整缓存快照账户或状态无效。")); return; }
  NSMutableSet *ids = [NSMutableSet setWithArray:[normal valueForKey:@"id"]];
  [ids intersectSet:[NSSet setWithArray:[archived valueForKey:@"id"]]];
  if (ids.count) { done(LBCErr(@"同步期间记录状态发生变化，请重新同步。")); return; }
  [self commit:@{@"NORMAL":[normal copy], @"ARCHIVED":[archived copy]} prune:YES done:done];
}
- (void)patchMemo:(NSDictionary *)memo deletedID:(NSNumber *)identifier done:(void (^)(NSError *))done {
  if (self.invalidated) { done([self lifecycleError]); return; }
  NSMutableDictionary *states = [NSMutableDictionary dictionary];
  NSNumber *target = identifier ?: memo[@"id"];
  for (NSString *state in @[@"NORMAL", @"ARCHIVED"]) {
    NSArray *old = self.snapshots[state]; if (!old) continue;
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *row in old) if (![row[@"id"] isEqual:target]) [rows addObject:row];
    if (memo && [memo[@"rowStatus"] isEqual:state]) [rows addObject:memo];
    states[state] = rows;
  }
  // Never claim a partial single write is a complete previously absent state.
  [self commit:states prune:NO done:done];
}
- (NSURL *)resourceURL:(NSDictionary *)resource {
  NSString *key = [self.class fingerprint:resource];
  return !self.invalidated && key && [resource[@"creatorId"] isEqual:self.userID] && [self.available containsObject:key] ? [self URLForResource:resource] : nil;
}
- (NSError *)capacityErrorForSize:(unsigned long long)size {
  if (size > LBCFileCap) return LBCErr(@"部分附件超过 32 MiB 安全上限，未缓存；不会显示为全部完成。");
  NSDictionary *space = [NSFileManager.defaultManager attributesOfFileSystemForPath:self.root.path error:NULL];
  NSNumber *free = space[NSFileSystemFreeSize];
  if (!free || free.unsignedLongLongValue < size + LBCReserve) return LBCErr(@"本地空间不足，部分附件未缓存；释放空间后请重试。");
  return nil;
}
- (void)checkCapacityForResource:(NSDictionary *)resource done:(void (^)(NSError *))done {
  dispatch_async(self.io, ^{
    NSError *error = [self prepare]; if (!error) error = [self capacityErrorForSize:[resource[@"size"] unsignedLongLongValue]];
    dispatch_async(dispatch_get_main_queue(), ^{ done([self lifecycleError] ?: error); });
  });
}
- (void)installFile:(NSURL *)file resource:(NSDictionary *)resource isCurrent:(BOOL (^)(void))isCurrent done:(void (^)(NSURL *, NSError *))done {
  NSString *key = [self.class fingerprint:resource];
  dispatch_async(self.io, ^{
    __block BOOL current = NO;
    // Never hold the IO queue from main. This quick guard grants no IO work
    // to main and rejects an epoch/reset/reconcile that preceded installation.
    if (!self.invalidated) dispatch_sync(dispatch_get_main_queue(), ^{ current = !self.invalidated && isCurrent(); });
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = current ? [self prepare] : LBCErr(@"附件快照已更新，未保存过期下载；请重新同步。");
    NSDictionary *a = [fm attributesOfItemAtPath:file.path error:NULL];
    if (!key || ![resource[@"creatorId"] isEqual:self.userID] || ![a[NSFileType] isEqual:NSFileTypeRegular] || ![a[NSFileSize] isEqual:resource[@"size"]] || [a[NSFileSize] unsignedLongLongValue] > LBCFileCap) error = LBCErr(@"附件实际大小与快照不符，请重新同步后重试。");
    NSURL *destination = key ? [self URLForResource:resource] : nil;
    NSURL *staging = [self.files URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".part"]];
    if (self.invalidated) error = [self lifecycleError];
    if (!error && (![fm moveItemAtURL:file toURL:staging error:NULL] || !LBCProtect(staging))) error = LBCErr(@"附件无法移入受保护的缓存。");
    if (self.invalidated) error = [self lifecycleError];
    if (!error) {
      // Same-volume rename is atomic. replaceItem preserves old bytes on error.
      BOOL exists = [fm fileExistsAtPath:destination.path];
      BOOL ok = exists ? [fm replaceItemAtURL:destination withItemAtURL:staging backupItemName:nil options:0 resultingItemURL:NULL error:NULL] : [fm moveItemAtURL:staging toURL:destination error:NULL];
      if (!ok || !LBCProtect(destination)) error = LBCErr(@"附件缓存保存失败，请检查存储空间后重试。");
    }
    if (!error && !self.invalidated) [fm removeItemAtURL:[self.files URLByAppendingPathComponent:[key stringByAppendingString:@".invalid"]] error:NULL];
    [fm removeItemAtURL:staging error:NULL]; [fm removeItemAtURL:file error:NULL];
    dispatch_async(dispatch_get_main_queue(), ^{ NSError *finalError = [self lifecycleError] ?: error; if (!finalError) [self.available addObject:key]; done(finalError ? nil : destination, finalError); });
  });
}
- (void)invalidateResource:(NSDictionary *)resource done:(void (^)(void))done {
  NSString *key = [self.class fingerprint:resource];
  if (self.invalidated || !key || ![resource[@"creatorId"] isEqual:self.userID]) { done(); return; }
  [self.available removeObject:key];
  dispatch_async(self.io, ^{
    if (self.invalidated) { dispatch_async(dispatch_get_main_queue(), done); return; }
    NSURL *marker = [self.files URLByAppendingPathComponent:[key stringByAppendingString:@".invalid"]];
    [[NSData data] writeToURL:marker options:NSDataWritingAtomic error:NULL]; LBCProtect(marker);
    if (!self.invalidated) [NSFileManager.defaultManager removeItemAtURL:[self URLForResource:resource] error:NULL];
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.invalidated) [self.available removeObject:key]; done(); });
  });
}
@end
