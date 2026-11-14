#import "LBMemos.h"
#import "LBMemosCache.h"
#import "LBMemosDiskCache.h"
#import <CommonCrypto/CommonDigest.h>
#import "LBPlatform.h"
#import <math.h>

NSString *const LBMemosCacheDidChange = @"LBMemosCacheDidChange";
NSString *const LBMemosDidChange = @"LBMemosDidChange";
static const NSUInteger LBFileCap = 32 * 1024 * 1024;
static const NSUInteger LBJSONCap = 8 * 1024 * 1024;
static NSString *const LBErrorDomain = @"LBMemosError";
// Codes are stable for UI/tests; errors intentionally contain no server body,
// underlying NSError, request URL, Authorization header or token.
static NSError *LBErr(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:LBErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSError *LBStale(void) { return LBErr(4091, @"连接或数据已改变，请重新加载。"); }
static id LBOnMain(id (^block)(void)) {
  if (NSThread.isMainThread) return block();
  __block id result; dispatch_sync(dispatch_get_main_queue(), ^{ result = block(); }); return result;
}
#define LB_MAIN_RETURN(call) if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ call; }); return; }
static BOOL LBString(id value) { return [value isKindOfClass:NSString.class]; }
static BOOL LBNumber(id value, BOOL positive) {
  if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
  double n = [value doubleValue]; return isfinite(n) && floor(n) == n && n >= (positive ? 1 : 0) && n <= 9007199254740991.0;
}
static BOOL LBBool(id value) {
  return [value isKindOfClass:NSNumber.class] && ([value isEqual:@0] || [value isEqual:@1]);
}
static BOOL LBVisibility(id value) { return LBString(value) && [@[@"PRIVATE",@"PROTECTED",@"PUBLIC"] containsObject:value]; }
static BOOL LBState(id value) { return LBString(value) && [@[@"NORMAL",@"ARCHIVED"] containsObject:value]; }
static NSString *LBBase(id value) {
  if (!LBString(value)) return nil;
  NSURLComponents *c = [NSURLComponents componentsWithString:value];
  if (![c.scheme.lowercaseString isEqual:@"https"] || !c.host.length || c.user != nil || c.password != nil || c.query != nil || c.fragment != nil || (c.path.length && ![c.path isEqual:@"/"])) return nil;
  if (c.port && (!LBNumber(c.port, YES) || c.port.integerValue > 65535)) return nil;
  c.scheme = @"https"; c.host = c.host.lowercaseString; c.path = @"";
  if ([c.port isEqual:@443]) c.port = nil;
  return c.URL.absoluteString;
}
static NSString *LBSafeName(id value) {
  NSString *s = LBString(value) ? value : @"attachment";
  // Preserve Chinese/Unicode display names and upload names, but remove path,
  // multipart quoting, controls, bidi-formatting and Unicode line separators.
  NSMutableCharacterSet *bad = [NSCharacterSet.controlCharacterSet mutableCopy];
  [bad formUnionWithCharacterSet:NSCharacterSet.newlineCharacterSet];
  [bad addCharactersInString:@"/\\\":\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069"];
  s = [[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
  while ([s containsString:@".."]) s = [s stringByReplacingOccurrencesOfString:@".." withString:@"_"];
  while ([s hasPrefix:@"."]) s = [s substringFromIndex:1];
  if (!s.length) s = @"attachment";
  if (s.length > 180) s = [s substringWithRange:[s rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 180)]];
  return s;
}
static NSString *LBSafeType(id value) {
  if (!LBString(value) || [value length] > 120) return @"application/octet-stream";
  NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"^[a-zA-Z0-9!#$&^_.+-]+/[a-zA-Z0-9!#$&^_.+-]+$" options:0 error:NULL];
  return [rx numberOfMatchesInString:value options:0 range:NSMakeRange(0, [value length])] == 1 ? value : @"application/octet-stream";
}
static NSArray *LBIDs(id value) {
  if (![value isKindOfClass:NSArray.class] || [value count] > 1000) return nil;
  NSMutableOrderedSet *out = [NSMutableOrderedSet orderedSet];
  for (id n in value) { if (!LBNumber(n, YES)) return nil; [out addObject:n]; }
  return out.array;
}
static NSDictionary *LBResource(id value) {
  if (![value isKindOfClass:NSDictionary.class]) return nil;
  NSDictionary *r = value;
  if (!LBNumber(r[@"id"], YES) || !LBNumber(r[@"creatorId"], YES) || !LBNumber(r[@"size"], NO) || !LBNumber(r[@"createdTs"], NO) || !LBNumber(r[@"updatedTs"], NO) || !LBString(r[@"filename"]) || !LBString(r[@"type"])) return nil;
  // Do not propagate remote externalLink/filepath/name/uid: canonical private
  // /resource/id/file is built from the verified connection at download time.
  return @{@"id":r[@"id"], @"creatorId":r[@"creatorId"], @"size":r[@"size"], @"createdTs":r[@"createdTs"], @"updatedTs":r[@"updatedTs"], @"filename":LBSafeName(r[@"filename"]), @"type":LBSafeType(r[@"type"])};
}
static NSDictionary *LBMemo(id value) {
  if (![value isKindOfClass:NSDictionary.class]) return nil;
  NSDictionary *m = value;
  if (!LBNumber(m[@"id"], YES) || !LBNumber(m[@"creatorId"], YES) || !LBString(m[@"content"]) || !LBVisibility(m[@"visibility"]) || !LBState(m[@"rowStatus"]) || !LBNumber(m[@"createdTs"], NO) || !LBNumber(m[@"updatedTs"], NO) || !LBNumber(m[@"displayTs"], NO) || !LBBool(m[@"pinned"]) || ![m[@"resourceList"] isKindOfClass:NSArray.class]) return nil;
  NSMutableArray *resources = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
  for (id raw in m[@"resourceList"]) {
    NSDictionary *r = LBResource(raw);
    if (!r || ![r[@"creatorId"] isEqual:m[@"creatorId"]] || [seen containsObject:r[@"id"]]) return nil;
    [seen addObject:r[@"id"]]; [resources addObject:r];
  }
  NSMutableDictionary *out = [@{@"id":m[@"id"], @"creatorId":m[@"creatorId"], @"content":m[@"content"], @"visibility":m[@"visibility"], @"rowStatus":m[@"rowStatus"], @"createdTs":m[@"createdTs"], @"updatedTs":m[@"updatedTs"], @"displayTs":m[@"displayTs"], @"pinned":@([m[@"pinned"] boolValue]), @"resourceList":resources} mutableCopy];
  for (NSString *key in @[@"creatorName", @"creatorUsername"]) if (LBString(m[key])) out[key] = m[key];
  NSMutableArray *tags = [NSMutableArray array];
  if ([m[@"tagList"] isKindOfClass:NSArray.class]) for (id tag in m[@"tagList"]) {
    if (LBString(tag)) [tags addObject:tag];
    else if ([tag isKindOfClass:NSDictionary.class] && LBString(tag[@"name"])) [tags addObject:tag[@"name"]];
  }
  out[@"tagList"] = tags; return out;
}
static NSArray *LBMemoIDs(NSDictionary *memo) { return [memo[@"resourceList"] valueForKey:@"id"]; }
static BOOL LBEqualOriginal(NSDictionary *a, NSDictionary *b) {
  for (NSString *key in @[@"id",@"creatorId",@"content",@"visibility",@"rowStatus",@"pinned",@"updatedTs"]) if (![a[key] isEqual:b[key]]) return NO;
  return [[NSSet setWithArray:LBMemoIDs(a)] isEqual:[NSSet setWithArray:LBMemoIDs(b)]];
}
static void LBProtect(NSURL *url) { LBProtectLocalURL(url, NULL); }

@interface LBMemosTransfer : NSObject
@property NSUInteger generation;
@property NSUInteger epoch;
@property BOOL mutation;
@property BOOL download;
@property NSString *expectedType;
@property NSUInteger bytes;
@property NSInteger status;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) NSURL *bodyFile;
@property (nonatomic, strong) NSURL *output;
@property (nonatomic, strong) NSOutputStream *stream;
@property (nonatomic, copy) void (^progress)(double);
@property (nonatomic, copy) void (^done)(id, NSInteger, NSError *);
@end
@implementation LBMemosTransfer
@end

@interface LBMemosCachedDownload : NSObject
@property NSDictionary *resource;
@property NSMutableArray *callbacks;
@property NSURLSessionTask *task;
@property NSUInteger generation;
@property BOOL started;
@end
@implementation LBMemosCachedDownload
@end

@interface LBMemosClient () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, readwrite, strong) NSDictionary *user;
@property (nonatomic, readwrite) NSUInteger generation;
@property (nonatomic, readwrite) BOOL busy;
@property NSUInteger epoch;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, LBMemosTransfer *> *transfers;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *ownedResourceIDs;
@property (nonatomic, strong) NSMutableSet<NSURL *> *temporaryFiles;
@property BOOL keychainFailed;
@property (nonatomic, readwrite) BOOL authenticationRequired;
@property LBMemosDiskCache *diskCache;
@property NSMutableDictionary<NSString *, LBMemosCachedDownload *> *cacheDownloads;
@property NSMutableDictionary<NSString *, NSDictionary *> *cacheResources;
@property NSMutableSet<NSString *> *cacheFailures;
@property NSMutableDictionary<NSString *, NSArray *> *cacheVerifiedStates;
@property NSUInteger cacheProofEpoch;
@property NSUInteger cacheActive;
@property BOOL cachePrefetching;
@property BOOL cacheReconciling;
@property NSError *cacheError;
@property BOOL cacheBindingLoading;
@property BOOL cacheBindingAttempted;
@property NSMutableSet<NSString *> *cacheCompleted;
@property BOOL cacheLoaded;
- (void)cacheLoadBoundIdentity;
- (void)cacheIndexResources;
- (void)cacheNotify;
- (void)cachePump;
- (void)cacheFinish:(LBMemosCachedDownload *)job key:(NSString *)key url:(NSURL *)url error:(NSError *)error;

@end

@implementation LBMemosClient
@synthesize baseURL = _baseURL;
+ (instancetype)shared { static LBMemosClient *client; static dispatch_once_t once; dispatch_once(&once, ^{ client = [self new]; }); return client; }
- (instancetype)init {
  if ((self = [super init])) {
    _baseURL = [[NSUserDefaults.standardUserDefaults stringForKey:@"LBMemosBaseURL"] ?: @"https://shuoshuo.ssaw.top" copy];
    _transfers = [NSMutableDictionary dictionary]; _ownedResourceIDs = [NSMutableSet set]; _temporaryFiles = [NSMutableSet set]; _generation = 1;
    _cacheDownloads = [NSMutableDictionary dictionary]; _cacheResources = [NSMutableDictionary dictionary];
    _cacheFailures = [NSMutableSet set]; _cacheCompleted = [NSMutableSet set]; _cacheVerifiedStates = [NSMutableDictionary dictionary];
    dispatch_async(dispatch_get_main_queue(), ^{ [self cacheLoadBoundIdentity]; });
  } return self;
}
- (NSString *)baseURL { return LBOnMain(^id{ return self->_baseURL; }); }
- (void)setBaseURL:(NSString *)value {
  // A changed origin must never inherit the old origin's credential.
  LBOnMain(^id{ NSString *base = LBBase(value) ?: @"";
    if (![self->_baseURL isEqual:base]) [self configureBaseURL:base token:nil];
    return nil;
  });
}
- (BOOL)configureBaseURL:(NSString *)base token:(NSString *)token {
  return [LBOnMain(^id{
    NSString *normalized = LBBase([base stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    NSString *key = [token ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!normalized || [key rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return @NO;
    [LBKeychain set:key account:@"memos-token"];
    if (![([LBKeychain get:@"memos-token"] ?: @"") isEqual:key]) { self.keychainFailed = YES; return @NO; }
    // Both values are committed BEFORE any synchronous reset observer runs.
    self->_baseURL = [normalized copy];
    [NSUserDefaults.standardUserDefaults setObject:normalized forKey:@"LBMemosBaseURL"];
    self.keychainFailed = NO; self.authenticationRequired = NO;
    [self reset]; return @YES;
  }) boolValue];
}
- (NSString *)token { return LBOnMain(^id{ return [LBKeychain get:@"memos-token"]; }); }
- (void)setToken:(NSString *)value {
  LBOnMain(^id{
    NSString *t = LBString(value) ? [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    NSString *old = [LBKeychain get:@"memos-token"] ?: @"";
    if (![old isEqual:t] || self.keychainFailed) {
      [LBKeychain set:t account:@"memos-token"];
      self.keychainFailed = ![([LBKeychain get:@"memos-token"] ?: @"") isEqual:t];
      self.authenticationRequired = NO;
      [self reset];
    } return nil;
  });
}
- (BOOL)configured {
  return [LBOnMain(^id{
    NSString *t = [LBKeychain get:@"memos-token"];
    return @(LBBase(self->_baseURL) != nil && t.length > 0 && [t rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound && !self.keychainFailed);
  }) boolValue];
}
- (void)reset {
  LB_MAIN_RETURN([self reset]);
  self.generation++; self.epoch++; self.user = nil; self.busy = NO;
  NSArray *cacheJobs = self.cacheDownloads.allValues;
  [self.cacheDownloads removeAllObjects]; self.cacheActive = 0;
  for (LBMemosCachedDownload *job in cacheJobs) for (void (^callback)(NSURL *, NSError *) in job.callbacks) dispatch_async(dispatch_get_main_queue(), ^{ callback(nil, LBStale()); });
  [self.diskCache invalidate];
  self.diskCache = nil; self.cachePrefetching = NO; self.cacheError = nil; self.cacheLoaded = NO; self.cacheBindingLoading = NO; self.cacheBindingAttempted = NO; self.cacheReconciling = NO; [self.cacheCompleted removeAllObjects];
  [self.cacheResources removeAllObjects]; [self.cacheFailures removeAllObjects]; [self.cacheVerifiedStates removeAllObjects];
  [self cacheNotify];
  [self.session invalidateAndCancel]; self.session = nil;
  NSArray *pending = self.transfers.allValues; [self.transfers removeAllObjects];
  for (LBMemosTransfer *c in pending) { [c.stream close]; if (c.bodyFile) [NSFileManager.defaultManager removeItemAtURL:c.bodyFile error:NULL]; if (c.output) [NSFileManager.defaultManager removeItemAtURL:c.output error:NULL]; dispatch_async(dispatch_get_main_queue(), ^{ c.done(nil, 0, LBStale()); }); }
  for (NSURL *url in self.temporaryFiles) [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
  [self.temporaryFiles removeAllObjects]; [self.ownedResourceIDs removeAllObjects];
  // Deliberately never delete account-scoped drafts on reset/token changes.
  [self cacheLoadBoundIdentity];
  [NSNotificationCenter.defaultCenter postNotificationName:LBMemosDidChange object:self userInfo:nil];
}
- (NSError *)ready {
  if (!self.configured) return LBErr(1001, @"请配置有效的 HTTPS 根地址和独立 Memos 令牌，并确认钥匙串保存成功。");
  if (self.authenticationRequired || !self.user) return LBErr(1002, @"请先验证 Memos 身份。"); return nil;
}
- (NSError *)beginWrite {
  NSError *e = [self ready]; if (e) return e;
  if (self.busy) return LBErr(1003, @"正在保存或传输，请稍后再试。"); self.busy = YES; return nil;
}
- (NSURL *)tempWithName:(NSString *)name {
  NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"LBMemos"] isDirectory:YES];
  [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL]; LBProtect(directory);
  NSURL *url = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, LBSafeName(name)]];
  [NSFileManager.defaultManager createFileAtPath:url.path contents:nil attributes:@{NSFilePosixPermissions:@0600}]; LBProtect(url); return url;
}
- (NSURLSessionTask *)request:(NSString *)method path:(NSString *)path query:(NSArray<NSURLQueryItem *> *)query json:(id)json bodyFile:(NSURL *)bodyFile contentType:(NSString *)type download:(NSURL *)output mutation:(BOOL)mutation progress:(void (^)(double))progress done:(void (^)(id, NSInteger, NSError *))done {
  NSAssert(NSThread.isMainThread, @"Main queue confinement");
  if (!self.configured) { done(nil, 0, LBErr(1001, @"Memos 连接配置无效。")); return nil; }
  if (!self.session) {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage = nil; config.HTTPShouldSetCookies = NO; config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData; config.URLCredentialStorage = nil;
    config.timeoutIntervalForRequest = 35; config.timeoutIntervalForResource = 180;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
  }
  NSURLComponents *parts = [NSURLComponents componentsWithString:self.baseURL]; parts.path = path; parts.queryItems = query.count ? query : nil;
  NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:parts.URL]; r.HTTPMethod = method;
  [r setValue:[@"Bearer " stringByAppendingString:self.token] forHTTPHeaderField:@"Authorization"];
  [r setValue:@"application/json" forHTTPHeaderField:@"Accept"]; [r setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
  if (json) { r.HTTPBody = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL]; [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; }
  if (type) [r setValue:type forHTTPHeaderField:@"Content-Type"];
  if (output) [r setValue:@"*/*" forHTTPHeaderField:@"Accept"];
  LBMemosTransfer *c = [LBMemosTransfer new]; c.generation = self.generation; c.epoch = self.epoch; c.mutation = mutation;
  c.bodyFile = bodyFile; c.output = output; c.download = output != nil; c.progress = progress; c.done = done; c.data = [NSMutableData data];
  if (output) { c.stream = [NSOutputStream outputStreamWithURL:output append:NO]; [c.stream open]; }
  NSURLSessionTask *task = bodyFile ? [self.session uploadTaskWithRequest:r fromFile:bodyFile] : [self.session dataTaskWithRequest:r];
  self.transfers[@(task.taskIdentifier)] = c; [task resume]; return task;
}
- (LBMemosTransfer *)context:(NSURLSession *)session task:(NSURLSessionTask *)task { return session == self.session ? self.transfers[@(task.taskIdentifier)] : nil; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
  (void)response; (void)request; LBMemosTransfer *c = [self context:session task:task]; c.error = LBErr(1004, @"为保护令牌，已拒绝服务器重定向。"); completionHandler(nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
  LBMemosTransfer *c = [self context:session task:task];
  if (!c) { completionHandler(NSURLSessionResponseCancel); return; }
  c.status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
  NSUInteger cap = c.download ? LBFileCap : LBJSONCap;
  if (response.expectedContentLength > (int64_t)cap) c.error = LBErr(1005, @"响应超过允许的大小限制。");
  if (c.download && c.status >= 200 && c.status < 300 && c.expectedType.length) {
    NSString *actual = response.MIMEType.lowercaseString, *expected = c.expectedType.lowercaseString;
    BOOL generic = !actual.length || [actual isEqual:@"application/octet-stream"];
    NSString *family = [expected componentsSeparatedByString:@"/"].firstObject;
    BOOL media = [@[@"image", @"video", @"audio"] containsObject:family];
    if ((!generic && media && ![actual hasPrefix:[family stringByAppendingString:@"/"]]) || (([actual isEqual:@"text/html"] || [actual isEqual:@"application/json"]) && ![expected isEqual:actual])) c.error = LBErr(1006, @"附件响应类型与快照不符，未缓存；请重新同步。");
  }
  if (!c.download && c.status >= 200 && c.status < 300 && ![response.MIMEType.lowercaseString isEqual:@"application/json"]) c.error = LBErr(1006, @"服务器未返回 JSON 数据。");
  completionHandler(c.error ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
  LBMemosTransfer *c = [self context:session task:task]; if (!c) return;
  NSUInteger cap = c.download ? LBFileCap : LBJSONCap;
  if (data.length > cap - c.bytes) { c.error = LBErr(1005, @"响应超过允许的大小限制。"); [task cancel]; return; } c.bytes += data.length;
  if (!c.download) { [c.data appendData:data]; return; }
  const uint8_t *p = data.bytes; NSUInteger left = data.length;
  while (left) { NSInteger n = [c.stream write:p maxLength:left]; if (n <= 0) { c.error = LBErr(1007, @"无法写入受保护的临时文件。"); [task cancel]; return; } p += n; left -= (NSUInteger)n; }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesSent totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
  (void)bytesSent; LBMemosTransfer *c = [self context:session task:task];
  if (c && c.generation == self.generation && c.progress && totalBytesExpectedToSend > 0) c.progress(MIN(1.0, (double)totalBytesSent / (double)totalBytesExpectedToSend));
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  LBMemosTransfer *c = [self context:session task:task]; if (!c) return; [self.transfers removeObjectForKey:@(task.taskIdentifier)]; [c.stream close];
  if (c.bodyFile) [NSFileManager.defaultManager removeItemAtURL:c.bodyFile error:NULL];
  NSError *e = c.error;
  if (c.generation != self.generation || (!c.mutation && c.epoch != self.epoch)) e = LBStale();
  else if (!e && error) {
    if (error.code == NSURLErrorCancelled) e = LBErr(1008, c.mutation ? @"操作已取消，远端结果可能未知，请先刷新确认。" : @"操作已取消。");
    else e = LBErr(c.mutation ? 1010 : 1009, c.mutation ? @"UNKNOWN：远端结果未知。请先检查列表或详情，确认是否成功，再决定重试；不会自动重发。" : @"网络请求失败，请稍后重新加载。");
  }
  if (!e && (c.status < 200 || c.status >= 300)) {
    NSString *message;
    if (c.mutation && c.status >= 500) message = @"UNKNOWN：服务器错误时写入结果仍可能不确定。请先检查列表或详情，不要直接重发。";
    else message = c.status == 401 ? @"令牌无效或过期，请重新验证身份。" : c.status == 403 ? @"没有访问权限。" : c.status == 404 ? @"记录不存在。" : @"服务器拒绝请求，请刷新确认状态。";
    e = LBErr(c.status ?: 1009, message);
  }
  id result;
  if (!e) {
    if (c.download) { LBProtect(c.output); [self.temporaryFiles addObject:c.output]; result = c.output; }
    else { result = [NSJSONSerialization JSONObjectWithData:c.data options:NSJSONReadingFragmentsAllowed error:NULL]; if (!result) e = LBErr(1006, @"服务器返回的数据格式无效。"); }
  }
  if (e && c.output) [NSFileManager.defaultManager removeItemAtURL:c.output error:NULL];
  if (c.status == 401 && c.generation == self.generation) { [LBMemosDiskCache revokeBindingForBase:LBBase(self.baseURL) token:self.token]; self.authenticationRequired = YES; self.user = nil; [self reset]; }
  c.done(result, c.status, e);
}

- (void)validate:(void (^)(NSDictionary *, NSError *))done {
  LB_MAIN_RETURN([self validate:done]);
  if (!self.configured) { done(nil, LBErr(1001, @"请先配置 Memos 连接和令牌。")); return; }
  if (self.busy) { done(nil, LBErr(1003, @"正在写入，请稍后验证。")); return; }
  [self request:@"GET" path:@"/api/v1/user/me" query:nil json:nil bodyFile:nil contentType:nil download:nil mutation:NO progress:nil done:^(id raw, NSInteger status, NSError *e) {
    (void)status;
    NSDictionary *u = [raw isKindOfClass:NSDictionary.class] ? raw : nil;
    // A successful authenticated /user/me is the authority. This legacy
    // deployment reports HOST+ARCHIVED while permitting that account's API;
    // validate the enum but do not impose a separate client account lockout.
    if (!e && (!LBNumber(u[@"id"], YES) || !LBString(u[@"username"]) || !LBState(u[@"rowStatus"]))) e = LBErr(1006, @"身份数据格式无效。");
    if (e) { done(nil, e); return; }
    NSDictionary *clean = @{@"id":u[@"id"], @"username":u[@"username"], @"nickname":LBString(u[@"nickname"]) ? u[@"nickname"] : @"", @"rowStatus":u[@"rowStatus"], @"role":LBString(u[@"role"]) ? u[@"role"] : @"USER"};
    // /user/me supersedes BOTH a live identity and a read-only cold binding.
    // Clear old-account UI via reset before accepting any new-account rows.
    if ((self.user && ![self.user[@"id"] isEqual:clean[@"id"]]) ||
        (self.diskCache && ![self.diskCache.userID isEqual:clean[@"id"]])) {
      [LBMemosDiskCache revokeBindingForBase:LBBase(self.baseURL) token:self.token];
      self.authenticationRequired = YES; // suppress old offline binding reload
      [self reset]; done(nil, LBStale()); return; // explicit validate again
    }
    self.authenticationRequired = NO; self.user = clean;
    NSUInteger generation = self.generation;
    NSString *base = LBBase(self.baseURL), *token = self.token;
    // Persist only a hash-indexed binding after an authenticated /user/me.
    [LBMemosDiskCache saveBindingForBase:base token:token userID:clean[@"id"] done:^(NSError *bindingError) {
      if (generation != self.generation) return;
      if (bindingError) { self.cacheError = bindingError; [self cacheNotify]; }
    }];
    if (self.diskCache && [self.diskCache.userID isEqual:clean[@"id"]] && self.cacheLoaded) { done(clean, nil); return; }
    LBMemosDiskCache *cache = [[LBMemosDiskCache alloc] initWithBase:base userID:clean[@"id"]];
    [self.diskCache invalidate];
    self.diskCache = cache; self.cacheLoaded = NO;
    [cache load:^(NSError *cacheError) {
      if (generation != self.generation || cache != self.diskCache) { done(nil, LBStale()); return; }
      self.cacheLoaded = YES; self.cacheError = cacheError; [self cacheIndexResources];
      [self cacheNotify]; done(clean, nil);
    }];
  }];
}
- (void)listState:(NSString *)state text:(NSString *)text tag:(NSString *)tag offset:(NSUInteger)offset done:(void (^)(NSArray<NSDictionary *> *, BOOL, NSError *))done {
  LB_MAIN_RETURN([self listState:state text:text tag:tag offset:offset done:done]);
  NSError *e = [self ready];
  if (!e && (!LBState(state) || !LBString(text) || !LBString(tag) || offset > 9007199254740991ULL)) e = LBErr(1011, @"列表筛选参数无效。");
  if (e) { done(nil, NO, e); return; }
  NSNumber *uid = self.user[@"id"];
  NSMutableArray *q = [NSMutableArray arrayWithArray:@[[NSURLQueryItem queryItemWithName:@"creatorId" value:uid.stringValue], [NSURLQueryItem queryItemWithName:@"rowStatus" value:state], [NSURLQueryItem queryItemWithName:@"limit" value:@"30"], [NSURLQueryItem queryItemWithName:@"offset" value:[@(offset) stringValue]]]];
  if (text.length) [q addObject:[NSURLQueryItem queryItemWithName:@"text" value:text]];
  if (tag.length) [q addObject:[NSURLQueryItem queryItemWithName:@"tag" value:tag]];
  [self request:@"GET" path:@"/api/v1/memo" query:q json:nil bodyFile:nil contentType:nil download:nil mutation:NO progress:nil done:^(id raw, NSInteger status, NSError *err) {
    (void)status; NSMutableArray *rows = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    if (!err && (![raw isKindOfClass:NSArray.class] || [raw count] > 30)) err = LBErr(1006, @"列表数据格式无效。");
    if (!err) for (id value in raw) {
      NSDictionary *m = LBMemo(value);
      if (!m || ![m[@"creatorId"] isEqual:uid] || ![m[@"rowStatus"] isEqual:state]) { err = LBErr(1006, @"列表包含错误账户或状态的数据。"); break; }
      if (![seen containsObject:m[@"id"]]) { [rows addObject:m]; [seen addObject:m[@"id"]]; }
    }
    // Pagination uses server raw count, NEVER the deduplicated count.
    done(err ? nil : rows, !err && [raw count] == 30, err);
  }];
}
- (void)allState:(NSString *)state text:(NSString *)text tag:(NSString *)tag done:(void (^)(NSArray<NSDictionary *> *, NSError *))done {
  LB_MAIN_RETURN([self allState:state text:text tag:tag done:done]);
  NSError *error = [self ready];
  if (!error && (!LBState(state) || !LBString(text) || !LBString(tag))) error = LBErr(1011, @"列表筛选参数无效。");
  if (error) { done(nil, error); return; }
  NSNumber *uid = self.user[@"id"];
  // The deployed legacy API explicitly supports personal full sync when a
  // rowStatus is supplied and limit is absent. Do NOT send limit=-1.
  NSMutableArray *query = [NSMutableArray arrayWithArray:@[
    [NSURLQueryItem queryItemWithName:@"creatorId" value:uid.stringValue],
    [NSURLQueryItem queryItemWithName:@"rowStatus" value:state] ]];
  if (text.length) [query addObject:[NSURLQueryItem queryItemWithName:@"text" value:text]];
  if (tag.length) [query addObject:[NSURLQueryItem queryItemWithName:@"tag" value:tag]];
  [self request:@"GET" path:@"/api/v1/memo" query:query json:nil bodyFile:nil contentType:nil download:nil mutation:NO progress:nil done:^(id raw, NSInteger status, NSError *e) {
    if (!e && (![raw isKindOfClass:NSArray.class] || [raw count] > 10000)) e = LBErr(1006, @"完整列表过大或格式异常，未将部分结果当作总数。");
    NSMutableArray *rows = [NSMutableArray array]; NSMutableSet *ids = [NSMutableSet set];
    if (!e) for (id value in raw) {
      NSDictionary *memo = LBMemo(value);
      if (!memo || ![memo[@"creatorId"] isEqual:uid] || ![memo[@"rowStatus"] isEqual:state] || [ids containsObject:memo[@"id"]]) { e = LBErr(1006, @"完整列表存在异常记录，未更新总数。"); break; }
      [rows addObject:memo]; [ids addObject:memo[@"id"]];
    }
    if (!e && !text.length && !tag.length) {
      if (self.cacheProofEpoch != self.epoch) { [self.cacheVerifiedStates removeAllObjects]; self.cacheProofEpoch = self.epoch; }
      self.cacheVerifiedStates[state] = [rows copy];
      LBMemosDiskCache *cache = self.diskCache;
      [cache replaceState:state rows:rows done:^(NSError *cacheError) {
        if (cache != self.diskCache) return;
        self.cacheError = cacheError; [self cacheNotify];
      }];
    }
    done(e ? nil : rows, e);
  }];
}
- (void)checkLatestMemoState:(NSString *)state done:(void (^)(NSDictionary *_Nullable, NSError *_Nullable))done {
  LB_MAIN_RETURN([self checkLatestMemoState:state done:done]);
  NSError *error = [self ready];
  if (!error && !LBState(state)) error = LBErr(1011, @"状态参数无效。");
  if (error) { done(nil, error); return; }
  NSNumber *uid = self.user[@"id"];
  NSMutableArray *query = [NSMutableArray arrayWithArray:@[
    [NSURLQueryItem queryItemWithName:@"creatorId" value:uid.stringValue],
    [NSURLQueryItem queryItemWithName:@"rowStatus" value:state],
    [NSURLQueryItem queryItemWithName:@"limit" value:@"1"] ]];
  [self request:@"GET" path:@"/api/v1/memo" query:query json:nil bodyFile:nil contentType:nil download:nil mutation:NO progress:nil done:^(id raw, NSInteger status, NSError *e) {
    (void)status;
    if (e) { done(nil, e); return; }
    if (![raw isKindOfClass:NSArray.class]) { done(nil, LBErr(1006, @"数据格式异常。")); return; }
    NSArray *list = (NSArray *)raw;
    if (!list.count) { done(nil, nil); return; }
    NSDictionary *m = LBMemo(list.firstObject);
    done(m, nil);
  }];
}

- (void)tags:(void (^)(NSArray<NSString *> *, NSError *))done {
  LB_MAIN_RETURN([self tags:done]); NSError *e = [self ready]; if (e) { done(nil, e); return; }
  [self request:@"GET" path:@"/api/v1/tag" query:nil json:nil bodyFile:nil contentType:nil download:nil mutation:NO progress:nil done:^(id raw, NSInteger status, NSError *err) {
    (void)status; if (!err && ![raw isKindOfClass:NSArray.class]) err = LBErr(1006, @"标签数据格式无效。");
    if (!err) for (id tag in raw) if (!LBString(tag)) { err = LBErr(1006, @"标签必须是字符串。"); break; }
    done(err ? nil : raw, err);
  }];
}
- (void)fetchMemo:(NSNumber *)identifier mutation:(BOOL)mutation done:(void (^)(NSDictionary *, NSError *))done {
  NSNumber *uid = self.user[@"id"];
  [self request:@"GET" path:[@"/api/v1/memo/" stringByAppendingString:identifier.stringValue] query:nil json:nil bodyFile:nil contentType:nil download:nil mutation:mutation progress:nil done:^(id raw, NSInteger status, NSError *e) {
    (void)status; NSDictionary *m = e ? nil : LBMemo(raw);
    if (!e && (!m || ![m[@"creatorId"] isEqual:uid] || ![m[@"id"] isEqual:identifier])) e = LBErr(1006, @"说说数据格式或账户归属无效。");
    done(e ? nil : m, e);
  }];
}
- (void)memo:(NSNumber *)identifier done:(void (^)(NSDictionary *, NSError *))done {
  LB_MAIN_RETURN([self memo:identifier done:done]); NSError *e = [self ready];
  if (!e && !LBNumber(identifier, YES)) e = LBErr(1011, @"说说编号无效。");
  if (e) { done(nil, e); return; } [self fetchMemo:identifier mutation:NO done:done];
}
- (void)changedMemo:(NSDictionary *)memo {
  self.epoch++; [self.cacheVerifiedStates removeAllObjects];
  LBMemosDiskCache *cache = self.diskCache;
  [cache patchMemo:memo deletedID:nil done:^(NSError *error) {
    if (cache != self.diskCache) return; self.cacheError = error; [self cacheNotify];
  }];
  [NSNotificationCenter.defaultCenter postNotificationName:LBMemosDidChange object:self userInfo:@{@"memo":memo}];
}
- (void)writeMemoPath:(NSString *)path method:(NSString *)method fields:(NSDictionary *)fields expectedID:(NSNumber *)expectedID done:(void (^)(NSDictionary *, NSError *))done {
  NSNumber *uid = self.user[@"id"]; NSUInteger generation = self.generation;
  [self request:method path:path query:nil json:fields bodyFile:nil contentType:nil download:nil mutation:YES progress:nil done:^(id raw, NSInteger status, NSError *e) {
    (void)status; if (generation == self.generation) self.busy = NO;
    NSDictionary *m = e ? nil : LBMemo(raw);
    if (!e && (!m || ![m[@"creatorId"] isEqual:uid] || (expectedID && ![m[@"id"] isEqual:expectedID]))) e = LBErr(1010, @"UNKNOWN：保存可能已完成，但响应无效。请先检查列表或详情，不要直接重新发布。");
    if (!e) {
      BOOL matches = expectedID != nil || [m[@"rowStatus"] isEqual:@"NORMAL"];
      for (NSString *key in fields) {
        if ([key isEqual:@"resourceIdList"]) matches = matches && [[NSSet setWithArray:fields[key]] isEqual:[NSSet setWithArray:LBMemoIDs(m)]];
        else matches = matches && [fields[key] isEqual:m[key]];
      }
      if (!matches) e = LBErr(1010, @"UNKNOWN：服务器返回与保存内容不一致，请先检查详情，勿直接重发。");
    }
    if (!e) {
      [self.ownedResourceIDs minusSet:[NSSet setWithArray:LBMemoIDs(m)]];
      [self changedMemo:m];
      if (generation != self.generation) done(nil, LBStale()); else done(m, nil);
    } else { if (generation == self.generation) self.epoch++; done(nil, e); }
  }];
}
- (void)saveOriginal:(NSDictionary *)original content:(NSString *)content visibility:(NSString *)visibility resourceIDs:(NSArray<NSNumber *> *)ids done:(void (^)(NSDictionary *, NSError *))done {
  LB_MAIN_RETURN([self saveOriginal:original content:content visibility:visibility resourceIDs:ids done:done]);
  NSArray *cleanIDs = LBIDs(ids);
  if (!LBString(content) || !LBVisibility(visibility) || !cleanIDs || (!content.length && !cleanIDs.count)) { done(nil, LBErr(1011, @"内容、可见性或附件编号无效。")); return; }
  NSDictionary *fields = @{@"content":content, @"visibility":visibility, @"resourceIdList":cleanIDs};
  if (original) { [self updateMemo:original fields:fields done:done]; return; }
  NSError *e = [self beginWrite]; if (e) { done(nil, e); return; }
  [self writeMemoPath:@"/api/v1/memo" method:@"POST" fields:fields expectedID:nil done:done];
}
- (void)updateMemo:(NSDictionary *)memo fields:(NSDictionary *)fields done:(void (^)(NSDictionary *, NSError *))done {
  LB_MAIN_RETURN([self updateMemo:memo fields:fields done:done]);
  NSDictionary *original = LBMemo(memo); NSMutableDictionary *clean = [NSMutableDictionary dictionary];
  BOOL valid = original && [fields isKindOfClass:NSDictionary.class] && fields.count;
  if (valid) for (id key in fields) {
    id value = fields[key];
    if ([key isEqual:@"content"]) valid = LBString(value);
    else if ([key isEqual:@"visibility"]) valid = LBVisibility(value);
    else if ([key isEqual:@"rowStatus"]) valid = LBState(value);
    else if ([key isEqual:@"pinned"]) valid = LBBool(value);
    else if ([key isEqual:@"resourceIdList"]) { value = LBIDs(value); valid = value != nil; }
    else valid = NO;
    if (!valid) break; clean[key] = value;
  }
  if (!valid) { done(nil, LBErr(1011, @"修改参数或原始快照无效。")); return; }
  NSError *e = [self beginWrite]; if (e) { done(nil, e); return; }
  if (![original[@"creatorId"] isEqual:self.user[@"id"]]) { self.busy = NO; done(nil, LBErr(403, @"只能修改自己的说说。")); return; }
  NSUInteger generation = self.generation;
  [self fetchMemo:original[@"id"] mutation:YES done:^(NSDictionary *fresh, NSError *err) {
    // This is optimistic preflight, NOT atomic CAS: Worker has no version
    // precondition, so another device can still write between GET and PATCH.
    if (!err && !LBEqualOriginal(original, fresh)) err = LBErr(409, @"远端内容、可见性、状态、置顶、附件或时间已改变，请重新打开后再编辑。");
    if (err) { if (generation == self.generation) self.busy = NO; done(nil, err); return; }
    NSString *path = [@"/api/v1/memo/" stringByAppendingString:[original[@"id"] stringValue]];
    [self writeMemoPath:path method:@"PATCH" fields:clean expectedID:original[@"id"] done:done];
  }];
}

- (void)deleteArchived:(NSDictionary *)memo done:(void (^)(NSError *))done {
  LB_MAIN_RETURN([self deleteArchived:memo done:done]); NSDictionary *original = LBMemo(memo);
  if (!original || ![original[@"rowStatus"] isEqual:@"ARCHIVED"]) { done(LBErr(1011, @"只能永久删除已归档的说说。")); return; }
  NSError *e = [self beginWrite]; if (e) { done(e); return; }
  if (![original[@"creatorId"] isEqual:self.user[@"id"]]) { self.busy = NO; done(LBErr(403, @"只能删除自己的说说。")); return; }
  NSUInteger generation = self.generation; NSNumber *identifier = original[@"id"];
  void (^finish)(NSError *) = ^(NSError *err) {
    if (generation == self.generation) {
      self.busy = NO; self.epoch++;
      if (!err) {
        [self.cacheVerifiedStates removeAllObjects]; LBMemosDiskCache *cache = self.diskCache;
        [cache patchMemo:nil deletedID:identifier done:^(NSError *error) {
          if (cache != self.diskCache) return; self.cacheError = error; [self cacheNotify];
        }];
        // Originals are removed only after a verified, complete TWO-state sync.
        [NSNotificationCenter.defaultCenter postNotificationName:LBMemosDidChange object:self userInfo:@{@"deletedID":identifier}];
      }
    }
    done(generation == self.generation ? err : LBStale());
  };
  [self fetchMemo:identifier mutation:YES done:^(NSDictionary *fresh, NSError *err) {
    if ([err.domain isEqual:LBErrorDomain] && err.code == 404) { finish(nil); return; }
    if (!err && ![fresh[@"rowStatus"] isEqual:@"ARCHIVED"]) err = LBErr(409, @"远端记录已恢复，未发送删除请求。");
    if (err) { finish(err); return; }
    // Legacy DELETE is non-idempotent. A single remote preflight followed by a
    // SINGLE request; no retry path, no automatic archive-then-delete sequence.
    [self request:@"DELETE" path:[@"/api/v1/memo/" stringByAppendingString:identifier.stringValue] query:nil json:nil bodyFile:nil contentType:nil download:nil mutation:YES progress:nil done:^(id raw, NSInteger status, NSError *error) {
      if (status == 404) error = nil; // Already absent is a known safe outcome.
      else if (!error && (![raw isKindOfClass:NSDictionary.class] || ![raw[@"message"] isEqual:@"Memo permanently deleted"])) error = LBErr(1010, @"UNKNOWN：删除结果无法确认，请刷新归档列表，勿直接重发。");
      finish(error);
    }];
  }];
}
- (NSURLSessionTask *)uploadFile:(NSURL *)file filename:(NSString *)filename type:(NSString *)type progress:(void (^)(double))progress done:(void (^)(NSDictionary *, NSError *))done {
  if (!NSThread.isMainThread) return LBOnMain(^id{ return [self uploadFile:file filename:filename type:type progress:progress done:done]; });
  NSError *e = [self beginWrite]; if (e) { done(nil, e); return nil; }
  NSDictionary *attrs = file.isFileURL ? [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:NULL] : nil;
  NSNumber *size = attrs[NSFileSize];
  if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || !size || size.unsignedLongLongValue > LBFileCap) { self.busy = NO; done(nil, LBErr(1011, @"请选择不超过 32 MiB 的本地普通文件。")); return nil; }
  NSString *boundary = [@"LBMemos-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSURL *body = [self tempWithName:@"multipart.body"];
  NSOutputStream *out = [NSOutputStream outputStreamWithURL:body append:NO]; [out open];
  NSInputStream *input = [NSInputStream inputStreamWithURL:file]; [input open];
  NSString *header = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\nContent-Type: %@\r\n\r\n", boundary, LBSafeName(filename), LBSafeType(type)];
  NSData *start = [header dataUsingEncoding:NSUTF8StringEncoding];
  BOOL (^write)(const uint8_t *, NSUInteger) = ^BOOL(const uint8_t *p, NSUInteger left) {
    while (left) { NSInteger n = [out write:p maxLength:left]; if (n <= 0) return NO; p += n; left -= (NSUInteger)n; } return YES;
  };
  BOOL ok = write(start.bytes, start.length); uint8_t buffer[65536]; NSUInteger total = 0;
  while (ok) {
    NSInteger n = [input read:buffer maxLength:sizeof(buffer)];
    if (n < 0) { ok = NO; break; } if (!n) break;
    if ((NSUInteger)n > LBFileCap - total) { ok = NO; break; } total += (NSUInteger)n; ok = write(buffer, (NSUInteger)n);
  }
  NSData *end = [[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding];
  ok = ok && total == size.unsignedLongLongValue && write(end.bytes, end.length);
  [input close]; [out close]; LBProtect(body);
  if (!ok) { [NSFileManager.defaultManager removeItemAtURL:body error:NULL]; self.busy = NO; done(nil, LBErr(1007, @"无法安全读取附件或创建上传临时文件。")); return nil; }
  NSNumber *uid = self.user[@"id"]; NSUInteger generation = self.generation;
  return [self request:@"POST" path:@"/api/v1/resource/blob" query:nil json:nil bodyFile:body contentType:[@"multipart/form-data; boundary=" stringByAppendingString:boundary] download:nil mutation:YES progress:progress done:^(id raw, NSInteger status, NSError *err) {
    (void)status; if (generation == self.generation) { self.busy = NO; self.epoch++; }
    NSDictionary *r = err ? nil : LBResource(raw);
    if (!err && (!r || ![r[@"creatorId"] isEqual:uid] || [r[@"size"] unsignedLongLongValue] != total)) err = LBErr(1010, @"UNKNOWN：附件可能已上传，但响应无效。请先确认资源，勿重复上传。");
    if (!err) [self.ownedResourceIDs addObject:r[@"id"]];
    done(err ? nil : r, err);
  }];
}
- (void)deleteResource:(NSNumber *)identifier done:(void (^)(NSError *))done {
  LB_MAIN_RETURN([self deleteResource:identifier done:done]);
  // Only explicitly requested resources uploaded by this client/context may be
  // deleted. Existing memo attachments are never implicitly deleted on unlink.
  if (!LBNumber(identifier, YES) || ![self.ownedResourceIDs containsObject:identifier]) { done(LBErr(403, @"仅可显式清理当前连接新上传且由本机记录的附件。")); return; }
  NSError *e = [self beginWrite]; if (e) { done(e); return; } NSUInteger generation = self.generation;
  [self request:@"DELETE" path:[@"/api/v1/resource/" stringByAppendingString:identifier.stringValue] query:nil json:nil bodyFile:nil contentType:nil download:nil mutation:YES progress:nil done:^(id raw, NSInteger status, NSError *err) {
    (void)status; if (generation == self.generation) { self.busy = NO; self.epoch++; }
    if (!err && !(CFGetTypeID((__bridge CFTypeRef)raw) == CFBooleanGetTypeID() && [raw boolValue])) err = LBErr(1010, @"UNKNOWN：附件删除响应无效，请刷新确认。");
    if (!err) [self.ownedResourceIDs removeObject:identifier]; done(err);
  }];
}
- (NSURLSessionTask *)downloadResource:(NSDictionary *)resource done:(void (^)(NSURL *, NSError *))done {
  if (!NSThread.isMainThread) return LBOnMain(^id{ return [self downloadResource:resource done:done]; });
  // A previously verified exact credential may READ original bytes offline.
  // No network/writes are allowed by this branch while user remains nil.
  NSURL *offline = [self cachedResource:resource]; if (offline) { done(offline, nil); return nil; }
  NSError *e = [self ready]; if (e) { done(nil, e); return nil; }
  NSDictionary *clean = LBResource(resource);
  // cachePump builds only the canonical /api/v1/resource/%@/file path.
  // ID-only descriptors cannot produce a stable versioned cache entry.
  if (!clean || ![clean[@"creatorId"] isEqual:self.user[@"id"]] || [clean[@"size"] unsignedLongLongValue] > LBFileCap) { done(nil, LBErr(1011, @"附件快照、归属或大小无效（上限 32 MiB）。")); return nil; }
  NSURL *cached = [self cachedResource:clean];
  if (cached) { done(cached, nil); return nil; }
  NSString *key = [LBMemosDiskCache fingerprint:clean];
  LBMemosCachedDownload *job = self.cacheDownloads[key];
  if (job) { [job.callbacks addObject:[done copy]]; return nil; }
  job = [LBMemosCachedDownload new]; job.resource = clean; job.generation = self.generation;
  job.callbacks = [NSMutableArray arrayWithObject:[done copy]];
  self.cacheDownloads[key] = job; [self.cacheFailures removeObject:key];
  if (!self.cacheFailures.count) self.cacheError = nil;
  [self cachePump];
  // The shared/deduplicated job is cache-owned; no caller may cancel another
  // view's transfer. Queued/cached jobs return nil. reset cancels all jobs.
  return nil;
}

- (NSURL *)draftURL:(NSNumber *)identifier create:(BOOL)create {
  if ([self ready] || (identifier && !LBNumber(identifier, YES))) return nil;
  NSString *scope = [NSString stringWithFormat:@"%@\n%@", LBBase(self.baseURL), self.user[@"id"]];
  NSData *bytes = [scope dataUsingEncoding:NSUTF8StringEncoding]; unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest); NSMutableString *hash = [NSMutableString string];
  for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hash appendFormat:@"%02x", digest[i]];
  NSURL *support = LBApplicationSupportURL();
  NSURL *root = [support URLByAppendingPathComponent:@"MemosDrafts" isDirectory:YES];
  NSURL *directory = [root URLByAppendingPathComponent:hash isDirectory:YES];
  if (create) {
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL]) return nil;
    LBProtect(root); LBProtect(directory);
  }
  return [directory URLByAppendingPathComponent:identifier ? [identifier.stringValue stringByAppendingString:@".json"] : @"new.json"];
}
- (NSDictionary *)cleanDraft:(id)value {
  if (![value isKindOfClass:NSDictionary.class]) return nil;
  NSString *text = value[@"text"] ?: value[@"content"]; NSArray *ids = LBIDs(value[@"resourceIDs"]);
  if (!LBString(text) || !LBVisibility(value[@"visibility"]) || !ids) return nil;
  NSMutableDictionary *clean = [@{@"text":text, @"visibility":value[@"visibility"], @"resourceIDs":ids} mutableCopy];
  NSMutableArray *resources = [NSMutableArray array];
  if (value[@"resourceList"]) {
    if (![value[@"resourceList"] isKindOfClass:NSArray.class]) return nil;
    for (id raw in value[@"resourceList"]) {
      NSDictionary *r = LBResource(raw);
      if (!r || ![r[@"creatorId"] isEqual:self.user[@"id"]] || ![ids containsObject:r[@"id"]]) return nil;
      [resources addObject:r];
    }
    clean[@"resourceList"] = resources;
  }
  // Optional editor metadata is whitelisted and constrained to our private
  // import directory, never arbitrary paths or security-scoped external URLs.
  if (value[@"localFiles"]) {
    if (![value[@"localFiles"] isKindOfClass:NSArray.class] || [value[@"localFiles"] count] > 100) return nil;
    NSURL *support = LBApplicationSupportURL();
    NSURL *root = [support URLByAppendingPathComponent:@"MemosEditorFiles" isDirectory:YES];
    NSMutableArray *files = [NSMutableArray array];
    for (id row in value[@"localFiles"]) {
      if (![row isKindOfClass:NSDictionary.class] || !LBString(row[@"path"]) || !LBString(row[@"filename"]) || !LBString(row[@"type"])) return nil;
      NSURL *url = [NSURL fileURLWithPath:row[@"path"]];
      NSString *parent = url.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByStandardizingPath.path;
      NSString *resolved = [root.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
      if (![parent isEqual:root.URLByStandardizingPath.path] || ![url.URLByResolvingSymlinksInPath.path hasPrefix:resolved]) return nil;
      // Missing files are retained as safe paths: editor reports them explicitly
      // rather than silently throwing away the recoverable text/IDs draft.
      NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL];
      if (a && (![a[NSFileType] isEqual:NSFileTypeRegular] || [a[NSFileSize] unsignedLongLongValue] > LBFileCap)) return nil;
      if (a) { LBProtect(url); LBProtect(url.URLByDeletingLastPathComponent); }
      NSString *name = row[@"filename"];
      if (name.length > 200 || [name containsString:@"/"] || [name containsString:@"\\"] || [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
      [files addObject:@{@"path":url.path, @"filename":name, @"type":LBSafeType(row[@"type"])}];
    }
    clean[@"localFiles"] = files;
  }
  if (value[@"originalSnapshot"]) {
    NSDictionary *original = LBMemo(value[@"originalSnapshot"]);
    if (!original || ![original[@"creatorId"] isEqual:self.user[@"id"]]) return nil;
    clean[@"originalSnapshot"] = original;
  }
  NSArray *owned = value[@"ownedResourceIDs"] ? LBIDs(value[@"ownedResourceIDs"]) : @[];
  if (!owned) return nil;
  for (NSNumber *n in owned) if (![ids containsObject:n]) return nil;
  clean[@"ownedResourceIDs"] = owned;
  return clean;
}
- (NSDictionary *)draftForMemo:(NSNumber *)identifier {
  return LBOnMain(^id{
    NSURL *url = [self draftURL:identifier create:NO]; if (!url) return nil;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL];
    if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || [attrs[NSFileSize] unsignedLongLongValue] > 2 * 1024 * 1024) return nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:NULL]; if (!data) return nil;
    NSDictionary *draft = [self cleanDraft:[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]];
    if (draft) [self.ownedResourceIDs addObjectsFromArray:draft[@"ownedResourceIDs"]];
    return draft;
  });
}
- (BOOL)saveDraft:(NSDictionary *)draft forMemo:(NSNumber *)identifier {
  return [LBOnMain(^id{
    NSURL *url = [self draftURL:identifier create:YES]; if (!url) return @NO;
    NSDictionary *clean = [self cleanDraft:draft]; if (!clean) return @NO;
    NSMutableDictionary *stored = [clean mutableCopy]; NSMutableArray *owned = [NSMutableArray array];
    for (NSNumber *n in clean[@"resourceIDs"]) if ([self.ownedResourceIDs containsObject:n]) [owned addObject:n];
    stored[@"ownedResourceIDs"] = owned;
    NSData *data = [NSJSONSerialization dataWithJSONObject:stored options:0 error:NULL];
    if (!data || data.length > 2 * 1024 * 1024) return @NO;
    BOOL ok = [data writeToURL:url options:NSDataWritingAtomic error:NULL];
    if (ok) LBProtect(url); return @(ok);
  }) boolValue];
}
- (void)removeDraftForMemo:(NSNumber *)identifier {
  LBOnMain(^id{ NSURL *url = [self draftURL:identifier create:NO]; if (url) [NSFileManager.defaultManager removeItemAtURL:url error:NULL]; return nil; });
}
#pragma mark - Verified account local-first cache
- (void)requireAuthentication {
  LB_MAIN_RETURN([self requireAuthentication]);
  if (self.authenticationRequired) return;
  [LBMemosDiskCache revokeBindingForBase:LBBase(self.baseURL) token:self.token];
  self.authenticationRequired = YES; self.user = nil;
  [self reset]; // invalidates cache lifecycle; no automatic revalidation
}
- (void)cacheIndexResources {
  [self.cacheResources removeAllObjects]; [self.cacheCompleted removeAllObjects];
  for (NSArray *rows in self.diskCache.snapshots.allValues) for (NSDictionary *memo in rows) for (NSDictionary *r in memo[@"resourceList"]) {
    NSString *key = [LBMemosDiskCache fingerprint:r]; if (key) { self.cacheResources[key] = r; if ([self.diskCache resourceURL:r]) [self.cacheCompleted addObject:key]; }
  }
}
- (void)cacheLoadBoundIdentity {
  NSAssert(NSThread.isMainThread, @"Main queue confinement");
  if (self.diskCache || self.cacheBindingLoading || self.cacheBindingAttempted || !self.configured || self.authenticationRequired) return;
  self.cacheBindingLoading = YES; self.cacheBindingAttempted = YES; NSUInteger generation = self.generation;
  NSString *base = LBBase(self.baseURL), *token = self.token;
  [LBMemosDiskCache loadBindingForBase:base token:token done:^(NSNumber *uid) {
    if (generation != self.generation) return;
    self.cacheBindingLoading = NO;
    if (!uid || self.diskCache || self.authenticationRequired) return;
    LBMemosDiskCache *cache = [[LBMemosDiskCache alloc] initWithBase:base userID:uid];
    self.diskCache = cache;
    [cache load:^(NSError *error) {
      if (generation != self.generation || cache != self.diskCache) return;
      self.cacheLoaded = YES; self.cacheError = error; [self cacheIndexResources]; [self cacheNotify];
      // Intentionally DO NOT set self.user. ready/beginWrite still reject.
    }];
  }];
}
- (void)cacheNotify {
  NSAssert(NSThread.isMainThread, @"Main queue confinement");
  [NSNotificationCenter.defaultCenter postNotificationName:LBMemosCacheDidChange object:self userInfo:[self cacheProgress]];
}
- (NSArray<NSDictionary *> *)cachedState:(NSString *)state {
  return LBOnMain(^id{
    [self cacheLoadBoundIdentity];
    if (!self.configured || self.authenticationRequired || !LBState(state) || !self.cacheLoaded) return nil;
    return self.diskCache.snapshots[state];
  });
}
- (NSURL *)cachedResource:(NSDictionary *)resource {
  return LBOnMain(^id{
    [self cacheLoadBoundIdentity];
    if (!self.configured || self.authenticationRequired || !self.cacheLoaded) return nil;
    NSDictionary *clean = LBResource(resource);
    return clean && [clean[@"creatorId"] isEqual:self.diskCache.userID] ? [self.diskCache resourceURL:clean] : nil;
  });
}
- (NSDictionary *)cacheProgress {
  return LBOnMain(^id{
    // O(1): no main-thread filesystem checks or all-resource scan on each
    // transfer notification. Sets are reconciled once per full snapshot.
    NSMutableDictionary *progress = [@{@"total":@(self.cacheResources.count), @"completed":@(self.cacheCompleted.count), @"failed":@(self.cacheFailures.count), @"running":@(self.cacheDownloads.count > 0 || self.cacheBindingLoading || (self.diskCache && !self.cacheLoaded) || self.cacheReconciling)} mutableCopy];
    if (self.cacheError) { progress[@"message"] = self.cacheError.localizedDescription; progress[@"error"] = @YES; }
    return progress;
  });
}
- (void)reconcileCacheNormal:(NSArray<NSDictionary *> *)normal archived:(NSArray<NSDictionary *> *)archived {
  LB_MAIN_RETURN([self reconcileCacheNormal:normal archived:archived]);
  if ([self ready] || !self.diskCache) return;
  // Proof is issued only by successful UNFILTERED allState in this exact write
  // epoch. A caller cannot accidentally prune from pages/filters/stale rows.
  if (self.cacheProofEpoch != self.epoch || ![self.cacheVerifiedStates[@"NORMAL"] isEqual:normal] || ![self.cacheVerifiedStates[@"ARCHIVED"] isEqual:archived]) {
    self.cacheError = LBErr(4091, @"完整同步快照已过期，附件尚未清理；请重新同步。"); [self cacheNotify]; return;
  }
  NSMutableDictionary *resources = [NSMutableDictionary dictionary]; NSMutableDictionary *byID = [NSMutableDictionary dictionary];
  for (NSArray *rows in @[normal, archived]) for (NSDictionary *memo in rows) for (NSDictionary *resource in memo[@"resourceList"]) {
    NSString *key = [LBMemosDiskCache fingerprint:resource];
    NSString *old = byID[resource[@"id"]];
    if (!key || (old && ![old isEqual:key])) { self.cacheError = LBErr(4091, @"同步期间附件发生变化，请重新同步。"); [self cacheNotify]; return; }
    resources[key] = resource; byID[resource[@"id"]] = key;
  }
  self.cachePrefetching = NO; self.cacheReconciling = YES;
  // Retire stale queued jobs BEFORE the ordered IO commit/prune. A transfer
  // already installing on io precedes pruning; later callbacks cannot insert.
  for (NSString *key in self.cacheDownloads.allKeys) if (!resources[key]) {
    LBMemosCachedDownload *job = self.cacheDownloads[key]; [job.task cancel];
    [self cacheFinish:job key:key url:nil error:LBStale()];
  }
  self.cacheResources = resources;
  [self.cacheCompleted intersectSet:[NSSet setWithArray:resources.allKeys]];
  [self.cacheFailures intersectSet:[NSSet setWithArray:resources.allKeys]];
  LBMemosDiskCache *cache = self.diskCache; NSUInteger generation = self.generation, epoch = self.epoch;
  [cache reconcileNormal:normal archived:archived done:^(NSError *error) {
    if (cache != self.diskCache || generation != self.generation) return;
    self.cacheReconciling = NO;
    if (epoch != self.epoch) { self.cacheError = LBStale(); [self cacheNotify]; return; }
    self.cacheError = error;
    if (!error) [self prefetchAllResources]; else { [self cacheNotify]; [self cachePump]; }
  }];
  [self cacheNotify];
}
- (void)prefetchAllResources {
  LB_MAIN_RETURN([self prefetchAllResources]);
  if ([self ready] || !self.diskCache) return;
  // Explicit call/full sync retries failed files; the pump itself never retries
  // failures in a loop. No allState recursion, and ALL MIME types participate.
  self.cachePrefetching = YES; [self.cacheFailures removeAllObjects]; self.cacheError = nil;
  [self.cacheCompleted removeAllObjects];
  for (NSString *key in self.cacheResources) {
    NSDictionary *r = self.cacheResources[key];
    if ([self.diskCache resourceURL:r]) { [self.cacheCompleted addObject:key]; continue; }
    if (self.cacheDownloads[key]) continue;
    if ([r[@"size"] unsignedLongLongValue] > LBFileCap) { [self.cacheFailures addObject:key]; self.cacheError = LBErr(1005, @"部分附件超过 32 MiB 安全上限，未缓存；释放空间或处理附件后重试。"); continue; }
    LBMemosCachedDownload *job = [LBMemosCachedDownload new]; job.resource = r; job.generation = self.generation; job.callbacks = [NSMutableArray array];
    self.cacheDownloads[key] = job;
  }
  [self cacheNotify]; [self cachePump];
}
- (void)cacheFinish:(LBMemosCachedDownload *)job key:(NSString *)key url:(NSURL *)url error:(NSError *)error {
  if (self.cacheDownloads[key] != job) return;
  [self.cacheDownloads removeObjectForKey:key];
  if (job.started && self.cacheActive) self.cacheActive--;
  if (error) { if (self.cacheResources[key]) [self.cacheFailures addObject:key]; self.cacheError = error; }
  else { [self.cacheFailures removeObject:key]; if (self.cacheResources[key]) [self.cacheCompleted addObject:key]; }
  if (!self.cacheDownloads.count && !self.cacheFailures.count && !error) self.cacheError = nil;
  NSArray *callbacks = [job.callbacks copy]; [job.callbacks removeAllObjects];
  for (void (^callback)(NSURL *, NSError *) in callbacks) callback(url, error);
  [self cacheNotify]; [self cachePump];
}
- (void)cachePump {
  if ([self ready] || !self.diskCache || self.cacheReconciling) return;
  // Includes capacity checks and atomic installation in the two-worker limit.
  for (NSString *key in self.cacheDownloads.allKeys) {
    if (self.cacheActive >= 2) break;
    LBMemosCachedDownload *job = self.cacheDownloads[key]; if (job.started) continue;
    job.started = YES; self.cacheActive++;
    LBMemosDiskCache *cache = self.diskCache; NSUInteger epoch = self.epoch;
    [cache checkCapacityForResource:job.resource done:^(NSError *capacityError) {
      if (cache != self.diskCache || self.cacheDownloads[key] != job) return;
      if (capacityError || epoch != self.epoch) { [self cacheFinish:job key:key url:nil error:capacityError ?: LBStale()]; return; }
      NSURL *output = [self tempWithName:@"cache-download"];
      // An ID always wins over externalLink: same-origin /api/v1/resource/%@/file.
      job.task = [self request:@"GET" path:[NSString stringWithFormat:@"/api/v1/resource/%@/file", job.resource[@"id"]] query:nil json:nil bodyFile:nil contentType:nil download:output mutation:NO progress:nil done:^(id raw, NSInteger status, NSError *error) {
        (void)status;
        if (cache != self.diskCache || self.cacheDownloads[key] != job) {
          if ([raw isKindOfClass:NSURL.class]) { [self.temporaryFiles removeObject:raw]; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [NSFileManager.defaultManager removeItemAtURL:raw error:NULL]; }); }
          return;
        }
        if (error || epoch != self.epoch) {
          if (raw) { [self.temporaryFiles removeObject:raw]; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [NSFileManager.defaultManager removeItemAtURL:raw error:NULL]; }); }
          [self cacheFinish:job key:key url:nil error:error ?: LBStale()]; return;
        }
        // Transfer ownership before reset can unlink staging files. Cache IO
        // owns staging from here; no successful persistent URL is temporary.
        [self.temporaryFiles removeObject:raw];
        [cache installFile:raw resource:job.resource isCurrent:^BOOL{
          return cache == self.diskCache && self.cacheDownloads[key] == job && epoch == self.epoch;
        } done:^(NSURL *url, NSError *installError) {
          if (cache != self.diskCache || self.cacheDownloads[key] != job) return;
          [self cacheFinish:job key:key url:(epoch == self.epoch ? url : nil) error:(epoch == self.epoch ? installError : LBStale())];
        }];
      }];
      self.transfers[@(job.task.taskIdentifier)].expectedType = job.resource[@"type"];
    }];
  }
}
- (void)invalidateCachedResource:(NSDictionary *)resource {
  LB_MAIN_RETURN([self invalidateCachedResource:resource]);
  if (!self.configured || self.authenticationRequired || !self.cacheLoaded) return;
  NSDictionary *clean = LBResource(resource); if (!clean || ![clean[@"creatorId"] isEqual:self.diskCache.userID]) return;
  NSString *key = [LBMemosDiskCache fingerprint:clean]; LBMemosCachedDownload *job = self.cacheDownloads[key];
  if (job) { [job.task cancel]; [self cacheFinish:job key:key url:nil error:LBStale()]; }
  [self.cacheCompleted removeObject:key]; if (self.cacheResources[key]) [self.cacheFailures addObject:key]; self.cacheError = LBErr(1102, @"附件无法解码，已清除本地副本；请重试下载。");
  LBMemosDiskCache *cache = self.diskCache;
  [cache invalidateResource:clean done:^{ if (cache == self.diskCache) [self cacheNotify]; }];
}

@end
