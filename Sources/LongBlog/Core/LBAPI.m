#import "LB.h"
#import <Security/Security.h>

NSString *const LBDefaultAPIBase = @"https://shuoshuo.huowenlong.com/terminal-chat";
static NSString *const kKeychainAccount = @"owner-key";
static NSString *const kBaseDefaults = @"LBAPIBase";

static BOOL LBID(id value) {
  return [value isKindOfClass:NSString.class] && [value rangeOfString:@"^[a-f0-9]{32}$" options:NSRegularExpressionSearch].location != NSNotFound;
}
static BOOL LBInteger(id value, long long minimum, long long maximum) {
  if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
  double d = [value doubleValue];
  return isfinite(d) && floor(d) == d && d >= minimum && d <= maximum;
}

@implementation LBMessage
+ (instancetype)fromJSON:(NSDictionary *)d {
  if (![d isKindOfClass:NSDictionary.class]) return nil;
  NSString *mid = d[@"id"], *sender = d[@"sender"], *text = d[@"text"];
  if (!LBID(mid) || (![sender isEqual:@"user"] && ![sender isEqual:@"author"]) || ![text isKindOfClass:NSString.class]
      || text.length == 0 || text.length > 500 || !LBInteger(d[@"createdAt"], 1, 9007199254740991LL)
      || !LBInteger(d[@"sequence"], 1, 200)) return nil;
  LBMessage *m = [LBMessage new];
  m.mid = mid; m.sender = sender; m.text = text;
  m.createdAt = [d[@"createdAt"] longLongValue];
  m.sequence = [d[@"sequence"] integerValue];
  return m;
}
- (BOOL)fromVisitor { return [self.sender isEqualToString:@"user"]; }
@end

@implementation LBSession
+ (instancetype)fromJSON:(NSDictionary *)d {
  if (![d isKindOfClass:NSDictionary.class] || !LBID(d[@"sessionId"])
      || !LBInteger(d[@"createdAt"], 1, 9007199254740991LL) || !LBInteger(d[@"expiresAt"], 1, 9007199254740991LL)
      || !LBInteger(d[@"sequence"], 1, 200) || !LBInteger(d[@"lastUserSequence"], 0, 200)) return nil;
  LBSession *s = [LBSession new];
  s.sessionId = d[@"sessionId"];
  s.createdAt = [d[@"createdAt"] longLongValue];
  s.expiresAt = [d[@"expiresAt"] longLongValue];
  s.sequence = [d[@"sequence"] integerValue];
  s.lastUserSequence = [d[@"lastUserSequence"] integerValue];
  s.last = [LBMessage fromJSON:d[@"last"]];
  s.archived = [d[@"archived"] isKindOfClass:NSNumber.class] && [d[@"archived"] boolValue];
  if (s.archived) {
    id deadline = d[@"archiveExpiresAt"];
    if (deadline == NSNull.null) s.archiveExpiresAt = 0; // nil server expiry means permanent until owner deletion.
    else {
      if (!LBInteger(deadline, s.expiresAt + 1, 9007199254740991LL)) return nil;
      s.archiveExpiresAt = [deadline longLongValue];
    }
    s.archivedAt = LBInteger(d[@"archivedAt"], 1, 9007199254740991LL) ? [d[@"archivedAt"] longLongValue] : s.expiresAt;
  }
  if (s.expiresAt <= s.createdAt || s.expiresAt > s.createdAt + 72LL * 3600000 || s.lastUserSequence > s.sequence
      || !s.last || s.last.sequence != s.sequence) return nil;
  return s;
}
- (NSString *)shortId { return [self.sessionId substringToIndex:MIN(8, self.sessionId.length)]; }
@end

@interface LBAPI () <NSURLSessionTaskDelegate>
@end
@implementation LBAPI {
  NSURLSession *_session;
  NSUInteger _generation;
}
+ (instancetype)shared {
  static LBAPI *a; static dispatch_once_t once;
  dispatch_once(&once, ^{ a = [LBAPI new]; });
  return a;
}
- (instancetype)init {
  if ((self = [super init])) {
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    c.timeoutIntervalForRequest = 15;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    c.HTTPAdditionalHeaders = @{ @"Accept" : @"application/json" };
    _session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:nil];
  }
  return self;
}
- (NSString *)baseURL {
  NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:kBaseDefaults];
  return v.length ? v : LBDefaultAPIBase;
}
- (void)setBaseURL:(NSString *)baseURL {
  NSString *previous = self.baseURL;
  NSString *t = [baseURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  while ([t hasSuffix:@"/"]) t = [t substringToIndex:t.length - 1];
  [NSUserDefaults.standardUserDefaults setObject:t.length ? t : LBDefaultAPIBase forKey:kBaseDefaults];
  if (![previous isEqualToString:self.baseURL]) _generation++;
}

#pragma mark Keychain
// Shared cached LBKeychain (same service namespace) so a permission prompt cannot
// be triggered on every `configured` check from the main thread.
- (NSString *)ownerKey { return [LBKeychain get:kKeychainAccount]; }
- (void)setOwnerKey:(NSString *)ownerKey {
  NSString *t = [ownerKey stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if ([self.ownerKey ?: @"" isEqualToString:t ?: @""]) return;
  _generation++;
  [LBKeychain set:t account:kKeychainAccount];
}
- (void)noteCredentialChange { _generation++; }
- (NSUInteger)connectionRevision { return _generation; }
- (BOOL)configured { return self.ownerKey.length > 0; }

#pragma mark HTTP
static NSError *LBErr(NSInteger code, NSString *msg) {
  return [NSError errorWithDomain:@"LBAPI" code:code userInfo:@{ NSLocalizedDescriptionKey : msg }];
}
- (void)call:(NSString *)method path:(NSString *)path query:(NSDictionary *)query body:(NSDictionary *)body
        done:(void (^)(NSDictionary *json, NSError *e))done {
  NSUInteger generation = _generation;
  void (^finish)(NSDictionary *, NSError *) = ^(NSDictionary *j, NSError *e) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation != self->_generation) return done(nil, LBErr(409, @"连接已变更，请重新刷新"));
      done(j, e);
    });
  };
  NSString *key = self.ownerKey;
  if (!key.length) return finish(nil, LBErr(401, @"尚未设置站长密钥"));
  NSURLComponents *c = [NSURLComponents componentsWithString:[self.baseURL stringByAppendingString:path]];
  if (!c.URL || ![c.scheme isEqualToString:@"https"] || !c.host.length || c.user.length || c.password.length) return finish(nil, LBErr(400, @"接口地址必须是 HTTPS"));
  if (query.count) {
    NSMutableArray *items = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
      [items addObject:[NSURLQueryItem queryItemWithName:k value:[v description]]];
    }];
    c.queryItems = items;
  }
  NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:c.URL];
  r.HTTPMethod = method;
  [r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
  if (body) {
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  }
  [[_session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
    if (error) return finish(nil, LBErr(-1, @"网络不可用，稍后自动重试"));
    NSInteger status = [(NSHTTPURLResponse *)resp statusCode];
    if (data.length > 2 * 1024 * 1024) return finish(nil, LBErr(413, @"服务器返回数据过大"));
    id j = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) return finish(nil, LBErr(status, [NSString stringWithFormat:@"服务器返回异常（%ld）", (long)status]));
    if (status < 200 || status >= 300) {
      NSString *msg = [j[@"error"] isKindOfClass:NSString.class] ? j[@"error"] : @"请求失败";
      return finish(nil, LBErr(status, msg));
    }
    finish(j, nil);
  }] resume];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))done {
  done(nil); // Never redirect a credential-bearing request to another origin.
}
- (void)fetchSessions:(void (^)(NSArray<LBSession *> *, NSError *))done {
  [self call:@"GET" path:@"/owner/sessions" query:nil body:nil done:^(NSDictionary *j, NSError *e) {
    if (e) return done(nil, e);
    if (![j[@"sessions"] isKindOfClass:NSArray.class] || [j[@"sessions"] count] > 100) return done(nil, LBErr(500, @"会话列表格式异常"));
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *ids = [NSMutableSet set];
    for (id d in j[@"sessions"]) {
      LBSession *s = [LBSession fromJSON:d];
      if (!s || s.archived || [ids containsObject:s.sessionId]) return done(nil, LBErr(500, @"会话列表无法验证"));
      [out addObject:s]; [ids addObject:s.sessionId];
    }
    done(out, nil);
  }];
}
- (void)fetchArchivedSessions:(NSString *)cursor done:(void (^)(NSArray<LBSession *> *, NSString *, NSError *))done {
  [self call:@"GET" path:@"/owner/archives" query:cursor.length ? @{ @"cursor" : cursor } : nil body:nil done:^(NSDictionary *j, NSError *e) {
    if (e) return done(nil, nil, e);
    if (![j[@"sessions"] isKindOfClass:NSArray.class] || [j[@"sessions"] count] > 50) return done(nil, nil, LBErr(500, @"归档列表格式异常"));
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *ids = [NSMutableSet set];
    for (id d in j[@"sessions"]) {
      LBSession *s = [LBSession fromJSON:d];
      if (!s || !s.archived || [ids containsObject:s.sessionId]) return done(nil, nil, LBErr(500, @"归档列表无法验证"));
      [out addObject:s]; [ids addObject:s.sessionId];
    }
    id next = j[@"nextCursor"];
    if (next == NSNull.null) next = nil;
    if (next && (![next isKindOfClass:NSString.class] || [next length] == 0 || [next length] > 2048 || [next isEqual:cursor]
                 || !out.count)) return done(nil, nil, LBErr(500, @"归档游标异常"));
    done(out, next, nil);
  }];
}
- (void)deleteArchivedSession:(NSString *)sid done:(void (^)(NSError *))done {
  if (!LBID(sid)) return done(LBErr(400, @"归档会话无效"));
  [self call:@"POST" path:@"/owner/archive-delete" query:nil body:@{ @"sessionId" : sid } done:^(NSDictionary *json, NSError *error) {
    if (error) return done(error);
    if (![json[@"success"] isEqual:@YES] || ![json[@"sessionId"] isEqual:sid]) return done(LBErr(500, @"删除结果无法确认，请刷新归档列表核对"));
    done(nil);
  }];
}
- (void)fetchSessionContact:(NSString *)sid done:(void (^)(NSDictionary *, NSError *))done {
  if (!LBID(sid)) return done(nil, LBErr(400, @"会话无效"));
  [self call:@"GET" path:@"/owner/session-contact" query:@{ @"sessionId" : sid } body:nil done:^(NSDictionary *json, NSError *error) {
    if (error) return done(nil, error);
    id email = json[@"email"], status = json[@"status"];
    if (![status isKindOfClass:NSString.class] || ![@[ @"none", @"enabled", @"disabled", @"unavailable" ] containsObject:status])
      return done(nil, LBErr(500, @"访客邮箱状态无法验证"));
    if (email != NSNull.null && (![email isKindOfClass:NSString.class] || [email length] > 254 || [email length] < 3
        || [email rangeOfString:@"@"].location == NSNotFound || [email rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound))
      return done(nil, LBErr(500, @"访客邮箱格式异常"));
    NSMutableDictionary *contact = [@{ @"status" : status, @"email" : email ?: NSNull.null } mutableCopy];
    if ([json[@"delivery"] isKindOfClass:NSString.class] && [json[@"delivery"] length] <= 64) contact[@"delivery"] = json[@"delivery"];
    done(contact, nil);
  }];
}
- (void)fetchMessages:(NSString *)sid after:(NSInteger)cursor done:(void (^)(NSArray<LBMessage *> *, NSInteger, NSError *))done {
  [self pageMessages:sid archived:NO from:cursor into:[NSMutableArray array] done:done];
}
- (void)fetchArchivedMessages:(NSString *)sid after:(NSInteger)cursor done:(void (^)(NSArray<LBMessage *> *, NSInteger, NSError *))done {
  [self pageMessages:sid archived:YES from:cursor into:[NSMutableArray array] done:done];
}
- (void)pageMessages:(NSString *)sid archived:(BOOL)archived from:(NSInteger)from into:(NSMutableArray *)all
                done:(void (^)(NSArray<LBMessage *> *, NSInteger, NSError *))done {
  if (!LBID(sid) || from < 0 || from > 200) return done(nil, from, LBErr(400, @"会话或消息游标无效"));
  [self call:@"GET" path:archived ? @"/owner/archive-messages" : @"/owner/messages" query:@{ @"sessionId" : sid, @"cursor" : @(from) } body:nil
        done:^(NSDictionary *j, NSError *e) {
    if (e) return done(nil, from, e);
    if (![j[@"messages"] isKindOfClass:NSArray.class] || [j[@"messages"] count] > 50
        || !LBInteger(j[@"cursor"], from, 200) || ![j[@"hasMore"] isKindOfClass:NSNumber.class])
      return done(nil, from, LBErr(500, @"消息响应格式异常"));
    NSInteger expected = from;
    NSMutableArray *page = [NSMutableArray array];
    NSMutableSet *ids = [NSMutableSet setWithArray:[all valueForKey:@"mid"]];
    for (id d in j[@"messages"]) {
      LBMessage *m = [LBMessage fromJSON:d];
      BOOL ordered = m && (archived ? m.sequence > expected : m.sequence == expected + 1);
      if (!ordered || [ids containsObject:m.mid]) return done(nil, from, LBErr(500, @"消息顺序无法验证，请刷新重试"));
      expected = m.sequence;
      [page addObject:m]; [ids addObject:m.mid];
    }
    NSInteger next = [j[@"cursor"] integerValue];
    BOOL more = [j[@"hasMore"] boolValue];
    if (next != expected || (more && (!page.count || next >= 200)) || all.count + page.count > 200)
      return done(nil, from, LBErr(500, @"消息分页无法验证"));
    [all addObjectsFromArray:page];
    if (more) [self pageMessages:sid archived:archived from:next into:all done:done];
    else done(all, next, nil);
  }];
}
- (void)reply:(NSString *)sid messageId:(NSString *)mid text:(NSString *)text done:(void (^)(LBMessage *, NSError *))done {
  if (!LBID(sid) || !LBID(mid) || ![text isKindOfClass:NSString.class] || !text.length || text.length > 500) return done(nil, LBErr(400, @"回复参数无效"));
  [self call:@"POST" path:@"/owner/reply" query:nil body:@{ @"sessionId" : sid, @"messageId" : mid, @"message" : text }
        done:^(NSDictionary *j, NSError *e) {
    if (e) return done(nil, e);
    LBMessage *m = [LBMessage fromJSON:j[@"message"]];
    BOOL valid = m && [m.mid isEqualToString:mid] && [m.sender isEqualToString:@"author"] && [m.text isEqualToString:text];
    done(valid ? m : nil, valid ? nil : LBErr(500, @"回复结果无法确认，请下拉刷新"));
  }];
}
+ (NSString *)randomHex:(NSUInteger)bytes {
  NSMutableData *d = [NSMutableData dataWithLength:bytes];
  if (SecRandomCopyBytes(kSecRandomDefault, bytes, d.mutableBytes) != errSecSuccess) return @"";
  NSMutableString *s = [NSMutableString stringWithCapacity:bytes * 2];
  const unsigned char *p = d.bytes;
  for (NSUInteger i = 0; i < bytes; i++) [s appendFormat:@"%02x", p[i]];
  return s;
}
@end
