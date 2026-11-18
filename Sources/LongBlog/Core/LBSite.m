#import "LB.h"
#import "LBMdStore.h"
#import "LBPlatform.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

static NSDictionary *dict(id v) { return [v isKindOfClass:NSDictionary.class] ? v : nil; }
static NSString *str(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }
static NSNumber *num(id v) { return [v isKindOfClass:NSNumber.class] ? v : @0; }

NSString *const LBSiteDataDidChange = @"LBSiteDataDidChange";

#pragma mark - Keychain
@implementation LBKeychain
// Login-Keychain reads of an ad-hoc signed app can block on a system permission
// dialog (every new build has a new code signature). Read each item at most once
// per launch and serve later lookups from memory so the UI never stalls repeatedly.
static NSMutableDictionary<NSString *, id> *LBKeychainCache(void) {
  static NSMutableDictionary *cache; static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
  return cache;
}
+ (NSDictionary *)query:(NSString *)account {
  return @{ (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService : LBAppNamespace(),
            (__bridge id)kSecAttrAccount : account };
}
+ (NSString *)get:(NSString *)account {
  NSMutableDictionary *cache = LBKeychainCache();
  @synchronized (cache) {
    id cached = cache[account];
    if (cached) return cached == NSNull.null ? nil : cached;
    NSMutableDictionary *q = [[self query:account] mutableCopy];
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef out = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
    NSString *value = nil;
    if (status == errSecSuccess && out) value = [[NSString alloc] initWithData:(__bridge_transfer NSData *)out encoding:NSUTF8StringEncoding];
    else if (out) CFRelease(out);
    // Denied/cancelled prompts are remembered too: asking again would freeze the UI again.
    cache[account] = value ?: NSNull.null;
    return value;
  }
}
+ (void)set:(NSString *)value account:(NSString *)account {
  NSString *t = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if ([[self get:account] ?: @"" isEqualToString:t ?: @""]) return;
  NSMutableDictionary *cache = LBKeychainCache();
  @synchronized (cache) { [cache removeObjectForKey:account]; }
  if (!t.length) { SecItemDelete((__bridge CFDictionaryRef)[self query:account]); return; }
  NSDictionary *update = @{ (__bridge id)kSecValueData : [t dataUsingEncoding:NSUTF8StringEncoding] };
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)[self query:account], (__bridge CFDictionaryRef)update);
  if (status != errSecItemNotFound) return;
  NSMutableDictionary *q = [[self query:account] mutableCopy];
  q[(__bridge id)kSecValueData] = [t dataUsingEncoding:NSUTF8StringEncoding];
  // macOS login Keychain access follows its unlock state and item ACL.
  // Do not set iOS-only data-protection accessibility attributes.
  q[(__bridge id)kSecAttrSynchronizable] = @NO;
  SecItemAdd((__bridge CFDictionaryRef)q, NULL);
}
@end

#pragma mark - Preferences
@implementation LBStore
static NSString *pref(NSString *k, NSString *fallback) {
  NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:k];
  return v.length ? v : fallback;
}
static void setPref(NSString *k, NSString *v) {
  NSString *t = [v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  while ([t hasSuffix:@"/"]) t = [t substringToIndex:t.length - 1];
  if (t.length) [NSUserDefaults.standardUserDefaults setObject:t forKey:k];
  else [NSUserDefaults.standardUserDefaults removeObjectForKey:k];
}
+ (NSString *)siteURL { return pref(@"LBSiteURL", @"https://huowenlong.com"); }
+ (void)setSiteURL:(NSString *)v { setPref(@"LBSiteURL", v); }
+ (NSString *)repo { return pref(@"LBRepo", @"minlonghuo-lab/longBlog"); }
+ (void)setRepo:(NSString *)v { setPref(@"LBRepo", v); }
+ (NSArray<NSString *> *)certHosts {
  NSString *raw = pref(@"LBCertHosts", @"huowenlong.com, shuoshuo.huowenlong.com, shuoshuo.ssaw.top");
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *p in [raw componentsSeparatedByString:@","]) {
    NSString *h = [p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (h.length && ![out containsObject:h]) [out addObject:h];
  }
  return out;
}
+ (void)setCertHosts:(NSString *)v { setPref(@"LBCertHosts", v); }
@end

#pragma mark - HTTP
@interface LBCertProbe : NSObject <NSURLSessionDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, strong) NSDate *expiry;
@end
@implementation LBCertProbe
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
  completion(nil); // Measure this host's certificate, not the redirect destination.
}
- (void)URLSession:(NSURLSession *)s didReceiveChallenge:(NSURLAuthenticationChallenge *)c
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))done {
  SecTrustRef trust = c.protectionSpace.serverTrust;
  if (trust && [c.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    if (chain && CFArrayGetCount(chain) > 0) {
      SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
      // Public macOS API, available before the macOS 14 deployment target.
      CFErrorRef error = NULL;
      CFDictionaryRef values = SecCertificateCopyValues(leaf,
        (__bridge CFArrayRef)@[(__bridge id)kSecOIDX509V1ValidityNotAfter], &error);
      if (values) {
        NSDictionary *properties = (__bridge NSDictionary *)values;
        id value = properties[(__bridge id)kSecOIDX509V1ValidityNotAfter][(__bridge id)kSecPropertyKeyValue];
        if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]))
          self.expiry = [NSDate dateWithTimeIntervalSinceReferenceDate:[value doubleValue]];
        else if ([value isKindOfClass:NSDate.class]) self.expiry = value;
        CFRelease(values);
      }
      if (error) CFRelease(error);
    }
    if (chain) CFRelease(chain);
  }
  // Read the date only; let the system evaluate trust normally.
  done(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

@implementation LBHTTP
static NSURLSession *sharedSession(void) {
  static NSURLSession *s; static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    c.timeoutIntervalForRequest = 20;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    s = [NSURLSession sessionWithConfiguration:c];
  });
  return s;
}
static NSError *httpErr(NSInteger code, NSString *msg) {
  return [NSError errorWithDomain:@"LBHTTP" code:code userInfo:@{ NSLocalizedDescriptionKey : msg }];
}
+ (void)JSON:(NSString *)method url:(NSURL *)url headers:(NSDictionary *)headers body:(NSDictionary *)body
        done:(void (^)(id, NSInteger, NSError *))done {
  void (^finish)(id, NSInteger, NSError *) = ^(id j, NSInteger st, NSError *e) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(j, st, e); });
  };
  if (!url || ![url.scheme isEqualToString:@"https"]) return finish(nil, 0, httpErr(400, @"地址必须是 HTTPS"));
  NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
  r.HTTPMethod = method;
  r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  [headers enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { [r setValue:v forHTTPHeaderField:k]; }];
  if (body) {
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  }
  [[sharedSession() dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
    if (error) return finish(nil, 0, httpErr(-1, @"网络不可用"));
    NSInteger st = [(NSHTTPURLResponse *)resp statusCode];
    id j = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (st < 200 || st >= 300) {
      NSString *m = [j isKindOfClass:NSDictionary.class] && [j[@"message"] isKindOfClass:NSString.class] ? j[@"message"] : nil;
      return finish(j, st, httpErr(st, m ? [NSString stringWithFormat:@"%@（%ld）", m, (long)st] : [NSString stringWithFormat:@"请求失败（%ld）", (long)st]));
    }
    if (!j) return finish(nil, st, httpErr(st, @"返回内容不是 JSON"));
    finish(j, st, nil);
  }] resume];
}
+ (void)certificateExpiry:(NSString *)host done:(void (^)(NSDate *, NSError *))done {
  LBCertProbe *probe = [LBCertProbe new];
  NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  c.timeoutIntervalForRequest = 12;
  c.timeoutIntervalForResource = 15;
  c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  NSURLSession *s = [NSURLSession sessionWithConfiguration:c delegate:probe delegateQueue:nil];
  NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/", host]]];
  r.HTTPMethod = @"HEAD";
  [[s dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
    NSDate *exp = probe.expiry;
    [s finishTasksAndInvalidate];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (exp && !e) done(exp, nil);
      else done(nil, httpErr(-1, e ? @"无法建立 HTTPS 连接" : @"未读到证书"));
    });
  }] resume];
}
+ (void)image:(NSURL *)url done:(void (^)(NSImage *))done {
  static NSCache *cache; static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 120; });
  if (!url) return done(nil);
  NSImage *hit = [cache objectForKey:url];
  if (hit) return done(hit);
  [[sharedSession() dataTaskWithURL:url completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
    NSImage *img = d ? [[NSImage alloc] initWithData:d] : nil;
    if (img) [cache setObject:img forKey:url];
    dispatch_async(dispatch_get_main_queue(), ^{ done(img); });
  }] resume];
}
@end

#pragma mark - GitHub
static BOOL GHSafePath(NSString *path) {
  if (![path isKindOfClass:NSString.class] || !path.length || [path hasPrefix:@"/"] || [path containsString:@"\\"] || [path containsString:@"%"] || [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
  for (NSString *part in [path componentsSeparatedByString:@"/"])
    if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
  return YES;
}
static BOOL GHSHA(NSString *sha) {
  return [sha isKindOfClass:NSString.class] && sha.length == 40 && [sha rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
static NSString *GHBlobSHA(NSData *data) {
  NSString *header = [NSString stringWithFormat:@"blob %lu", (unsigned long)data.length];
  NSMutableData *object = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  unsigned char zero = 0; [object appendBytes:&zero length:1]; [object appendData:data];
  unsigned char digest[CC_SHA1_DIGEST_LENGTH]; CC_SHA1(object.bytes, (CC_LONG)object.length, digest);
  NSMutableString *sha = [NSMutableString string];
  for (NSUInteger i = 0; i < sizeof(digest); i++) [sha appendFormat:@"%02x", digest[i]];
  return sha;
}
// Pure policy functions are also compiled by the offline fault-injection tests.
// GH_POLICY_BEGIN
static double GHRequestTimeout(int binary) { return binary ? 60.0 : 8.0; }
static double GHResourceTimeout(int binary) { return binary ? 120.0 : 10.0; }
static double GHRequestBudget(int binary) { return binary ? 132.0 : 24.0; }
static int GHRetryableStatus(long status) { return status == 429 || (status >= 500 && status <= 599); }
static double GHRetryDelay(unsigned attempt, double retryAfter, double jitter) {
  // A long Retry-After is NOT shortened and retried early: fail promptly instead.
  if (attempt >= 2 || retryAfter > 5.0) return -1.0;
  double backoff = (attempt ? 1.0 : 0.5) + jitter * 0.25;
  return retryAfter > backoff ? retryAfter : backoff;
}
// comparison: 1 = desired is an ancestor of head; 0 = proven unrelated/behind; -1 = unknown.
static int GHConfirmedState(int sameDesired, int sameBase, int comparison) {
  if (sameDesired) return 1;
  if (sameBase) return 0;
  return comparison == 1 ? 1 : (comparison == 0 ? 2 : -1);
}
// GH_POLICY_END
static NSUInteger GHCredentialGeneration;
static BOOL GHTransientNetwork(NSError *error) {
  if (![error.domain isEqual:NSURLErrorDomain]) return NO;
  switch (error.code) {
    case NSURLErrorTimedOut: case NSURLErrorCannotFindHost: case NSURLErrorCannotConnectToHost:
    case NSURLErrorNetworkConnectionLost: case NSURLErrorDNSLookupFailed: case NSURLErrorNotConnectedToInternet:
    case NSURLErrorResourceUnavailable: return YES;
    default: return NO; // cancellation, TLS/certificate and policy failures are not transient.
  }
}
static NSTimeInterval GHRetryAfter(NSHTTPURLResponse *response) {
  NSString *value = [response valueForHTTPHeaderField:@"Retry-After"];
  if (!value.length) return 0;
  NSScanner *scanner = [NSScanner scannerWithString:value]; double seconds = 0;
  if ([scanner scanDouble:&seconds] && scanner.isAtEnd) return isfinite(seconds) && seconds >= 0 ? seconds : 6;
  NSDateFormatter *formatter = [NSDateFormatter new]; formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0]; formatter.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss z";
  NSDate *date = [formatter dateFromString:value];
  return date ? MAX(0, date.timeIntervalSinceNow) : 6;
}
// Main-queue retry token bucket, shared across all frozen clients. Never a retry storm.
static BOOL GHReserveRetry(void) {
  static NSTimeInterval window; static NSUInteger used;
  NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (now - window >= 30) { window = now; used = 0; }
  if (used >= 6) return NO;
  used++; return YES;
}
// Never forward a bearer token on redirects, even to another GitHub URL.
@interface LBGitTransport : NSObject <NSURLSessionTaskDelegate>
@end
@implementation LBGitTransport
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion { completion(nil); }
@end
@interface LBGitHub ()
@property (nonatomic, copy) NSString *frozenRepository;
@property (nonatomic, copy) NSString *frozenToken;
@property (nonatomic) NSUInteger credentialGeneration;
@property (nonatomic, strong) NSURLSession *transportSession, *binarySession;
@property (nonatomic, copy) NSString *credentialID;
- (NSURLSession *)sessionForBinary:(BOOL)binary;
- (BOOL)identityCurrent;
- (void)request:(NSString *)method suffix:(NSString *)suffix body:(NSDictionary *)body done:(void (^)(NSDictionary *, NSError *))done;
@end
@interface LBGitRequestTask : NSObject
@property (nonatomic, strong) LBGitHub *github;
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, copy) void (^done)(NSDictionary *, NSError *);
@property (nonatomic) NSUInteger attempt;
@property (nonatomic) NSTimeInterval started;
@property (nonatomic) BOOL binary;
- (void)start;
@end
@interface LBGitCommitTask : NSObject
@property (nonatomic, strong) LBGitHub *github;
@property (nonatomic, copy) NSDictionary *changes, *snapshot;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) void (^done)(NSDictionary *, NSError *);
@property (nonatomic, copy) BOOL (^prepared)(NSDictionary *, NSError **);
@property (nonatomic, strong) NSArray *paths;
@property (nonatomic, strong) NSMutableArray *entries;
@property (nonatomic, strong) NSMutableDictionary *shas;
@property (nonatomic) NSUInteger index;
- (void)next;
@end
@implementation LBGitHub
+ (instancetype)shared {
  static LBGitHub *g; static dispatch_once_t once;
  dispatch_once(&once, ^{ g = [LBGitHub new]; }); return g;
}
- (instancetype)initWithRepository:(NSString *)repository {
  if ((self = [super init])) {
    _frozenRepository = [repository copy]; _frozenToken = [[LBKeychain get:@"github-token"] copy] ?: @""; _credentialGeneration = GHCredentialGeneration;
    NSString *identity = [LBKeychain get:@"github-credential-id"];
    if (!identity.length) { identity = NSUUID.UUID.UUIDString; [LBKeychain set:identity account:@"github-credential-id"]; }
    _credentialID = [identity copy];
  } return self;
}
- (void)dealloc { [_transportSession invalidateAndCancel]; [_binarySession invalidateAndCancel]; }
- (NSURLSession *)sessionForBinary:(BOOL)binary {
  NSURLSession *session = binary ? self.binarySession : self.transportSession;
  if (!session) {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = GHRequestTimeout(binary); config.timeoutIntervalForResource = GHResourceTimeout(binary);
    config.URLCache = nil; config.HTTPCookieStorage = nil; config.URLCredentialStorage = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.HTTPShouldSetCookies = NO; config.HTTPMaximumConnectionsPerHost = 2;
    config.waitsForConnectivity = NO;
    session = [NSURLSession sessionWithConfiguration:config delegate:[LBGitTransport new] delegateQueue:nil];
    if (binary) self.binarySession = session; else self.transportSession = session;
  }
  return session;
}
- (BOOL)identityCurrent {
  return !self.frozenRepository || (self.credentialGeneration == GHCredentialGeneration &&
    [self.frozenRepository.lowercaseString isEqual:LBStore.repo.lowercaseString] &&
    [self.frozenToken isEqual:([LBKeychain get:@"github-token"] ?: @"")] &&
    [self.credentialID isEqual:[LBKeychain get:@"github-credential-id"]]);
}
- (NSString *)repository { return self.frozenRepository ?: LBStore.repo; }
- (NSString *)token { return self.frozenRepository ? self.frozenToken : [LBKeychain get:@"github-token"]; }
- (void)setToken:(NSString *)token {
  if (!self.frozenRepository) {
    if (![(self.token ?: @"") isEqual:(token ?: @"")]) {
      GHCredentialGeneration++;
      // Random local identifier, never the token or its hash. Old pending belongs to old credentials.
      [LBKeychain set:NSUUID.UUID.UUIDString account:@"github-credential-id"];
    }
    [LBKeychain set:token account:@"github-token"];
  }
}
- (BOOL)matchesPendingIdentity:(NSDictionary *)pending {
  if (!self.frozenRepository) return [[[LBGitHub alloc] initWithRepository:self.repository] matchesPendingIdentity:pending];
  NSString *identity = str(pending[@"credentialID"]);
  return [self identityCurrent] && identity.length && [identity isEqual:self.credentialID] &&
    [identity isEqual:[LBKeychain get:@"github-credential-id"]] &&
    [str(pending[@"repository"]).lowercaseString isEqual:self.repository.lowercaseString];
}
- (BOOL)configured { return self.token.length > 0; }
- (NSDictionary *)headers {
  NSMutableDictionary *h = [@{ @"Accept": @"application/vnd.github+json", @"X-GitHub-Api-Version": @"2022-11-28" } mutableCopy];
  if (self.token.length) h[@"Authorization"] = [@"Bearer " stringByAppendingString:self.token]; return h;
}
- (NSURL *)api:(NSString *)suffix {
  NSArray *parts = [self.repository componentsSeparatedByString:@"/"];
  if (parts.count != 2) return nil;
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."];
  for (NSString *p in parts) if (!p.length || [p isEqual:@"."] || [p isEqual:@".."] || [p rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
  NSString *enc = [suffix stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/"]];
  return [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@%@", self.repository, enc]];
}
- (void)request:(NSString *)method suffix:(NSString *)suffix body:(NSDictionary *)body done:(void (^)(NSDictionary *, NSError *))done {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self request:method suffix:suffix body:body done:done]; }); return; }
  if (!self.frozenRepository) { [[[LBGitHub alloc] initWithRepository:self.repository] request:method suffix:suffix body:body done:done]; return; }
  if (![self identityCurrent]) return done(nil, httpErr(-999, @"GitHub 账号或仓库已变更，操作已停止"));
  BOOL recursive = [suffix hasSuffix:@"?recursive=1"];
  NSString *plain = recursive ? [suffix substringToIndex:suffix.length - @"?recursive=1".length] : suffix;
  NSURL *url = [self api:plain];
  if (recursive && url) { NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO]; c.queryItems = @[[NSURLQueryItem queryItemWithName:@"recursive" value:@"1"]]; url = c.URL; }
  if (!url || !self.configured) { dispatch_async(dispatch_get_main_queue(), ^{ done(nil, httpErr(400, @"GitHub 仓库或令牌未配置")); }); return; }
  NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url]; r.HTTPMethod = method;
  [self.headers enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { [r setValue:v forHTTPHeaderField:k]; }];
  if (body) { r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil]; [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; }
  // Blob GET size is unknown until headers arrive; allow existing large media to finish.
  // Large content/tree bodies also use bounded media timeouts, never a write retry.
  BOOL binary = [plain isEqual:@"/git/blobs"] || [plain hasPrefix:@"/git/blobs/"] || r.HTTPBody.length > 256 * 1024;
  r.timeoutInterval = GHRequestTimeout(binary); r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData; r.HTTPShouldHandleCookies = NO;
  LBGitRequestTask *task = [LBGitRequestTask new]; task.github = self; task.request = r; task.done = done; task.binary = binary;
  task.started = NSProcessInfo.processInfo.systemUptime; [task start];
}
- (void)getBlobData:(NSString *)sha done:(void (^)(NSData *, NSError *))done {
  if (!GHSHA(sha)) return done(nil, httpErr(400, @"无效 Blob SHA"));
  [self request:@"GET" suffix:[@"/git/blobs/" stringByAppendingString:sha] body:nil done:^(NSDictionary *j, NSError *e) {
    if (e) return done(nil, e);
    NSString *content = str(j[@"content"]);
    NSString *clean = [[content componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    NSData *data = [str(j[@"encoding"]) isEqual:@"base64"] ? [[NSData alloc] initWithBase64EncodedString:clean options:0] : nil;
    if (!data || ![str(j[@"sha"]) isEqual:sha] || ![GHBlobSHA(data) isEqual:sha]) return done(nil, httpErr(500, @"GitHub 二进制内容异常"));
    done(data, nil);
  }];
}
- (void)getData:(NSString *)path ref:(NSString *)ref done:(void (^)(NSData *, NSString *, NSError *))done {
  if (!GHSafePath(path) || !GHSHA(ref)) return done(nil, nil, httpErr(400, @"读取需要安全路径与固定提交 SHA"));
  if (!self.frozenRepository) { [[[LBGitHub alloc] initWithRepository:self.repository] getData:path ref:ref done:done]; return; }
  [self request:@"GET" suffix:[NSString stringWithFormat:@"/git/commits/%@", ref] body:nil done:^(NSDictionary *commit, NSError *ce) {
    if (ce) return done(nil, nil, ce);
    NSString *treeSHA = str(dict(commit[@"tree"])[@"sha"]);
    if (!GHSHA(treeSHA)) return done(nil, nil, httpErr(500, @"Commit tree SHA 异常"));
    [self request:@"GET" suffix:[@"/git/trees/" stringByAppendingString:treeSHA] body:nil done:^(NSDictionary *j, NSError *e) {
      if (e) return done(nil, nil, e);
      [self dataAtPath:path components:[path componentsSeparatedByString:@"/"] tree:j index:0 done:done];
    }];
  }];
}
- (void)dataAtPath:(NSString *)path components:(NSArray *)parts tree:(NSDictionary *)tree index:(NSUInteger)index done:(void (^)(NSData *, NSString *, NSError *))done {
  if ([tree[@"truncated"] boolValue]) return done(nil, nil, httpErr(413, @"Git tree 被截断"));
  NSDictionary *hit = nil;
  for (NSDictionary *entry in tree[@"tree"]) if ([str(entry[@"path"]) isEqual:parts[index]]) { hit = entry; break; }
  if (!hit) return done(nil, nil, httpErr(404, @"文件不存在"));
  NSString *sha = str(hit[@"sha"]);
  if (index + 1 == parts.count) {
    if (![str(hit[@"type"]) isEqual:@"blob"] || ![str(hit[@"mode"]) isEqual:@"100644"]) return done(nil, nil, httpErr(400, @"不是普通文件"));
    [self getBlobData:sha done:^(NSData *d, NSError *e) { done(d, e ? nil : sha, e); }];
  } else {
    if (![str(hit[@"type"]) isEqual:@"tree"] || !GHSHA(sha)) return done(nil, nil, httpErr(400, @"不是目录"));
    [self request:@"GET" suffix:[@"/git/trees/" stringByAppendingString:sha] body:nil done:^(NSDictionary *j, NSError *e) {
      if (e) return done(nil, nil, e);
      [self dataAtPath:path components:parts tree:j index:index + 1 done:done];
    }];
  }
}
- (void)getFile:(NSString *)path done:(void (^)(NSString *, NSString *, NSError *))done { [self getFile:path ref:@"main" done:done]; }
- (void)getFile:(NSString *)path ref:(NSString *)ref done:(void (^)(NSString *, NSString *, NSError *))done {
  if (!self.frozenRepository) { LBGitHub *g = [[LBGitHub alloc] initWithRepository:self.repository]; [g getFile:path ref:ref done:done]; return; }
  if ([ref isEqual:@"main"]) { [self headCommit:^(NSDictionary *h, NSError *e) { if (e) return done(nil, nil, e); [self getFile:path ref:h[@"sha"] done:done]; }]; return; }
  [self getData:path ref:ref done:^(NSData *data, NSString *sha, NSError *e) {
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    done(text, sha, e ?: (!text ? httpErr(500, @"文件不是 UTF-8 文本") : nil));
  }];
}
- (void)headCommit:(void (^)(NSDictionary *, NSError *))done {
  [self request:@"GET" suffix:@"/commits/main" body:nil done:^(NSDictionary *j, NSError *e) {
    if (e) return done(nil, e);
    NSDictionary *commit = dict(j[@"commit"]), *committer = dict(commit[@"committer"]), *tree = dict(commit[@"tree"]);
    if (!GHSHA(j[@"sha"]) || !GHSHA(tree[@"sha"])) return done(nil, httpErr(500, @"提交信息异常"));
    done(@{@"sha":j[@"sha"], @"treeSHA":tree[@"sha"], @"message":str(commit[@"message"]), @"date":str(committer[@"date"]), @"url":str(j[@"html_url"])}, nil);
  }];
}
- (void)articleSnapshot:(void (^)(NSDictionary *, NSError *))done {
  if (!self.frozenRepository) { [[[LBGitHub alloc] initWithRepository:self.repository] articleSnapshot:done]; return; }
  [self headCommit:^(NSDictionary *head, NSError *e) {
    if (e) return done(nil, e);
    // The recursive parameter is constant, not user input.
    NSURL *url = [self api:[@"/git/trees/" stringByAppendingString:head[@"treeSHA"]]];
    (void)url;
    [self request:@"GET" suffix:[NSString stringWithFormat:@"/git/trees/%@?recursive=1", head[@"treeSHA"]] body:nil done:^(NSDictionary *j, NSError *err) {
      if (err) return done(nil, err);
      if ([j[@"truncated"] boolValue]) return done(nil, httpErr(413, @"Git tree 被截断，未同步任何文章"));
      if (![j[@"tree"] isKindOfClass:NSArray.class]) return done(nil, httpErr(500, @"Git tree 格式异常"));
      NSMutableDictionary *files = [NSMutableDictionary dictionary];
      for (NSDictionary *entry in j[@"tree"]) {
        NSString *path = str(entry[@"path"]);
        if (![str(entry[@"type"]) isEqual:@"blob"]) continue;
        if (!GHSafePath(path) || !GHSHA(entry[@"sha"])) return done(nil, httpErr(400, @"Git tree 包含不安全路径"));
        files[path] = entry;
      }
      done(@{@"head":head[@"sha"], @"treeSHA":head[@"treeSHA"], @"files":files}, nil);
    }];
  }];
}
- (void)confirmCommit:(NSString *)commit base:(NSString *)base done:(void (^)(NSDictionary *, NSError *))done {
  if (!self.frozenRepository) { [[[LBGitHub alloc] initWithRepository:self.repository] confirmCommit:commit base:base done:done]; return; }
  if (!GHSHA(commit) || !GHSHA(base)) return done(nil, httpErr(400, @"无效恢复提交 SHA"));
  [self request:@"GET" suffix:@"/git/ref/heads/main" body:nil done:^(NSDictionary *ref, NSError *error) {
    if (error) return done(nil, (error.code == -999 || error.code == 401 || error.code == 403) ? error : httpErr(-2, @"提交结果仍未知；已保留恢复记录，请稍后核对"));
    NSString *head = str(dict(ref[@"object"])[@"sha"]);
    if (!GHSHA(head)) return done(nil, httpErr(-2, @"分支响应异常，提交结果仍未知"));
    int state = GHConfirmedState([head isEqual:commit], [head isEqual:base], -1);
    if (state >= 0) return done(@{@"state":state == 1 ? @"applied" : @"unchanged", @"head":head}, nil);
    // Compare immutable SHAs, not a moving main. A later normal advance still proves success.
    [self request:@"GET" suffix:[NSString stringWithFormat:@"/compare/%@...%@", commit, head] body:nil done:^(NSDictionary *comparison, NSError *ce) {
      if (ce) return done(nil, (ce.code == -999 || ce.code == 401 || ce.code == 403) ? ce : httpErr(-2, @"无法确认提交祖先关系，请稍后核对"));
      NSString *status = str(comparison[@"status"]), *mergeBase = str(dict(comparison[@"merge_base_commit"])[@"sha"]);
      if (![str(dict(comparison[@"base_commit"])[@"sha"]) isEqual:commit] || !GHSHA(mergeBase)) return done(nil, httpErr(-2, @"提交比较响应异常，结果仍未知"));
      BOOL included = ([status isEqual:@"ahead"] || [status isEqual:@"identical"]) && [mergeBase isEqual:commit];
      BOOL excluded = [status isEqual:@"behind"] || [status isEqual:@"diverged"];
      int confirmed = GHConfirmedState(0, 0, included ? 1 : (excluded ? 0 : -1));
      if (confirmed < 0) return done(nil, httpErr(-2, @"提交祖先关系响应异常，结果仍未知"));
      done(@{@"state":confirmed == 1 ? @"applied" : @"conflict", @"head":head}, nil);
    }];
  }];
}
- (void)commitChanges:(NSDictionary<NSString *,id> *)changes snapshot:(NSDictionary *)snapshot message:(NSString *)message done:(void (^)(NSDictionary *, NSError *))done {
  [self commitChanges:changes snapshot:snapshot message:message prepared:nil done:done];
}
- (void)commitChanges:(NSDictionary<NSString *,id> *)changes snapshot:(NSDictionary *)snapshot message:(NSString *)message prepared:(BOOL (^)(NSDictionary *, NSError **))prepared done:(void (^)(NSDictionary *, NSError *))done {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self commitChanges:changes snapshot:snapshot message:message prepared:prepared done:done]; }); return; }
  LBGitCommitTask *task = [LBGitCommitTask new]; task.github = self.frozenRepository ? self : [[LBGitHub alloc] initWithRepository:self.repository];
  task.changes = changes; task.snapshot = snapshot; task.message = message; task.done = done; task.prepared = prepared;
  task.paths = [[changes allKeys] sortedArrayUsingSelector:@selector(compare:)]; task.entries = [NSMutableArray array]; task.shas = [NSMutableDictionary dictionary];
  if (!GHSHA(snapshot[@"head"]) || !GHSHA(snapshot[@"treeSHA"]) || !changes.count) return done(nil, httpErr(400, @"缺少提交基线或变更"));
  for (NSString *path in task.paths) {
    if (!GHSafePath(path) || (![path hasPrefix:@"content/posts/"] && ![path hasPrefix:@"public/assets/"]) || (![changes[path] isKindOfClass:NSData.class] && changes[path] != NSNull.null)) return done(nil, httpErr(400, @"提交路径或数据不安全"));
  }
  [task next];
}
- (void)putFile:(NSString *)path text:(NSString *)text sha:(NSString *)sha message:(NSString *)message done:(void (^)(NSString *, NSError *))done {
  NSMutableDictionary *body = [@{@"message":message ?: @"update file", @"branch":@"main", @"content":[[text dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]} mutableCopy];
  if (sha.length) body[@"sha"] = sha;
  if (!GHSafePath(path)) return done(nil, httpErr(400, @"无效文件路径"));
  [self request:@"PUT" suffix:[@"/contents/" stringByAppendingString:path] body:body done:^(NSDictionary *j, NSError *e) { NSString *commit = dict(j[@"commit"])[@"sha"]; done(commit, e ?: (!GHSHA(commit) ? httpErr(500, @"提交结果无法确认") : nil)); }];
}
- (void)deleteFile:(NSString *)path sha:(NSString *)sha message:(NSString *)message done:(void (^)(NSError *))done {
  if (!self.frozenRepository) { [[[LBGitHub alloc] initWithRepository:self.repository] deleteFile:path sha:sha message:message done:done]; return; }
  if (!GHSafePath(path)) return done(httpErr(400, @"无效文件路径"));
  if (!sha.length) { [self getFile:path done:^(NSString *text, NSString *found, NSError *e) { if (e) return done(e.code == 404 ? nil : e); [self deleteFile:path sha:found message:message done:done]; }]; return; }
  [self request:@"DELETE" suffix:[@"/contents/" stringByAppendingString:path] body:@{@"message":message ?: @"delete file", @"branch":@"main", @"sha":sha} done:^(NSDictionary *j, NSError *e) { done(e); }];
}
@end
@implementation LBGitRequestTask
- (void)finish:(NSDictionary *)json error:(NSError *)error {
  void (^callback)(NSDictionary *, NSError *) = self.done; self.done = nil;
  if (callback) callback(error ? nil : json, error);
}
- (void)start {
  if (![self.github identityCurrent]) return [self finish:nil error:httpErr(-999, @"GitHub 账号或仓库已变更，操作已停止")];
  if (NSProcessInfo.processInfo.systemUptime - self.started >= GHRequestBudget(self.binary)) return [self finish:nil error:httpErr(-1, @"GitHub 网络重试已达时限，请稍后重试")];
  [[[self.github sessionForBinary:self.binary] dataTaskWithRequest:self.request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    NSInteger status = http.statusCode;
    NSDictionary *json = data ? dict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (![self.github identityCurrent]) return [self finish:nil error:httpErr(-999, @"GitHub 账号或仓库已变更，操作已停止")];
      BOOL transient = error ? GHTransientNetwork(error) : GHRetryableStatus(status);
      // Even a transport error accompanying 401/403 must not trigger a retry.
      BOOL read = [self.request.HTTPMethod isEqual:@"GET"];
      if (read && transient && status != 401 && status != 403) {
        NSTimeInterval delay = GHRetryDelay((unsigned)self.attempt, GHRetryAfter(http), (double)arc4random_uniform(1001) / 1000.0);
        NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - self.started;
        if (delay >= 0 && elapsed + delay + GHResourceTimeout(self.binary) <= GHRequestBudget(self.binary) && GHReserveRetry()) {
          self.attempt++;
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self start]; });
          return;
        }
      }
      // Never surface server payload, URL, underlying error, token or raw headers.
      NSError *safe = nil;
      if (status == 401 || status == 403) safe = httpErr(status, @"GitHub 身份验证或权限不足，请检查连接设置");
      else if (error) safe = httpErr(-1, @"GitHub 网络请求失败，请稍后重试");
      else if (status < 200 || status >= 300) safe = httpErr(status, [NSString stringWithFormat:@"GitHub 请求失败（%ld）", (long)status]);
      else if (!json) safe = httpErr(500, @"GitHub 响应格式异常");
      [self finish:json error:safe];
    });
  }] resume];
}
@end
@implementation LBGitCommitTask
- (void)finish:(NSDictionary *)result error:(NSError *)error { void (^callback)(NSDictionary *, NSError *) = self.done; self.done = nil; self.prepared = nil; if (callback) callback(result, error); }
- (void)next {
  if (self.index < self.paths.count) {
    NSString *path = self.paths[self.index++]; id data = self.changes[path];
    if (data == NSNull.null) {
      [self.entries addObject:@{@"path":path, @"mode":@"100644", @"type":@"blob", @"sha":NSNull.null}];
      // Queue advancement instead of recursive self-releasing blocks / deep synchronous recursion.
      dispatch_async(dispatch_get_main_queue(), ^{ [self next]; }); return;
    }
    [self.github request:@"POST" suffix:@"/git/blobs" body:@{@"content":[data base64EncodedStringWithOptions:0], @"encoding":@"base64"} done:^(NSDictionary *j, NSError *e) {
      if (e || !GHSHA(j[@"sha"]) || ![GHBlobSHA(data) isEqual:j[@"sha"]]) return [self finish:nil error:e ?: httpErr(500, @"Blob 创建失败")];
      self.shas[path] = j[@"sha"]; [self.entries addObject:@{@"path":path, @"mode":@"100644", @"type":@"blob", @"sha":j[@"sha"]}]; [self next];
    }]; return;
  }
  [self.github request:@"POST" suffix:@"/git/trees" body:@{@"base_tree":self.snapshot[@"treeSHA"], @"tree":self.entries} done:^(NSDictionary *tree, NSError *e) {
    if (e || !GHSHA(tree[@"sha"])) return [self finish:nil error:e ?: httpErr(500, @"Tree 创建失败")];
    [self.github request:@"POST" suffix:@"/git/commits" body:@{@"message":self.message ?: @"update article", @"tree":tree[@"sha"], @"parents":@[self.snapshot[@"head"]]} done:^(NSDictionary *commit, NSError *ce) {
      if (ce || !GHSHA(commit[@"sha"])) return [self finish:nil error:ce ?: httpErr(500, @"Commit 创建失败")];
      NSDictionary *pending = @{@"repository":self.github.repository.lowercaseString, @"credentialID":self.github.credentialID, @"base":self.snapshot[@"head"], @"commit":commit[@"sha"], @"shas":[self.shas copy]};
      // Persist BEFORE sending PATCH. No token/body is included in this checkpoint.
      NSError *checkpointError = nil;
      if (self.prepared && !self.prepared(pending, &checkpointError)) return [self finish:nil error:checkpointError ?: httpErr(-2, @"未能保存提交恢复记录，尚未更新分支")];
      // The new commit has precisely the expected head as its sole parent. A concurrent
      // advance makes this non-fast-forward (409/422); never force/rebase/retry silently.
      [self.github request:@"PATCH" suffix:@"/git/refs/heads/main" body:@{@"sha":commit[@"sha"], @"force":@NO} done:^(NSDictionary *ref, NSError *re) {
        if (!re && [str(dict(ref[@"object"])[@"sha"]) isEqual:commit[@"sha"]]) return [self finish:@{@"commit":commit[@"sha"], @"shas":self.shas} error:nil];
        // Permission errors and explicit conflicts are definitive failures, not a license to retry.
        if (re && (re.code == 401 || re.code == 403 || re.code == 409 || re.code == 422 || re.code == -999)) return [self finish:nil error:re];
        [self.github confirmCommit:commit[@"sha"] base:self.snapshot[@"head"] done:^(NSDictionary *confirmation, NSError *error) {
          if (error) return [self finish:nil error:error];
          if ([confirmation[@"state"] isEqual:@"applied"]) return [self finish:@{@"commit":commit[@"sha"], @"shas":self.shas} error:nil];
          if ([confirmation[@"state"] isEqual:@"conflict"]) return [self finish:nil error:httpErr(409, @"远端分支已变化且未包含本次提交；请核对冲突")];
          // Seeing the old head does not prove an in-flight server PATCH cannot finish later.
          [self finish:nil error:httpErr(-2, @"分支尚未显示本次提交，结果仍未知；已保留恢复记录")];
        }];
      }];
    }];
  }];
}
@end

#pragma mark - Site data cache
@interface LBSiteData ()
- (void)refreshDeploy:(void (^)(void))done forceCertificates:(BOOL)force active:(BOOL)active;
@end
@implementation LBSiteData {
  NSMutableDictionary *_errors, *_certs;
  NSMutableDictionary<NSString *, NSDate *> *_certCheckedAt, *_certAttemptAt;
  NSMutableArray *_deployCompletions;
  NSDate *_deployAttemptAt, *_deployCheckedAt, *_activationAttemptAt;
  BOOL _deployInFlight, _forceCertificatesQueued, _activeCertificatesQueued;
  NSString *_pendingCommit;
  NSDate *_pendingSince;
  NSUInteger _generation, _postsRevision;
  dispatch_queue_t _postsQueue;
  long long _headAtMilliseconds, _builtAtMilliseconds;
}
+ (instancetype)shared {
  static LBSiteData *d; static dispatch_once_t once;
  dispatch_once(&once, ^{ d = [LBSiteData new]; });
  return d;
}
- (instancetype)init {
  if ((self = [super init])) {
    _errors = [NSMutableDictionary dictionary]; _certs = [NSMutableDictionary dictionary];
    _certCheckedAt = [NSMutableDictionary dictionary]; _certAttemptAt = [NSMutableDictionary dictionary];
    _deployCompletions = [NSMutableArray array];
    _postsQueue = dispatch_queue_create("com.longblog.dashboard.posts", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}
- (void)resetConnection {
  _generation++;
  _posts = nil; _memos = nil; _memosVersion = nil; _envText = nil; _envSha = nil;
  _head = nil; _build = nil; _pendingCommit = nil; _pendingSince = nil;
  _headAtMilliseconds = 0; _builtAtMilliseconds = 0;
  [_errors removeAllObjects]; [_certs removeAllObjects];
  [_certCheckedAt removeAllObjects]; [_certAttemptAt removeAllObjects];
  _deployAttemptAt = nil; _deployCheckedAt = nil; _activationAttemptAt = nil;
  if (_deployInFlight) _forceCertificatesQueued = YES;
  [self changed];
}
- (NSDictionary *)errors { return [_errors copy]; }
- (NSDictionary *)certs { return [_certs copy]; }
- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:LBSiteDataDidChange object:self]; }
- (void)set:(NSString *)k error:(NSError *)e { if (e) _errors[k] = e; else [_errors removeObjectForKey:k]; }
- (NSURL *)site:(NSString *)path { return [NSURL URLWithString:[LBStore.siteURL stringByAppendingString:path]]; }

static long long msFromDateString(NSString *s) {
  // "2026-10-22 20:00:40.607+0800" or ISO-8601.
  if (![s isKindOfClass:NSString.class] || !s.length) return 0;
  static NSArray<NSDateFormatter *> *fs; static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *p in @[ @"yyyy-MM-dd HH:mm:ss.SSSZ", @"yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", @"yyyy-MM-dd'T'HH:mm:ssXXXXX" ]) {
      NSDateFormatter *f = [NSDateFormatter new];
      f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
      f.dateFormat = p;
      [a addObject:f];
    }
    fs = a;
  });
  for (NSDateFormatter *f in fs) { NSDate *d = [f dateFromString:s]; if (d) return (long long)(d.timeIntervalSince1970 * 1000); }
  return 0;
}

- (void)refreshPosts:(void (^)(void))done {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshPosts:done]; });
    return;
  }
  NSUInteger generation = _generation, revision = ++_postsRevision;
  NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:@"LBArticlesFolderBookmark"];
  dispatch_async(_postsQueue, ^{
    @autoreleasepool {
      NSArray *posts = [LBMdStore listArticlesForFolderBookmark:bookmark];
      dispatch_async(dispatch_get_main_queue(), ^{
        NSData *currentBookmark = [NSUserDefaults.standardUserDefaults dataForKey:@"LBArticlesFolderBookmark"];
        BOOL current = generation == self->_generation && revision == self->_postsRevision;
        BOOL sameFolder = bookmark == currentBookmark || [bookmark isEqual:currentBookmark];
        if (current && sameFolder) {
          self->_posts = [posts copy];
          [self set:@"posts" error:nil]; [self changed];
        } else if (current) {
          // A directory selection or stale-bookmark renewal invalidated this
          // scan. Only the newest live request may schedule a replacement.
          [self refreshPosts:nil];
        }
        // Always release the refreshAll group, including superseded results.
        if (done) done();
      });
    }
  });
}

- (void)refreshMemos:(void (^)(void))done {
  NSUInteger generation = _generation;
  // The public mirror contains only PUBLIC/NORMAL memos — no Memos token needed.
  [LBHTTP JSON:@"GET" url:[self site:@"/api/shuoshuo-feed/snapshot.json"] headers:nil body:nil done:^(id j, NSInteger st, NSError *e) {
    if (generation != self->_generation) { if (done) done(); return; }
    if (!e && (![j isKindOfClass:NSDictionary.class] || ![j[@"memos"] isKindOfClass:NSArray.class])) e = httpErr(500, @"说说快照格式异常");
    if (e) { [self set:@"memos" error:e]; [self changed]; if (done) done(); return; }
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *m in j[@"memos"]) {
      if (!dict(m) || ![m[@"content"] isKindOfClass:NSString.class]) continue;
      NSMutableDictionary *item = [m mutableCopy];
      for (NSString *key in @[ @"pinned", @"displayTs", @"createdTs" ]) item[key] = num(m[key]);
      NSMutableArray *resources = [NSMutableArray array];
      for (id resource in [m[@"resourceList"] isKindOfClass:NSArray.class] ? m[@"resourceList"] : @[]) {
        if (!dict(resource)) continue;
        NSMutableDictionary *res = [resource mutableCopy];
        for (NSString *key in @[ @"type", @"thumbnailUrl", @"filename", @"fileUrl" ]) res[key] = str(resource[key]);
        [resources addObject:res];
      }
      item[@"resourceList"] = resources;
      [list addObject:item];
    }
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      if ([a[@"pinned"] boolValue] != [b[@"pinned"] boolValue]) return [a[@"pinned"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
      return [@([b[@"displayTs"] longLongValue] ?: [b[@"createdTs"] longLongValue]) compare:@([a[@"displayTs"] longLongValue] ?: [a[@"createdTs"] longLongValue])];
    }];
    self->_memos = list;
    [self set:@"memos" error:nil];
    [LBHTTP JSON:@"GET" url:[self site:@"/api/shuoshuo-feed/version.json"] headers:nil body:nil done:^(id v, NSInteger st2, NSError *e2) {
    if (generation != self->_generation) { if (done) done(); return; }
      self->_memosVersion = !e2 && dict(v) && [v[@"checkedAt"] isKindOfClass:NSNumber.class] ? v : nil;
      [self changed];
      if (done) done();
    }];
  }];
}

- (void)refreshEnv:(void (^)(void))done {
  NSUInteger generation = _generation;
  [LBGitHub.shared getFile:@".env" done:^(NSString *text, NSString *sha, NSError *e) {
    if (generation != self->_generation) { if (done) done(); return; }
    [self set:@"env" error:e];
    if (!e) { self->_envText = text; self->_envSha = sha; }
    [self changed];
    if (done) done();
  }];
}
- (void)didCommitEnv:(NSString *)text commit:(NSString *)commitSha {
  _envText = text;
  _envSha = nil; // must re-read the new blob sha before the next edit
  _pendingCommit = commitSha;
  _pendingSince = [NSDate date];
  [self refreshEnv:nil];
  [self refreshDeploy:nil];
}

// Called only by the visible foreground dashboard. No content feeds or .env here.
- (BOOL)wantsFastDeployChecks {
  NSString *head = str(_head[@"sha"]), *built = str(_build[@"commit"]);
  if (built.length >= 7 && [head hasPrefix:built]) return NO;
  NSTimeInterval age = _pendingSince ? -_pendingSince.timeIntervalSinceNow : DBL_MAX;
  if (age >= 0 && age < 20 * 60) return YES;
  long long date = _headAtMilliseconds;
  age = date ? NSDate.date.timeIntervalSince1970 - date / 1000.0 : DBL_MAX;
  return head.length && age >= 0 && age < 20 * 60;
}
- (void)monitorDeploy {
  NSTimeInterval interval = [self wantsFastDeployChecks] ? 5 : 30;
  // A little scheduling slack avoids accidentally turning a 30s timer into 60s.
  if (_deployAttemptAt && -_deployAttemptAt.timeIntervalSinceNow < interval - 0.5) return;
  [self refreshDeploy:nil];
}
- (void)refreshDeployOnActivation {
  // Scene + application activation may arrive together. Coalesce both.
  if (_activationAttemptAt && -_activationAttemptAt.timeIntervalSinceNow < 2) return;
  _activationAttemptAt = [NSDate date];
  [self refreshDeploy:nil forceCertificates:NO active:YES];
}
- (NSDate *)certificateCheckedAt:(NSString *)host { return _certCheckedAt[host]; }
- (NSDate *)deployCheckedAt { return _deployCheckedAt; }
- (void)refreshDeploy:(void (^)(void))done {
  if (!done && _deployAttemptAt && -_deployAttemptAt.timeIntervalSinceNow < 4.5) return;
  [self refreshDeploy:done forceCertificates:NO active:NO];
}
- (void)refreshDeploy:(void (^)(void))done forceCertificates:(BOOL)force active:(BOOL)active {
  if (done) [_deployCompletions addObject:[done copy]];
  if (_deployInFlight) {
    // A manual refresh during an automatic probe must still perform fresh TLS.
    if (force) _forceCertificatesQueued = YES;
    if (active) _activeCertificatesQueued = YES;
    return;
  }
  _deployInFlight = YES;
  _deployAttemptAt = [NSDate date];
  NSUInteger generation = _generation;
  NSString *site = [LBStore.siteURL copy], *repo = [LBStore.repo copy];
  NSArray<NSString *> *hosts = [LBStore.certHosts copy];
  BOOL (^current)(void) = ^BOOL {
    return generation == self->_generation && [site isEqualToString:LBStore.siteURL] &&
      [repo isEqualToString:LBStore.repo] && [hosts isEqualToArray:LBStore.certHosts];
  };
  dispatch_group_t g = dispatch_group_create();
  if (LBGitHub.shared.configured) {
    dispatch_group_enter(g);
    [LBGitHub.shared headCommit:^(NSDictionary *c, NSError *e) {
      if (current()) {
        [self set:@"head" error:e];
        if (c && !e && ![str(self->_head[@"date"]) isEqualToString:str(c[@"date"])])
          self->_headAtMilliseconds = msFromDateString(str(c[@"date"]));
        if (c && !e) self->_head = c;
      }
      dispatch_group_leave(g);
    }];
  }
  dispatch_group_enter(g);
  NSURL *marker = [NSURL URLWithString:[site stringByAppendingString:@"/build-info.json"]];
  [LBHTTP JSON:@"GET" url:marker headers:@{ @"Cache-Control" : @"no-cache" } body:nil done:^(id j, NSInteger st, NSError *e) {
    if (current()) {
      BOOL valid = dict(j) && [num(j[@"schemaVersion"]) integerValue] == 1 && [j[@"builtAt"] isKindOfClass:NSString.class];
      if (!e && !valid) e = httpErr(500, @"构建信息格式异常");
      [self set:@"build" error:e];
      if (!e && ![str(self->_build[@"builtAt"]) isEqualToString:str(j[@"builtAt"])])
        self->_builtAtMilliseconds = msFromDateString(str(j[@"builtAt"]));
      if (!e) { self->_build = j; self->_deployCheckedAt = [NSDate date]; }
    }
    dispatch_group_leave(g);
  }];
  for (NSString *host in hosts) {
    NSDate *checked = _certCheckedAt[host], *attempt = _certAttemptAt[host];
    id cached = _certs[host];
    BOOL nearExpiry = [cached isKindOfClass:NSDate.class] && [(NSDate *)cached timeIntervalSinceNow] <= 7 * 86400;
    NSTimeInterval ttl = active || nearExpiry ? 5 * 60 : 15 * 60;
    // Failed probes retry at most every five minutes; successful timestamps
    // describe actual verified TLS, never a cached-date read or failed attempt.
    if (!force && attempt && -attempt.timeIntervalSinceNow < 5 * 60) continue;
    if (!force && checked && -checked.timeIntervalSinceNow < ttl) continue;
    _certAttemptAt[host] = [NSDate date];
    dispatch_group_enter(g);
    [LBHTTP certificateExpiry:host done:^(NSDate *exp, NSError *e) {
      if (current()) {
        NSString *key = [@"cert:" stringByAppendingString:host];
        [self set:key error:e];
        if (exp && !e) {
          self->_certs[host] = exp;
          self->_certCheckedAt[host] = [NSDate date];
        } else if (!self->_certs[host]) {
          self->_certs[host] = e ?: httpErr(-1, @"证书复核失败");
        }
      }
      dispatch_group_leave(g);
    }];
  }
  dispatch_group_notify(g, dispatch_get_main_queue(), ^{
    self->_deployInFlight = NO;
    BOOL valid = current();
    if (valid) [self changed];
    BOOL again = self->_forceCertificatesQueued;
    BOOL checkActive = self->_activeCertificatesQueued && NSApplication.sharedApplication.isActive;
    self->_forceCertificatesQueued = NO; self->_activeCertificatesQueued = NO;
    if (again || checkActive) {
      [self refreshDeploy:nil forceCertificates:again active:checkActive];
      return;
    }
    NSArray *callbacks = [self->_deployCompletions copy];
    [self->_deployCompletions removeAllObjects];
    for (void (^callback)(void) in callbacks) callback();
  });
}

- (NSString *)deployState:(NSColor **)color pending:(BOOL *)pending {
  NSString *head = _head[@"sha"], *built = [_build[@"commit"] isKindOfClass:NSString.class] ? _build[@"commit"] : nil;
  long long builtAt = _builtAtMilliseconds;
  long long headAt = _headAtMilliseconds;
  BOOL waiting = NO;
  NSString *text;
  NSColor *c = NSColor.secondaryLabelColor;
  if (!_build) { text = @"站点未提供构建信息（下次部署后可用）"; }
  else if (head && built.length >= 7 && [head hasPrefix:built]) { text = @"线上已是最新提交"; c = NSColor.systemGreenColor; }
  else if (head && !built && builtAt && headAt && builtAt >= headAt) { text = @"构建时间已更新，缺少 SHA 无法确认提交"; c = NSColor.systemOrangeColor; }
  else if (head) {
    waiting = YES;
    NSTimeInterval since = NSDate.date.timeIntervalSince1970 - (_pendingSince && [_pendingCommit isEqualToString:head] ? _pendingSince.timeIntervalSince1970 : headAt / 1000.0);
    if (since > 20 * 60) { text = @"最新提交 20 分钟仍未上线，请检查 EdgeOne 构建"; c = NSColor.systemRedColor; waiting = NO; }
    else { text = @"等待 EdgeOne 构建部署…"; c = NSColor.systemOrangeColor; }
  } else { text = @"已部署（未连接 GitHub，无法比对提交）"; }
  if (_errors[@"build"] || _errors[@"head"]) {
    text = [text stringByAppendingString:@" · 复核失败（保留上次结果）"];
    c = NSColor.systemOrangeColor;
  }
  if (color) *color = c;
  if (pending) *pending = waiting;
  return text;
}

- (void)refreshAll:(void (^)(void))done {
  dispatch_group_t g = dispatch_group_create();
  for (NSString *part in @[ @"memos", @"deploy", @"posts", @"env" ]) {
    if (([part isEqualToString:@"posts"] || [part isEqualToString:@"env"]) && !LBGitHub.shared.configured) continue;
    dispatch_group_enter(g);
    void (^leave)(void) = ^{ dispatch_group_leave(g); };
    if ([part isEqualToString:@"memos"]) [self refreshMemos:leave];
    else if ([part isEqualToString:@"deploy"]) [self refreshDeploy:leave forceCertificates:YES active:NO];
    else if ([part isEqualToString:@"posts"]) [self refreshPosts:leave];
    else [self refreshEnv:leave];
  }
  dispatch_group_notify(g, dispatch_get_main_queue(), ^{ if (done) done(); });
}
@end

#pragma mark - Helpers
NSString *LBDateText(NSDate *date) {
  NSDateFormatter *f = [NSDateFormatter new];
  f.dateFormat = @"yyyy年M月d日";
  return [f stringFromDate:date];
}
