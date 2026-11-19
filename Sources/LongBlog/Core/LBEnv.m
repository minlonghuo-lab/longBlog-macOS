#import "LB.h"

@implementation LBEnvLine
@end

/// Matches the subset of dotenv syntax Vite's loadEnv understands, one line at a time.
static NSRegularExpression *lineRegex(void) {
  static NSRegularExpression *r; static dispatch_once_t once;
  dispatch_once(&once, ^{
    r = [NSRegularExpression regularExpressionWithPattern:
         @"^\\s*(?:export\\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\\s*=\\s*(\"(?:\\\\\"|[^\"])*\"|'(?:\\\\'|[^'])*'|`(?:\\\\`|[^`])*`|[^#\\r\\n]*)?\\s*(?:#.*)?$"
                                                  options:0 error:nil];
  });
  return r;
}

static NSString *decodeValue(NSString *raw) {
  NSString *v = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if (v.length >= 2) {
    unichar q = [v characterAtIndex:0];
    if ((q == '"' || q == '\'' || q == '`') && [v characterAtIndex:v.length - 1] == q) {
      v = [v substringWithRange:NSMakeRange(1, v.length - 2)];
      if (q == '"') v = [[v stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\\r" withString:@"\r"];
    }
  }
  return v;
}

@implementation LBEnvFile {
  NSMutableArray<LBEnvLine *> *_lines;
  NSString *_parseError;
}
+ (instancetype)parse:(NSString *)text {
  LBEnvFile *f = [LBEnvFile new];
  f->_lines = [NSMutableArray array];
  for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
    LBEnvLine *l = [LBEnvLine new];
    l.raw = raw;
    NSString *trim = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (trim.length && ![trim hasPrefix:@"#"]) {
      NSTextCheckingResult *m = [lineRegex() firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
      if (m) {
        l.key = [raw substringWithRange:[m rangeAtIndex:1]];
        NSRange vr = [m rangeAtIndex:2];
        NSString *encoded = vr.location == NSNotFound ? @"" : [[raw substringWithRange:vr] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (encoded.length && [@"\"'`" rangeOfString:[encoded substringToIndex:1]].location != NSNotFound
            && (encoded.length < 2 || [encoded characterAtIndex:0] != [encoded characterAtIndex:encoded.length - 1])) {
          f->_parseError = @"检测到多行或未闭合的引号，为避免损坏文件，请在 GitHub 编辑此配置";
        }
        l.value = decodeValue(encoded);
      }
    }
    [f->_lines addObject:l];
  }
  return f;
}
- (NSMutableArray<LBEnvLine *> *)lines { return _lines; }
- (LBEnvLine *)lineFor:(NSString *)key {
  LBEnvLine *found = nil;
  for (LBEnvLine *l in _lines) if ([l.key isEqualToString:key]) found = l; // last wins, like dotenv
  return found;
}
- (NSString *)valueFor:(NSString *)key { return [self lineFor:key].value; }
- (NSDictionary *)values {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  for (LBEnvLine *l in _lines) if (l.key) d[l.key] = l.value ?: @"";
  return d;
}

- (NSString *)updateValue:(NSString *)value forKey:(NSString *)key {
  if (_parseError) return _parseError;
  if (![key hasPrefix:@"PUBLIC_"]) return @"仅允许编辑公开站点字段";
  if ([value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return @"不能包含换行";
  if ([value containsString:@"$"]) return @"不能包含 $（构建时会被当作变量展开）";
  if ([value containsString:@"\\n"] || [value containsString:@"\\r"]) return @"不能包含 \\n 或 \\r 文本";
  NSString *quoted;
  if (![value containsString:@"\""]) quoted = [NSString stringWithFormat:@"\"%@\"", value];
  else if (![value containsString:@"'"]) quoted = [NSString stringWithFormat:@"'%@'", value];
  else if (![value containsString:@"`"]) quoted = [NSString stringWithFormat:@"`%@`", value];
  else return @"同时包含三种引号，无法安全保存";
  LBEnvLine *l = [self lineFor:key];
  if ([l.value isEqualToString:value]) return nil; // untouched: keep the original bytes
  if (!l) { l = [LBEnvLine new]; l.key = key; [_lines addObject:l]; }
  l.value = value;
  l.raw = [NSString stringWithFormat:@"%@=%@", key, quoted];
  return nil;
}
- (NSString *)publicSnapshotText {
  if (_parseError) return nil;
  NSMutableArray *publicLines = [NSMutableArray arrayWithObject:@"# 本地公开配置"];
  for (LBEnvLine *line in _lines) {
    if (![line.key hasPrefix:@"PUBLIC_"]) continue;
    NSTextCheckingResult *match = [lineRegex() firstMatchInString:line.raw options:0 range:NSMakeRange(0,line.raw.length)];
    if (!match) return nil;
    NSRange encoded = [match rangeAtIndex:2];
    NSString *value = encoded.location == NSNotFound ? @"" : [line.raw substringWithRange:encoded];
    [publicLines addObject:[NSString stringWithFormat:@"%@=%@", line.key, value]];
  }
  return [publicLines componentsJoinedByString:@"\n"];
}
- (NSString *)serialize {
  NSMutableArray *a = [NSMutableArray arrayWithCapacity:_lines.count];
  for (LBEnvLine *l in _lines) [a addObject:l.raw];
  return [a componentsJoinedByString:@"\n"];
}

#pragma mark Sections from the file's own comments
static NSString *sectionTitle(NSString *trim) {
  // "# ── 站点与作者（沿用当前博客展示） ──"
  if (![trim hasPrefix:@"#"] || ![trim containsString:@"──"]) return nil;
  NSString *t = [[trim substringFromIndex:1] stringByReplacingOccurrencesOfString:@"──" withString:@""];
  t = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  // Strip noisy parentheticals like (路由由程序维护) or (Pages 同名环境变量...)
  NSRange paren = [t rangeOfString:@"("];
  if (paren.location == NSNotFound) paren = [t rangeOfString:@"（"];
  if (paren.location != NSNotFound) t = [t substringToIndex:paren.location];
  // Strip verbose colon explanations like "友链列表: 按数字顺序..."
  NSRange colon = [t rangeOfString:@":"];
  if (colon.location == NSNotFound) colon = [t rangeOfString:@"："];
  if (colon.location != NSNotFound) t = [t substringToIndex:colon.location];
  return [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}
static BOOL isFriendKey(NSString *k) {
  return [k rangeOfString:@"^PUBLIC_FRIEND_[0-9]+_" options:NSRegularExpressionSearch].location != NSNotFound;
}
- (NSArray<NSDictionary *> *)sections {
  NSMutableArray *out = [NSMutableArray array];
  NSMutableDictionary *cur = nil;
  NSMutableArray *comments = [NSMutableArray array];
  BOOL friendsAdded = NO;
  for (LBEnvLine *l in _lines) {
    NSString *trim = [l.raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *title = sectionTitle(trim);
    if (title) {
      cur = [@{ @"title" : title, @"keys" : [NSMutableArray array], @"friends" : @NO } mutableCopy];
      [out addObject:cur];
      [comments removeAllObjects];
      continue;
    }
    if ([trim hasPrefix:@"#"]) {
      NSString *c = [[trim substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if (c.length) [comments addObject:c];
      continue;
    }
    if (!trim.length) { [comments removeAllObjects]; continue; }
    if (!l.key || ![l.key hasPrefix:@"PUBLIC_"]) continue;
    if (!cur) { cur = [@{ @"title" : @"其他", @"keys" : [NSMutableArray array], @"friends" : @NO } mutableCopy]; [out addObject:cur]; }
    if (isFriendKey(l.key)) {
      if (!friendsAdded) { cur[@"friends"] = @YES; friendsAdded = YES; }
      [comments removeAllObjects];
      continue;
    }
    [cur[@"keys"] addObject:@{ @"key" : l.key, @"help" : [comments componentsJoinedByString:@" "] }];
    [comments removeAllObjects];
  }
  // A friends section always exists so new friends can be added.
  if (!friendsAdded) [out addObject:@{ @"title" : @"友链列表", @"keys" : @[], @"friends" : @YES }];
  return out;
}

#pragma mark Friends
- (NSArray<NSNumber *> *)friendIndexes {
  NSMutableOrderedSet *s = [NSMutableOrderedSet orderedSet];
  NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:@"^PUBLIC_FRIEND_([0-9]+)_" options:0 error:nil];
  for (LBEnvLine *l in _lines) {
    if (!l.key) continue;
    NSTextCheckingResult *m = [r firstMatchInString:l.key options:0 range:NSMakeRange(0, l.key.length)];
    if (m) [s addObject:@([[l.key substringWithRange:[m rangeAtIndex:1]] integerValue])];
  }
  return [s.array sortedArrayUsingSelector:@selector(compare:)];
}
- (NSInteger)addFriend {
  NSInteger next = [[self friendIndexes].lastObject integerValue] + 1;
  NSUInteger at = NSNotFound;
  for (NSUInteger i = 0; i < _lines.count; i++) if (_lines[i].key && isFriendKey(_lines[i].key)) at = i;
  if (at == NSNotFound) at = _lines.count ? _lines.count - 1 : 0;
  else at += 1;
  NSMutableArray *add = [NSMutableArray array];
  LBEnvLine *blank = [LBEnvLine new]; blank.raw = @"";
  [add addObject:blank];
  // Disabled until filled in, so a half-edited friend never breaks the build.
  for (NSArray *kv in @[ @[ @"NAME", @"" ], @[ @"URL", @"" ], @[ @"DESCRIPTION", @"" ], @[ @"AVATAR", @"" ], @[ @"ENABLED", @"false" ] ]) {
    LBEnvLine *l = [LBEnvLine new];
    l.key = [NSString stringWithFormat:@"PUBLIC_FRIEND_%ld_%@", (long)next, kv[0]];
    l.value = kv[1];
    l.raw = [NSString stringWithFormat:@"%@=%@", l.key, [kv[1] length] ? kv[1] : @"\"\""];
    [add addObject:l];
  }
  [_lines insertObjects:add atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(MIN(at, _lines.count), add.count)]];
  return next;
}
- (void)removeFriend:(NSInteger)index {
  NSString *prefix = [NSString stringWithFormat:@"PUBLIC_FRIEND_%ld_", (long)index];
  NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];
  for (NSUInteger i = 0; i < _lines.count; i++) {
    if ([_lines[i].key hasPrefix:prefix]) {
      [drop addIndex:i];
      // also drop the blank separator before the block
      if (i > 0 && ![drop containsIndex:i - 1] && !_lines[i - 1].key
          && ![[_lines[i - 1].raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] length]) [drop addIndex:i - 1];
    }
  }
  [_lines removeObjectsAtIndexes:drop];
}

#pragma mark Validation (mirrors src/lib/site-config.js)
static BOOL httpURL(NSString *v) {
  NSURL *u = [NSURL URLWithString:v];
  return u && ([u.scheme isEqualToString:@"https"] || [u.scheme isEqualToString:@"http"]) && u.host.length;
}
static BOOL enabledValue(NSString *v) {
  return ![[[v ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString] isEqualToString:@"false"];
}
- (NSArray<NSString *> *)validate {
  if (_parseError) return @[ _parseError ];
  NSDictionary *v = [self values];
  NSMutableArray *errs = [NSMutableArray array];
  NSString *(^t)(NSString *) = ^NSString *(NSString *k) {
    return [v[k] ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  };
  void (^url)(NSString *, BOOL, BOOL) = ^(NSString *k, BOOL relative, BOOL optional) {
    NSString *x = t(k);
    if (!x.length && optional) return;
    if (relative && [x hasPrefix:@"/"] && ![x hasPrefix:@"//"]) return;
    if (!httpURL(x)) [errs addObject:[NSString stringWithFormat:@"%@ 必须是有效的 HTTP(S) 地址%@", [LBEnvFile labelFor:k], relative ? @"或站内路径" : @""]];
  };
  for (NSString *k in @[ @"PUBLIC_SITE_TITLE", @"PUBLIC_SITE_AUTHOR" ])
    if (!t(k).length) [errs addObject:[NSString stringWithFormat:@"%@ 不能为空", [LBEnvFile labelFor:k]]];
  url(@"PUBLIC_SITE_URL", NO, NO);
  if (enabledValue(v[@"PUBLIC_FOOTER_SHOW_RUNTIME"])) {
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    NSISO8601DateFormatter *d = [NSISO8601DateFormatter new];
    d.formatOptions = NSISO8601DateFormatWithFullDate;
    if (![f dateFromString:t(@"PUBLIC_SITE_LAUNCH_DATE")] && ![d dateFromString:t(@"PUBLIC_SITE_LAUNCH_DATE")])
      [errs addObject:@"建站日期必须是有效日期，例如 2026-03-27T00:00:00+08:00"];
  }
  url(@"PUBLIC_SITE_GITHUB", NO, YES);
  url(@"PUBLIC_ICP_URL", NO, YES);
  url(@"PUBLIC_FRIEND_SITE_URL", NO, YES);
  url(@"PUBLIC_FRIEND_SITE_AVATAR", NO, YES);
  for (NSString *n in @[ @"ASTRO", @"AUTOMATION" ]) url([NSString stringWithFormat:@"PUBLIC_FOOTER_POWERED_%@_URL", n], NO, YES);
  for (NSNumber *i in [self friendIndexes]) {
    NSString *p = [NSString stringWithFormat:@"PUBLIC_FRIEND_%@", i];
    if (!enabledValue(v[[p stringByAppendingString:@"_ENABLED"]])) continue;
    if (!t([p stringByAppendingString:@"_NAME"]).length) [errs addObject:[NSString stringWithFormat:@"友链 #%@ 已启用但缺少名称", i]];
    NSString *u = t([p stringByAppendingString:@"_URL"]);
    if (!httpURL(u)) [errs addObject:[NSString stringWithFormat:@"友链 #%@ 的链接无效", i]];
    NSString *a = t([p stringByAppendingString:@"_AVATAR"]);
    if (a.length && !([a hasPrefix:@"/"] && ![a hasPrefix:@"//"]) && !httpURL(a)) [errs addObject:[NSString stringWithFormat:@"友链 #%@ 的头像地址无效", i]];
  }
  return errs;
}

#pragma mark Labels
+ (BOOL)isBoolean:(NSString *)key {
  return [key hasSuffix:@"_ENABLED"] || [key hasPrefix:@"PUBLIC_FOOTER_SHOW_"];
}
+ (NSString *)labelFor:(NSString *)key {
  static NSDictionary *m; static dispatch_once_t once;
  dispatch_once(&once, ^{
    m = @{
      @"PUBLIC_SITE_URL" : @"站点地址", @"PUBLIC_SITE_TITLE" : @"站点标题", @"PUBLIC_SITE_DESCRIPTION" : @"站点描述",
      @"PUBLIC_SITE_AUTHOR" : @"作者", @"PUBLIC_SITE_AUTHOR_INTRO" : @"作者简介", @"PUBLIC_SITE_GITHUB" : @"GitHub 主页",
      @"PUBLIC_SITE_EMAIL" : @"邮箱", @"PUBLIC_HOME_GREETING" : @"首页问候语", @"PUBLIC_HOME_INTRO_TEMPLATE" : @"首页介绍模板",
      @"PUBLIC_HOME_POSTS_TITLE" : @"首页文章区标题", @"PUBLIC_HOME_POSTS_LINK_TEXT" : @"首页“全部文章”链接文字",
      @"PUBLIC_NAV_HOME_TEXT" : @"导航 · 首页", @"PUBLIC_NAV_BLOG_TEXT" : @"导航 · 文章", @"PUBLIC_NAV_SHUOSHUO_TEXT" : @"导航 · 说说",
      @"PUBLIC_NAV_FRIENDS_TEXT" : @"导航 · 友链", @"PUBLIC_NAV_ABOUT_TEXT" : @"导航 · 关于",
      @"PUBLIC_BLOG_TITLE" : @"文章页标题", @"PUBLIC_BLOG_INTRO" : @"文章页简介", @"PUBLIC_BLOG_DESCRIPTION" : @"文章页 SEO 描述",
      @"PUBLIC_SHUOSHUO_TITLE" : @"说说页标题", @"PUBLIC_SHUOSHUO_INTRO" : @"说说页简介", @"PUBLIC_SHUOSHUO_DESCRIPTION" : @"说说页 SEO 描述",
      @"PUBLIC_FRIENDS_TITLE" : @"友链页标题", @"PUBLIC_FRIENDS_INTRO" : @"友链页简介", @"PUBLIC_FRIENDS_DESCRIPTION" : @"友链页 SEO 描述",
      @"PUBLIC_ABOUT_TITLE" : @"关于页标题", @"PUBLIC_ABOUT_INTRO" : @"关于页简介", @"PUBLIC_ABOUT_DESCRIPTION" : @"关于页 SEO 描述",
      @"PUBLIC_FOOTER_SHOW_COPYRIGHT" : @"显示版权", @"PUBLIC_FOOTER_AUTHOR" : @"版权署名", @"PUBLIC_ICP_URL" : @"备案链接",
      @"PUBLIC_ICP_TEXT" : @"备案号", @"PUBLIC_FOOTER_POWERED_TEXT" : @"Powered by 前缀",
      @"PUBLIC_FOOTER_POWERED_ASTRO_TEXT" : @"Powered 链接 1 名称", @"PUBLIC_FOOTER_POWERED_ASTRO_URL" : @"Powered 链接 1 地址",
      @"PUBLIC_FOOTER_POWERED_AUTOMATION_TEXT" : @"Powered 链接 2 名称", @"PUBLIC_FOOTER_POWERED_AUTOMATION_URL" : @"Powered 链接 2 地址",
      @"PUBLIC_FOOTER_SHOW_RUNTIME" : @"显示运行时间", @"PUBLIC_FOOTER_RUNTIME_PREFIX" : @"运行时间前缀", @"PUBLIC_SITE_LAUNCH_DATE" : @"建站日期",
      @"PUBLIC_FRIEND_SITE_NAME" : @"本站名称", @"PUBLIC_FRIEND_SITE_URL" : @"本站链接", @"PUBLIC_FRIEND_SITE_AVATAR" : @"本站头像",
      @"PUBLIC_FRIEND_SITE_DESCRIPTION" : @"本站描述", @"PUBLIC_FRIENDS_APPLY_TITLE" : @"申请友链标题", @"PUBLIC_FRIENDS_APPLY_INTRO" : @"申请友链说明",
      @"PUBLIC_ABOUT_TERMINAL_TITLE" : @"终端标题", @"PUBLIC_ABOUT_USER" : @"终端用户名", @"PUBLIC_ABOUT_HOST" : @"终端主机名",
      @"PUBLIC_ABOUT_STACK" : @"技术栈", @"PUBLIC_ABOUT_FOCUS" : @"关注方向", @"PUBLIC_ABOUT_LABEL" : @"About 字段", @"PUBLIC_ABOUT_STATUS" : @"状态",
      @"PUBLIC_MEMOS_URL" : @"Memos 地址", @"PUBLIC_MEMOS_FEED_URL" : @"说说镜像地址", @"PUBLIC_TERMINAL_CHAT_API_URL" : @"终端留言接口",
      @"PUBLIC_UMAMI_SCRIPT_URL" : @"Umami 脚本地址", @"PUBLIC_UMAMI_WEBSITE_ID" : @"Umami 站点 ID",
      @"NAME" : @"名称", @"URL" : @"链接", @"DESCRIPTION" : @"描述", @"AVATAR" : @"头像", @"ENABLED" : @"启用",
    };
  });
  NSString *hit = m[key];
  if (hit) return hit;
  NSRange r = [key rangeOfString:@"^PUBLIC_FRIEND_[0-9]+_" options:NSRegularExpressionSearch];
  if (r.location != NSNotFound) return m[[key substringFromIndex:NSMaxRange(r)]] ?: key;
  return key;
}
@end
