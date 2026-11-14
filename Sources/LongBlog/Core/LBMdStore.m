#import "LBMdStore.h"
#import "LBMarkdown.h"
#import <CommonCrypto/CommonDigest.h>
#import "LBPlatform.h"
#include <string.h>
#include <stdlib.h>
#include <limits.h>

NSString *const LBMdStoreDidChange = @"LBMdStoreDidChange";

// Pure decisions are shared by production and executable host fixtures.
static int MDArticleOrder(long long publishedA, long long createdA, const char *idA,
                          long long publishedB, long long createdB, const char *idB) {
  long long a = publishedA ? publishedA : createdA, b = publishedB ? publishedB : createdB;
  if (a != b) return a > b ? -1 : 1;
  int order = strcmp(idA, idB); return order < 0 ? -1 : (order > 0 ? 1 : 0);
}
// 1 means apply an already-persisted transaction. Never means create/retry a commit.
static int MDRecoveryAction(const char *state) { return strcmp(state, "applied") == 0 ? 1 : 0; }
static int MDKeepLocalEdit(int matchesBefore, int confirmed, int matchesPayload, int deletedAndMissing) {
  return !matchesBefore && !(confirmed && (matchesPayload || deletedAndMissing));
}
// A download may be inspected before deciding whether to install it. Versionless
// old Markdown and all HTML sidecars can never replace an upgraded local source.
static int MDSingleSourceAllowsDownload(int singleSource, int asset, int sidecar,
                                        int needsPublish, int hasRemote, int remoteVersion) {
  if (!singleSource || asset) return 1;
  if (sidecar) return 0;
  return !needsPublish && (!hasRemote || remoteVersion >= 1);
}

static NSString *currentDateString(void) {
  NSDateFormatter *df = [NSDateFormatter new];
  df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSSZ";
  return [df stringFromDate:NSDate.date];
}

static long long msFromDateString(NSString *s) {
  if (![s isKindOfClass:NSString.class] || !s.length) return 0;
  static NSArray<NSDateFormatter *> *formatters;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *fmt in @[
      @"yyyy-MM-dd HH:mm:ss.SSSZ",
      @"yyyy-MM-dd HH:mm:ssZ",
      @"yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
      @"yyyy-MM-dd'T'HH:mm:ssXXXXX",
      @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
      @"yyyy-MM-dd'T'HH:mm:ss'Z'",
      @"yyyy-MM-dd"
    ]) {
      NSDateFormatter *df = [NSDateFormatter new];
      df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
      df.dateFormat = fmt;
      df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
      df.lenient = NO;
      [list addObject:df];
    }
    formatters = list;
  });
  @synchronized (formatters) {
    for (NSDateFormatter *df in formatters) {
      NSDate *d = [df dateFromString:s];
      if (d) return (long long)(d.timeIntervalSince1970 * 1000);
    }
  }
  return 0;
}

static NSError *MDError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:@"LBMdStore" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL MDPath(NSString *path) {
  if (![path isKindOfClass:NSString.class] || !path.length || [path hasPrefix:@"/"] || [path containsString:@"\\"] || [path containsString:@"%"] || [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
  for (NSString *p in [path componentsSeparatedByString:@"/"]) if (!p.length || [p hasPrefix:@"."] || [p isEqual:@".."]) return NO;
  return YES;
}
static NSString *MDQuote(NSString *value) {
  if (![value isKindOfClass:NSString.class]) return @"";
  NSString *s = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
  s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
  return s;
}
static BOOL MDID(NSString *noteId) { return MDPath(noteId) && ![noteId containsString:@"/"] && noteId.length <= 160; }
static NSString *MDDigest(NSData *data) {
  if (!data) return @"";
  unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
  NSMutableString *out = [NSMutableString string]; for (NSUInteger i = 0; i < sizeof(bytes); i++) [out appendFormat:@"%02x", bytes[i]]; return out;
}
// Pure string containment check: strip leading /private consistently on both
// sides, without invoking POSIX realpath(3) (which fails with EPERM in iOS sandboxes
// on security-scoped parent directories) or URLByResolvingSymlinksInPath (which
// refuses to strip /private on non-existent destination targets).
static NSString *MDSafePathStripPrivate(NSString *p) {
  if (![p isKindOfClass:NSString.class] || !p.length) return @"";
  p = p.stringByStandardizingPath;
  if ([p hasPrefix:@"/private/"]) p = [p substringFromIndex:8];
  return p;
}

static NSURL *MDRawURL(NSURL *root, NSString *relative) {
  if (!MDPath(relative)) return nil;
  if ([[NSFileManager.defaultManager attributesOfItemAtPath:root.path error:nil][NSFileType] isEqual:NSFileTypeSymbolicLink]) return nil;
  NSURL *url = [root URLByAppendingPathComponent:relative];
  // Reject symlinks on every existing component, not only the final file.
  NSURL *cursor = root;
  NSArray *parts = [relative componentsSeparatedByString:@"/"];
  for (NSString *part in parts) {
    cursor = [cursor URLByAppendingPathComponent:part];
    NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:cursor.path error:nil];
    if ([a[NSFileType] isEqual:NSFileTypeSymbolicLink]) return nil;
  }
  NSString *rootClean = MDSafePathStripPrivate(root.path);
  NSString *childClean = MDSafePathStripPrivate(url.path);
  if (!rootClean.length || !childClean.length) return nil;
  NSString *base = [rootClean hasSuffix:@"/"] ? rootClean : [rootClean stringByAppendingString:@"/"];
  if (![childClean hasPrefix:base]) return nil;
  return url;
}
// Layout manifest is the sole switch point. Staged copies and old originals remain
// recoverable if the process dies before/after that atomic switch. No user file is deleted.
static NSString *MDLayoutName(void) { return @".longblog-layout.json"; }
static NSURL *MDRawURL(NSURL *root, NSString *relative);
static NSDictionary *MDLayout(NSURL *root) {
  NSURL *url = [root URLByAppendingPathComponent:MDLayoutName()];
  NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
  if (!attrs) return @{};
  if (![attrs[NSFileType] isEqual:NSFileTypeRegular]) return nil;
  static NSCache *cache; static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 8; });
  NSString *cacheKey = root.path;
  NSDictionary *cached = [cache objectForKey:cacheKey];
  // Re-stat every time: symlinks are rejected even for cached layouts. Inode,
  // size, modification and creation timestamps invalidate atomic/external writes.
  NSDictionary *signature = @{@"inode":attrs[NSFileSystemFileNumber] ?: @0, @"size":attrs[NSFileSize] ?: @0, @"mtime":attrs[NSFileModificationDate] ?: @0, @"ctime":attrs[NSFileCreationDate] ?: @0};
  if ([cached[@"signature"] isEqual:signature]) return cached[@"articles"];
  NSData *data = [NSData dataWithContentsOfURL:url];
  id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![obj isKindOfClass:NSDictionary.class] || ![obj[@"version"] isEqual:@1] || ![obj[@"articles"] isKindOfClass:NSDictionary.class]) return nil;
  for (NSString *note in obj[@"articles"]) {
    NSString *path = obj[@"articles"][note];
    NSArray *parts = [path isKindOfClass:NSString.class] ? [path componentsSeparatedByString:@"/"] : @[];
    if (!MDID(note) || !MDPath(path) || parts.count != 2 || ![@[@"草稿", @"已发布"] containsObject:parts[0]] || ![parts[1] hasSuffix:[@"_" stringByAppendingString:note]]) return nil;
  }
  [cache setObject:@{@"signature":signature, @"articles":obj[@"articles"]} forKey:cacheKey];
  return obj[@"articles"];
}
static NSString *MDPhysical(NSURL *root, NSString *relative) {
  NSDictionary *layout = MDLayout(root); if (!layout) return nil;
  NSArray *parts = [relative componentsSeparatedByString:@"/"];
  if ([relative hasPrefix:@"assets/"] && parts.count >= 2) {
    NSString *directory = layout[parts[1]];
    if (directory) return [directory stringByAppendingPathComponent:parts.count == 2 ? @"assets" : [@"assets" stringByAppendingPathComponent:[[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@"/"]]];
  } else if (parts.count == 1 && [@[@"md", @"html"] containsObject:relative.pathExtension]) {
    NSString *directory = layout[relative.stringByDeletingPathExtension];
    if (directory) return [directory stringByAppendingPathComponent:[@"index." stringByAppendingString:relative.pathExtension]];
  }
  return relative;
}
static NSURL *MDURL(NSURL *root, NSString *relative) {
  if (!MDPath(relative)) return nil;
  NSString *physical = MDPhysical(root, relative);
  return physical ? MDRawURL(root, physical) : nil;
}
static NSArray *MDArticleIDs(NSURL *root) {
  NSDictionary *layout = MDLayout(root); if (!layout) return @[];
  NSMutableSet *ids = [NSMutableSet setWithArray:layout.allKeys];
  for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root.path error:nil]) {
    if ([file.pathExtension isEqual:@"md"] && MDID(file.stringByDeletingPathExtension)) [ids addObject:file.stringByDeletingPathExtension];
  }
  return [ids.allObjects sortedArrayUsingSelector:@selector(compare:)];
}
static NSString *MDTitleComponent(NSString *title, NSString *note) {
  NSMutableString *safe = [NSMutableString string];
  NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"/\\:%\n\r\t\"<>|?*"];
  for (NSUInteger i = 0; i < title.length && safe.length < 70; i++) {
    unichar c = [title characterAtIndex:i];
    [safe appendFormat:@"%C", (unichar)(([invalid characterIsMember:c] || [NSCharacterSet.controlCharacterSet characterIsMember:c]) ? '_' : c)];
  }
  NSString *trimmed = [safe stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ."]];
  return [NSString stringWithFormat:@"%@_%@", trimmed.length ? trimmed : @"未命名文章", note];
}
static BOOL MDCopyVerified(NSURL *source, NSURL *destination, NSError **error) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSDictionary *attrs = [fm attributesOfItemAtPath:source.path error:error];
  if (!attrs) return NO;
  if ([attrs[NSFileType] isEqual:NSFileTypeDirectory]) {
    if (![fm createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSArray *names = [fm contentsOfDirectoryAtPath:source.path error:error]; if (!names) return NO;
    for (NSString *name in names) if (!MDCopyVerified([source URLByAppendingPathComponent:name], [destination URLByAppendingPathComponent:name], error)) return NO;
    return YES;
  }
  if (![attrs[NSFileType] isEqual:NSFileTypeRegular]) { if (error) *error = MDError(400, @"归档拒绝符号链接或非普通文件"); return NO; }
  if (![fm copyItemAtURL:source toURL:destination error:error]) return NO;
  NSData *a = [NSData dataWithContentsOfURL:source], *b = [NSData dataWithContentsOfURL:destination];
  if (!a || !b || ![MDDigest(a) isEqual:MDDigest(b)]) { if (error) *error = MDError(500, @"归档副本校验失败，原件未删除"); return NO; }
  if (attrs[NSFileModificationDate] && ![fm setAttributes:@{NSFileModificationDate:attrs[NSFileModificationDate]} ofItemAtPath:destination.path error:error]) return NO;
  return YES;
}
static BOOL MDTreeEqual(NSURL *a, NSURL *b) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSDictionary *aa = a ? [fm attributesOfItemAtPath:a.path error:nil] : nil;
  NSDictionary *bb = b ? [fm attributesOfItemAtPath:b.path error:nil] : nil;
  if (!aa || !bb) return !aa && !bb;
  if (![aa[NSFileType] isEqual:bb[NSFileType]]) return NO;
  if ([aa[NSFileType] isEqual:NSFileTypeRegular]) {
    NSData *left = [NSData dataWithContentsOfURL:a], *right = [NSData dataWithContentsOfURL:b];
    return left && right && [left isEqual:right];
  }
  if (![aa[NSFileType] isEqual:NSFileTypeDirectory]) return NO;
  NSArray *an = [fm contentsOfDirectoryAtPath:a.path error:nil], *bn = [fm contentsOfDirectoryAtPath:b.path error:nil];
  if (!an || !bn || ![[NSSet setWithArray:an] isEqual:[NSSet setWithArray:bn]]) return NO;
  for (NSString *name in an) if (!MDTreeEqual([a URLByAppendingPathComponent:name], [b URLByAppendingPathComponent:name])) return NO;
  return YES;
}
static BOOL MDArchiveMatches(NSURL *root, NSString *note, NSURL *target) {
  NSFileManager *fm = NSFileManager.defaultManager;
  if (![[fm attributesOfItemAtPath:target.path error:nil][NSFileType] isEqual:NSFileTypeDirectory]) return NO;
  NSSet *allowed = [NSSet setWithArray:@[@"index.md", @"index.html", @"assets", @"README.longblog.txt", @".longblog-install-token"]];
  for (NSString *name in [fm contentsOfDirectoryAtPath:target.path error:nil]) {
    if (![allowed containsObject:name]) return NO;
    if ([name hasPrefix:@"."] || [name isEqual:@"README.longblog.txt"]) {
      if (![[fm attributesOfItemAtPath:[target URLByAppendingPathComponent:name].path error:nil][NSFileType] isEqual:NSFileTypeRegular]) return NO;
    }
  }
  for (NSString *ext in @[@"md", @"html"]) {
    NSURL *source = MDURL(root, [note stringByAppendingPathExtension:ext]);
    if (!source || !MDTreeEqual(source, [target URLByAppendingPathComponent:[@"index." stringByAppendingString:ext]])) return NO;
  }
  NSURL *assets = MDURL(root, [@"assets/" stringByAppendingString:note]);
  return assets && MDTreeEqual(assets, [target URLByAppendingPathComponent:@"assets"]);
}
static NSURL *MDHiddenURL(NSURL *root, NSString *name, NSError **error) {
  NSURL *url = [root URLByAppendingPathComponent:name];
  NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
  if (attrs && ![attrs[NSFileType] isEqual:NSFileTypeRegular]) { if (error) *error = MDError(400, @"归档恢复清单路径不安全"); return nil; }
  return url;
}
static BOOL MDRecoverLayoutInstall(NSURL *root, NSError **error) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSURL *journalURL = MDHiddenURL(root, @".longblog-layout-pending.json", error); if (!journalURL) return NO;
  if (![fm fileExistsAtPath:journalURL.path]) return YES;
  NSData *bytes = [NSData dataWithContentsOfURL:journalURL];
  id journal = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
  if (![journal isKindOfClass:NSDictionary.class] || ![journal[@"plans"] isKindOfClass:NSArray.class] || ![journal[@"token"] isKindOfClass:NSString.class]) { if (error) *error = MDError(400, @"归档恢复记录损坏，原件保留"); return NO; }
  NSDictionary *layout = MDLayout(root); if (!layout) { if (error) *error = MDError(400, @"归档清单损坏，停止恢复"); return NO; }
  BOOL switched = YES;
  for (id plan in journal[@"plans"]) {
    if (![plan isKindOfClass:NSDictionary.class] || !MDID(plan[@"note"]) || !MDPath(plan[@"desired"])) { if (error) *error = MDError(400, @"归档恢复路径损坏"); return NO; }
    if (![layout[plan[@"note"]] isEqual:plan[@"desired"]]) switched = NO;
  }
  if (!switched) {
    // The old manifest still owns all originals. Quarantine only directories marked
    // by this installation token; never move/delete arbitrary collision directories.
    NSURL *stageRoot = [root URLByAppendingPathComponent:@".longblog-stage"];
    if ([[fm attributesOfItemAtPath:stageRoot.path error:nil][NSFileType] isEqual:NSFileTypeSymbolicLink]) { if (error) *error = MDError(400, @"归档暂存目录不安全"); return NO; }
    NSURL *recovery = [stageRoot URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![fm createDirectoryAtURL:recovery withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    for (NSDictionary *plan in journal[@"plans"]) {
      // A verified identical pre-existing package is never owned by this token.
      if ([plan[@"adopt"] boolValue]) continue;
      NSURL *target = MDRawURL(root, plan[@"desired"]);
      if (!target) { if (error) *error = MDError(400, @"归档恢复目标不安全"); return NO; }
      if (![fm fileExistsAtPath:target.path]) continue;
      NSURL *marker = [target URLByAppendingPathComponent:@".longblog-install-token"];
      NSString *token = [[fm attributesOfItemAtPath:marker.path error:nil][NSFileType] isEqual:NSFileTypeRegular] ? [NSString stringWithContentsOfURL:marker encoding:NSUTF8StringEncoding error:nil] : nil;
      if (![token isEqual:journal[@"token"]]) { if (error) *error = MDError(409, @"归档目标有外部文件，未移动，原件保留"); return NO; }
      if (![fm moveItemAtURL:target toURL:[recovery URLByAppendingPathComponent:plan[@"note"]] error:error]) return NO;
    }
  }
  return [fm removeItemAtURL:journalURL error:error];
}

static BOOL MDArchiveMany(NSURL *root, NSDictionary *metas, NSError **error) {
  if (!MDRecoverLayoutInstall(root, error)) return NO;
  NSDictionary *existing = MDLayout(root);
  if (!existing) { if (error) *error = MDError(400, @"文章归档清单损坏，拒绝修改"); return NO; }
  NSFileManager *fm = NSFileManager.defaultManager;
  NSURL *stageRoot = [root URLByAppendingPathComponent:@".longblog-stage" isDirectory:YES];
  if ([[fm attributesOfItemAtPath:stageRoot.path error:nil][NSFileType] isEqual:NSFileTypeSymbolicLink]) { if (error) *error = MDError(400, @"归档暂存目录不安全"); return NO; }
  NSURL *stage = [stageRoot URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
  NSMutableDictionary *layout = [existing mutableCopy];
  NSMutableArray *plans = [NSMutableArray array];
  NSMutableSet *destinations = [NSMutableSet set];
  // Preflight every destination before copying or switching anything.
  for (NSString *note in [[metas allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary *meta = metas[note];
    if (!MDID(note) || (meta[@"title"] && ![meta[@"title"] isKindOfClass:NSString.class])) { if (error) *error = MDError(400, @"归档文章ID不安全"); return NO; }
    NSString *desired = [([meta[@"publish"] boolValue] ? @"已发布" : @"草稿") stringByAppendingPathComponent:MDTitleComponent(meta[@"title"] ?: @"", note)];
    NSString *folded = desired.precomposedStringWithCanonicalMapping.lowercaseString;
    if ([destinations containsObject:folded]) { if (error) *error = MDError(409, @"归档目录大小写或 Unicode 冲突"); return NO; }
    [destinations addObject:folded];
    if ([existing[note] isEqual:desired]) continue;
    NSURL *target = MDRawURL(root, desired);
    if (!target) { if (error) *error = MDError(400, @"目标文章目录不安全；原件保留"); return NO; }
    BOOL adopt = [fm fileExistsAtPath:target.path];
    if (adopt && !MDArchiveMatches(root, note, target)) { if (error) *error = MDError(409, @"目标文章目录有差异；未覆盖，请保留两个版本人工核对"); return NO; }
    NSURL *copy = [stage URLByAppendingPathComponent:note isDirectory:YES];
    [plans addObject:@{@"note":note, @"target":target, @"copy":copy, @"adopt":@(adopt)}]; layout[note] = desired;
  }
  if (!plans.count) return YES;
  NSString *installToken = NSUUID.UUID.UUIDString;
  for (NSDictionary *plan in plans) {
    NSString *note = plan[@"note"]; NSURL *copy = plan[@"copy"];
    if ([plan[@"adopt"] boolValue]) continue;
    // Preserve arbitrary author files in an already organized package on rename.
    if (existing[note]) {
      NSURL *sourceDirectory = MDRawURL(root, existing[note]);
      if (!sourceDirectory || !MDCopyVerified(sourceDirectory, copy, error)) return NO;
      if (![installToken writeToURL:[copy URLByAppendingPathComponent:@".longblog-install-token"] atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
      continue;
    }
    if (![fm createDirectoryAtURL:copy withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    for (NSString *ext in @[@"md", @"html"]) {
      NSURL *source = MDURL(root, [note stringByAppendingPathExtension:ext]);
      if (!source) { if (error) *error = MDError(400, @"归档源路径不安全"); return NO; }
      if ([fm fileExistsAtPath:source.path] && !MDCopyVerified(source, [copy URLByAppendingPathComponent:[@"index." stringByAppendingString:ext]], error)) return NO;
    }
    NSURL *assets = MDURL(root, [@"assets/" stringByAppendingString:note]);
    if (!assets) { if (error) *error = MDError(400, @"归档附件源路径不安全"); return NO; }
    if ([fm fileExistsAtPath:assets.path] && !MDCopyVerified(assets, [copy URLByAppendingPathComponent:@"assets"], error)) return NO;
    if (![installToken writeToURL:[copy URLByAppendingPathComponent:@".longblog-install-token"] atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    // Canonical URLs intentionally survive unchanged, including cross-article refs.
  }
  NSMutableArray *journalPlans = [NSMutableArray array];
  for (NSDictionary *plan in plans) [journalPlans addObject:@{@"note":plan[@"note"], @"desired":layout[plan[@"note"]], @"adopt":plan[@"adopt"]}];
  NSURL *journalURL = MDHiddenURL(root, @".longblog-layout-pending.json", error); if (!journalURL) return NO;
  NSData *journal = [NSJSONSerialization dataWithJSONObject:@{@"token":installToken, @"plans":journalPlans} options:NSJSONWritingSortedKeys error:error];
  if (!journal || ![journal writeToURL:journalURL options:NSDataWritingAtomic error:error]) return NO;
  NSMutableArray *installed = [NSMutableArray array];
  for (NSDictionary *plan in plans) {
    NSURL *target = plan[@"target"], *copy = plan[@"copy"];
    if ([plan[@"adopt"] boolValue]) {
      if (!MDArchiveMatches(root, plan[@"note"], target)) { if (error) *error = MDError(409, @"认领前目标内容改变，未切换清单"); return NO; }
      continue;
    }
    if (![fm createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error] || ![fm moveItemAtURL:copy toURL:target error:error]) {
      for (NSDictionary *prior in installed) [fm moveItemAtURL:prior[@"target"] toURL:prior[@"copy"] error:nil];
      return NO;
    }
    [installed addObject:plan];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"articles":layout} options:NSJSONWritingSortedKeys error:error];
  NSURL *manifest = [root URLByAppendingPathComponent:MDLayoutName()];
  BOOL unsafeManifest = [[fm attributesOfItemAtPath:manifest.path error:nil][NSFileType] isEqual:NSFileTypeSymbolicLink];
  if (unsafeManifest && error) *error = MDError(400, @"归档清单路径不安全");
  if (!data || unsafeManifest || ![data writeToURL:manifest options:NSDataWritingAtomic error:error]) {
    for (NSDictionary *plan in installed) [fm moveItemAtURL:plan[@"target"] toURL:plan[@"copy"] error:nil];
    return NO;
  }
  // Only after the ONE manifest commit, hide original bytes as recoverable backups.
  NSURL *backupRoot = [root URLByAppendingPathComponent:@".longblog-backups"];
  if ([[fm attributesOfItemAtPath:backupRoot.path error:nil][NSFileType] isEqual:NSFileTypeSymbolicLink]) return YES;
  NSURL *backup = [backupRoot URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
  for (NSDictionary *plan in plans) {
    NSString *note = plan[@"note"];
    NSURL *destination = [backup URLByAppendingPathComponent:note];
    if (![fm createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:nil]) continue;
    if (existing[note]) {
      NSURL *old = MDRawURL(root, existing[note]); if (old) [fm moveItemAtURL:old toURL:[destination URLByAppendingPathComponent:@"article"] error:nil];
    } else {
      for (NSString *ext in @[@"md", @"html"]) {
        NSURL *old = MDRawURL(root, [note stringByAppendingPathExtension:ext]); if (old && [fm fileExistsAtPath:old.path]) [fm moveItemAtURL:old toURL:[destination URLByAppendingPathComponent:[note stringByAppendingPathExtension:ext]] error:nil];
      }
      NSURL *old = MDRawURL(root, [@"assets/" stringByAppendingString:note]); if (old && [fm fileExistsAtPath:old.path]) [fm moveItemAtURL:old toURL:[destination URLByAppendingPathComponent:@"assets"] error:nil];
    }
  }
  return [fm removeItemAtURL:journalURL error:error];
}
static BOOL MDArchive(NSURL *root, NSString *note, NSDictionary *meta, NSError **error) {
  return MDArchiveMany(root, @{note:meta}, error);
}
static BOOL MDArchiveAll(NSURL *root, NSError **error) {
  if (!MDLayout(root)) { if (error) *error = MDError(400, @"文章归档清单损坏"); return NO; }
  NSMutableDictionary *metas = [NSMutableDictionary dictionary];
  for (NSString *note in MDArticleIDs(root)) {
    NSURL *url = MDURL(root, [note stringByAppendingString:@".md"]);
    NSString *text = url ? [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!text) continue; // deleted manifest entries are tombstones, not recreated articles
    NSDictionary *meta = [LBMdStore parseFrontmatterAndBody:text];
    if (meta[@"id"] && ![meta[@"id"] isEqual:note]) { if (error) *error = MDError(409, @"文章 ID 与文件名不一致，未迁移"); return NO; }
    metas[note] = meta;
  }
  return MDArchiveMany(root, metas, error);
}

static NSString *MDDateString(NSDate *date) {
  NSDateFormatter *df = [NSDateFormatter new];
  df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX";
  return [df stringFromDate:date];
}
static NSString *MDValidDate(id value) {
  if (![value isKindOfClass:NSString.class] || !msFromDateString(value)) return @"";
  if ([value length] == 10) return [value stringByAppendingString:@"T00:00:00.000Z"];
  return value;
}
// Only metadata/filesystem evidence is inherited. A read never invents "now".
// Date-only legacy values deliberately mean UTC midnight, not invented historical time.
static NSDictionary *MDDates(NSDictionary *meta, NSURL *file) {
  NSString *created = MDValidDate(meta[@"createdAt"]), *updated = MDValidDate(meta[@"updatedAt"]), *published = MDValidDate(meta[@"publishedAt"]);
  NSDictionary *attrs = file ? [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil] : nil;
  NSString *source = @"metadata";
  if (!created.length) {
    created = published.length ? published : updated;
    if (!created.length) {
      NSDate *evidence = attrs[NSFileModificationDate] ?: attrs[NSFileCreationDate];
      created = evidence ? MDDateString(evidence) : @"1970-01-01T00:00:00.000Z";
      source = evidence ? @"filesystem" : @"unknown";
    } else source = @"inherited";
  }
  if (!updated.length) updated = published.length ? published : created;
  if (!published.length && [meta[@"publish"] boolValue]) published = updated.length ? updated : created;
  return @{@"createdAt":@(msFromDateString(created)), @"updatedAt":@(msFromDateString(updated)), @"publishedAt":@(msFromDateString(published)), @"createdAtString":created, @"updatedAtString":updated, @"publishedAtString":published, @"createdAtSource":source,
    @"datePrecisionNote":@"旧文仅日期按 UTC 00:00:00 规范；缺创建时间优先继承原发布日期、更新时间，再用文件时间，不代表已知历史精确时刻。"};
}
static void MDApplyDateStrings(NSMutableDictionary *meta, NSDictionary *dates) {
  for (NSString *key in @[@"createdAt", @"updatedAt", @"publishedAt"]) {
    NSString *value = dates[[key stringByAppendingString:@"String"]];
    if (value.length) meta[key] = value; else [meta removeObjectForKey:key];
  }
}
static NSString *MDDecodedLocalPath(NSString *input) {
  if (![input isKindOfClass:NSString.class]) return nil;
  NSString *path = input;
  if ([path hasPrefix:@"/trilium-assets/"]) path = [@"/assets/" stringByAppendingString:[path substringFromIndex:@"/trilium-assets/".length]];
  if ([path hasPrefix:@"/assets/"]) path = [path substringFromIndex:1];
  if (![path hasPrefix:@"assets/"]) return nil;
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *encoded in [path componentsSeparatedByString:@"/"]) {
    NSString *decoded = encoded.stringByRemovingPercentEncoding;
    if (!MDPath(decoded) || [decoded containsString:@"/"]) return nil;
    [parts addObject:decoded];
  }
  return parts.count >= 3 ? [parts componentsJoinedByString:@"/"] : nil;
}

// Portable delimiter scanner; tests compile this exact function on the host.
static size_t MDReferenceEnd(const char *text, size_t length, size_t start, char quote) {
  size_t depth = 0;
  for (size_t i = start; i < length; i++) {
    unsigned char c = (unsigned char)text[i];
    if (c == '\\' && i + 1 < length) { i++; continue; }
    if (quote) { if (c == (unsigned char)quote || c == '\n' || c == '\r') return i; continue; }
    if (c <= 32 || c == ']' || c == '<' || c == '>' || c == '\'' || c == '"') return i;
    if (c == '(') depth++;
    if (c == ')') { if (!depth) return i; depth--; }
  }
  return length;
}
static NSArray *MDAssetReferences(NSString *markdown, NSString *html, NSError **error) {
  // Ignore fenced examples: example URLs are not publish dependencies.
  NSRegularExpression *fences = [NSRegularExpression regularExpressionWithPattern:@"(?ms)^ {0,3}(`{3,}|~{3,})[^\\n]*\\n.*?^ {0,3}\\1[^\\n]*(?:\\n|$)" options:0 error:nil];
  NSString *body = [fences stringByReplacingMatchesInString:markdown ?: @"" options:0 range:NSMakeRange(0, markdown.length) withTemplate:@""];
  NSRegularExpression *inlineCode = [NSRegularExpression regularExpressionWithPattern:@"(`+)[^`\\n]*?\\1(?!`)" options:0 error:nil];
  body = [inlineCode stringByReplacingMatchesInString:body options:0 range:NSMakeRange(0, body.length) withTemplate:@""];
  NSString *text = [body stringByAppendingFormat:@"\n%@", html ?: @""];
  // Only link/image destinations, reference definitions, HTML resource attributes,
  // autolinks and CSS url() are dependencies. Never match arbitrary prose/code.
  NSString *pattern = @"(?:!?\\[[^\\]\\n]*\\]\\(\\s*|(?m:^ {0,3}\\[[^\\]\\n]+\\]:[ \\t]*)|(?i:\\b(?:src|href|poster|data-src)\\s*=\\s*)|(?i:url\\(\\s*)|<)([\\\"'<>]?)(/?(?:assets|trilium-assets)/)";
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
  NSMutableSet *paths = [NSMutableSet set];
  for (NSTextCheckingResult *match in [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
    NSRange opening = [match rangeAtIndex:1], prefix = [match rangeAtIndex:2];
    NSString *marker = [text substringWithRange:opening];
    char quote = [marker isEqual:@"<"] ? '>' : ([marker isEqual:@"\""] ? '"' : ([marker isEqual:@"'"] ? '\'' : 0));
    NSData *bytes = [[text substringFromIndex:prefix.location] dataUsingEncoding:NSUTF8StringEncoding];
    size_t end = MDReferenceEnd(bytes.bytes, bytes.length, 0, quote);
    NSString *destination = [[NSString alloc] initWithBytes:bytes.bytes length:end encoding:NSUTF8StringEncoding];
    NSRange suffix = [destination rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
    if (suffix.location != NSNotFound) destination = [destination substringToIndex:suffix.location];
    destination = [[destination stringByReplacingOccurrencesOfString:@"\\(" withString:@"("] stringByReplacingOccurrencesOfString:@"\\)" withString:@")"];
    NSString *local = MDDecodedLocalPath(destination);
    if (!local) { if (error) *error = MDError(400, @"文章包含不安全附件引用"); return nil; }
    [paths addObject:local];
  }
  return [paths.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

static NSData *MDRead(NSURL *root, NSString *relative) { NSURL *url = MDURL(root, relative); return url ? [NSData dataWithContentsOfURL:url] : nil; }
static BOOL MDWrite(NSURL *root, NSString *relative, NSData *data, NSError **error) {
  NSURL *url = MDURL(root, relative);
  if (!url) { if (error) *error = MDError(400, @"本地路径不安全（含符号链接或路径穿越）"); return NO; }
  if (![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
  return [data writeToURL:url options:NSDataWritingAtomic error:error];
}
static NSString *MDStateName(void) { return @".longblog-sync.json"; }
// This legacy path appears ONLY in the compatibility mapping. New writes always use /assets/.
static NSString *MDLegacyAssets(void) { return @"public/trilium-assets/"; }
static NSString *MDLocalPath(NSString *remote) {
  if ([remote hasPrefix:@"content/posts/"]) return [remote substringFromIndex:@"content/posts/".length];
  if ([remote hasPrefix:@"public/assets/"]) return [remote substringFromIndex:@"public/".length];
  if ([remote hasPrefix:MDLegacyAssets()]) return [@"assets/" stringByAppendingString:[remote substringFromIndex:MDLegacyAssets().length]];
  return nil;
}
static NSString *MDCanonicalReferences(NSString *text) {
  NSString *old = [@"/" stringByAppendingString:[MDLegacyAssets() substringFromIndex:@"public/".length]];
  return [text stringByReplacingOccurrencesOfString:old withString:@"/assets/"];
}
static NSString *MDGroup(NSString *local) {
  NSArray *parts = [local componentsSeparatedByString:@"/"];
  return [local hasPrefix:@"assets/"] ? (parts.count >= 3 ? parts[1] : nil) : local.stringByDeletingPathExtension;
}
static NSString *MDBodyDigest(NSData *data) {
  NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
  NSString *body = [LBMdStore parseFrontmatterAndBody:text ?: @""][@"markdown"] ?: @"";
  body = [body stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
  while ([body hasSuffix:@"\n"]) body = [body substringToIndex:body.length - 1];
  return MDDigest([MDCanonicalReferences(body) dataUsingEncoding:NSUTF8StringEncoding]);
}
// Ignore only the save clock, not author metadata. A body-only comparison would
// silently acknowledge title/summary/tags edits as remotely synced and lose them.
static NSString *MDContentDigest(NSData *data) {
  NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  if (!text) return @"";
  NSMutableDictionary *meta = [[LBMdStore parseFrontmatterAndBody:text] mutableCopy];
  [meta removeObjectForKey:@"updatedAt"]; [meta removeObjectForKey:@"markdown"];
  NSDictionary *content = @{@"metadata":meta, @"bodyDigest":MDBodyDigest(data)};
  return MDDigest([NSJSONSerialization dataWithJSONObject:content options:NSJSONWritingSortedKeys error:nil]);
}
static NSDictionary *MDRecord(NSString *remote, NSString *sha, NSString *local, NSData *data) {
  NSMutableDictionary *record = [@{@"remote":remote, @"sha":sha, @"baseline":MDDigest(data)} mutableCopy];
  if (![local hasPrefix:@"assets/"] && [local.pathExtension isEqual:@"md"]) {
    record[@"bodyBaseline"] = MDBodyDigest(data);
    record[@"contentBaseline"] = MDContentDigest(data);
  }
  return record;
}
static BOOL MDSingleSource(NSURL *root, NSString *note) {
  NSData *data = MDRead(root, [note stringByAppendingString:@".md"]);
  NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  NSDictionary *meta = [LBMdStore parseFrontmatterAndBody:text ?: @""];
  return [meta[@"singleSourceVersion"] integerValue] >= 1 || [meta[@"bodyFormat"] isEqual:@"html"];
}
static BOOL MDBatchItemsValid(id items) {
  if (![items isKindOfClass:NSArray.class]) return NO;
  NSMutableSet *ids = [NSMutableSet set];
  for (id item in items) {
    if (![item isKindOfClass:NSDictionary.class] || !MDID(item[@"id"]) || ![@[@"publish", @"update", @"unpublish"] containsObject:item[@"action"]]) return NO;
    NSString *folded = [item[@"id"] precomposedStringWithCanonicalMapping].lowercaseString;
    if ([ids containsObject:folded]) return NO;
    [ids addObject:folded];
  }
  return YES;
}
static NSDictionary *MDLoadState(NSURL *root, NSString *repo, NSError **error) {
  NSURL *url = [root URLByAppendingPathComponent:MDStateName()];
  NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
  if ([attrs[NSFileType] isEqual:NSFileTypeSymbolicLink]) { if (error) *error = MDError(400, @"同步状态不能是符号链接"); return nil; }
  NSData *data = [NSData dataWithContentsOfURL:url];
  if (!data && attrs) { if (error) *error = MDError(400, @"同步状态存在但无法读取，拒绝覆盖或丢弃待确认记录"); return nil; }
  if (!data) return @{@"version":@1, @"repository":repo.lowercaseString, @"branch":@"main", @"files":@{}};
  id state = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![state isKindOfClass:NSDictionary.class] || ![state[@"version"] isEqual:@1] || ![state[@"files"] isKindOfClass:NSDictionary.class]) { if (error) *error = MDError(400, @"同步状态损坏，拒绝覆盖本地文章"); return nil; }
  if (![state[@"repository"] isEqual:repo.lowercaseString] || ![state[@"branch"] isEqual:@"main"]) { if (error) *error = MDError(409, @"此文件夹已绑定其他 GitHub 仓库；请为新仓库另选文件夹"); return nil; }
  NSDictionary *records = state[@"files"];
  for (id local in records) {
    id record = records[local];
    if (!MDPath(local) || ![record isKindOfClass:NSDictionary.class] || ![record[@"remote"] isKindOfClass:NSString.class] || ![MDLocalPath(record[@"remote"]) isEqual:local] || ![record[@"sha"] isKindOfClass:NSString.class] || [record[@"sha"] length] != 40 || ![record[@"baseline"] isKindOfClass:NSString.class] || [record[@"baseline"] length] != 64) {
      if (error) *error = MDError(400, @"同步文件基线损坏，拒绝覆盖"); return nil;
    }
  }
  return state;
}
static BOOL MDSaveState(NSURL *root, NSDictionary *state, NSError **error) {
  NSURL *url = [root URLByAppendingPathComponent:MDStateName()];
  if ([[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil][NSFileType] isEqual:NSFileTypeSymbolicLink]) { if (error) *error = MDError(400, @"同步状态路径不安全"); return NO; }
  NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:error];
  return data && [data writeToURL:url options:NSDataWritingAtomic error:error];
}
// Revert guards are value snapshots, never file URLs supplied by the caller.
// Locate ONLY the true scalar in a draft's frontmatter. No serializer round-trip:
// comments, unknown YAML, CRLF and the entire body must remain byte-for-byte intact.
static int MDRevertDraftRange(const char *bytes, size_t length, size_t *start, size_t *end) {
  size_t cursor = 0, found = 0, valueStart = 0, valueEnd = 0;
  int first = 1;
  while (cursor < length) {
    size_t line = cursor;
    while (cursor < length && bytes[cursor] != '\n') cursor++;
    size_t limit = cursor;
    if (limit > line && bytes[limit - 1] == '\r') limit--;
    if (cursor < length) cursor++;
    if (limit - line == 3 && memcmp(bytes + line, "---", 3) == 0) {
      if (first) { first = 0; continue; }
      if (found == 1 && valueEnd > valueStart) { *start = valueStart; *end = valueEnd; return 1; }
      return 0;
    }
    if (first) return 0;
    if (limit - line < 8 || memcmp(bytes + line, "publish:", 8) != 0) continue;
    if (++found > 1) return 0;
    size_t p = line + 8;
    while (p < limit && (bytes[p] == ' ' || bytes[p] == '\t')) p++;
    char quote = p < limit && (bytes[p] == '\'' || bytes[p] == '"') ? bytes[p++] : 0;
    if (limit - p < 4 || memcmp(bytes + p, "true", 4) != 0) return 0;
    valueStart = p; p += 4; valueEnd = p;
    if (quote && (p >= limit || bytes[p++] != quote)) return 0;
    while (p < limit && (bytes[p] == ' ' || bytes[p] == '\t')) p++;
    if (p < limit && bytes[p] != '#') return 0;
  }
  return 0;
}
static NSData *MDRevertDraftData(NSData *source) {
  size_t start = 0, end = 0;
  if (!source || !MDRevertDraftRange(source.bytes, source.length, &start, &end)) return nil;
  NSMutableData *draft = [source mutableCopy];
  [draft replaceBytesInRange:NSMakeRange(start, end - start) withBytes:"false" length:5];
  return draft;
}

static NSString *MDJSONDigest(id value) {
  return MDDigest([NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil]);
}
static NSString *MDGitBlobDigest(NSData *data) {
  if (!data) return @"";
  NSMutableData *header = [[[NSString stringWithFormat:@"blob %lu", (unsigned long)data.length] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  unsigned char zero = 0; [header appendBytes:&zero length:1];
  CC_SHA1_CTX context; CC_SHA1_Init(&context); CC_SHA1_Update(&context, header.bytes, (CC_LONG)header.length); CC_SHA1_Update(&context, data.bytes, (CC_LONG)data.length);
  unsigned char bytes[CC_SHA1_DIGEST_LENGTH]; CC_SHA1_Final(bytes, &context);
  NSMutableString *out = [NSMutableString string]; for (NSUInteger i = 0; i < sizeof(bytes); i++) [out appendFormat:@"%02x", bytes[i]]; return out;
}
static NSDictionary *MDRevertGuard(NSURL *root, NSString *repo, NSDictionary *state, NSString *note) {
  if (!state || state[@"pending"] || state[@"singleSourcePendingReview"] || !MDID(note) || !MDLayout(root)) return nil;
  NSURL *layoutURL = MDHiddenURL(root, MDLayoutName(), nil);
  if (!layoutURL) return nil;
  NSMutableSet *paths = [NSMutableSet setWithArray:@[[note stringByAppendingString:@".md"], [note stringByAppendingString:@".html"]]];
  for (NSString *local in state[@"files"]) if ([MDGroup(local) isEqual:note]) [paths addObject:local];
  NSMutableDictionary *digests = [NSMutableDictionary dictionary];
  for (NSString *local in paths) {
    NSURL *url = MDURL(root, local); if (!url) return nil;
    NSError *attributeError = nil;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&attributeError];
    BOOL missing = [attributeError.domain isEqual:NSCocoaErrorDomain] && (attributeError.code == NSFileNoSuchFileError || attributeError.code == NSFileReadNoSuchFileError);
    if (!attrs && attributeError && !missing) return nil; // unreadable is NOT absent
    NSData *data = MDRead(root, local);
    if (attrs && (![attrs[NSFileType] isEqual:NSFileTypeRegular] || !data)) return nil;
    digests[local] = MDDigest(data);
  }
  return @{@"repository":repo.lowercaseString ?: @"", @"root":MDSafePathStripPrivate(root.path),
           @"state":MDJSONDigest(state), @"layout":MDDigest([NSData dataWithContentsOfURL:layoutURL]), @"files":digests};
}
// A journal is an audit/backup, not an instruction to replay stale editor bytes.
static BOOL MDRevertJournalClear(NSURL *root, NSError **error) {
  NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root.path error:error]; if (!names) return NO;
  for (NSString *name in names) {
    if (![name hasPrefix:@".longblog-revert-"] || ![name hasSuffix:@".json"]) continue;
    NSURL *url = MDHiddenURL(root, name, error); if (!url) return NO;
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSDictionary *journal = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![journal isKindOfClass:NSDictionary.class] || ![journal[@"phase"] isEqual:@"applied"]) {
      if (error) *error = MDError(409, @"存在未完成的本地撤销备份，请先人工核对 .longblog-revert-*.json；未自动回放"); return NO;
    }
  }
  NSURL *layoutPending = MDHiddenURL(root, @".longblog-layout-pending.json", error);
  if (!layoutPending || [NSFileManager.defaultManager fileExistsAtPath:layoutPending.path]) {
    if (error && !*error) *error = MDError(409, @"目录迁移尚未完成，未撤销文章"); return NO;
  }
  return YES;
}

@interface LBMdStore ()
@property (nonatomic, strong) id articleTask;
@property (atomic) BOOL revertInstalling;
@property (nonatomic, strong) NSMutableArray *syncCallbacks;
- (void)beginArticleOperation:(NSString *)operation note:(NSString *)note done:(void (^)(NSError *))done;
- (instancetype)initWithFolderBookmark:(NSData *)bookmark;
- (void)resolveFolderWithBookmark:(NSData *)bookmark renew:(BOOL)renew;
- (void)beginArticleOperation:(NSString *)operation note:(NSString *)note batch:(NSArray *)batch message:(NSString *)message done:(void (^)(NSError *))done;
@end
@interface LBArticleTask : NSObject
@property (nonatomic, strong) LBMdStore *store;
@property (nonatomic, strong) LBGitHub *github;
@property (nonatomic, strong) NSURL *root;
@property (nonatomic, copy) NSString *operation, *note, *message;
@property (nonatomic, copy) NSArray *batchItems;
@property (nonatomic, copy) void (^done)(NSError *);
@property (nonatomic, strong) NSMutableDictionary *state, *records, *staged, *changes, *before;
@property (nonatomic, strong) NSDictionary *snapshot, *mapping;
@property (nonatomic, strong) NSArray *paths;
@property (nonatomic, strong) NSMutableSet *protectedGroups;
@property (nonatomic) NSUInteger index;
@property (nonatomic) BOOL recoveredDifferentRequest;
- (void)resumePending:(NSDictionary *)pending;
- (void)applyPublish:(NSDictionary *)result;
- (void)prepareBatch;
- (void)applyBatch:(NSDictionary *)result;
- (void)prepareRevert;
- (void)downloadRevertNext;
- (void)applyRevert;
- (void)start;
@end

@implementation LBMdStore {
  NSURL *_activeFolderURL;
  BOOL _accessingSecurityScope;
  NSURL *_scopedFolderURL;
}

- (void)syncFromGitHub:(void (^)(NSError *))done { [self beginArticleOperation:@"sync" note:nil done:done]; }
- (void)forceSyncFromGitHub:(void (^)(NSError *))done { [self beginArticleOperation:@"forceSync" note:nil done:done]; }
- (void)publishArticle:(NSString *)noteId done:(void (^)(NSError *))done { [self beginArticleOperation:@"publish" note:noteId done:done]; }
- (void)unpublishArticle:(NSString *)noteId done:(void (^)(NSError *))done { [self beginArticleOperation:@"unpublish" note:noteId done:done]; }
- (void)deleteArticle:(NSString *)noteId done:(void (^)(NSError *))done { [self beginArticleOperation:@"delete" note:noteId done:done]; }
- (void)beginArticleOperation:(NSString *)operation note:(NSString *)note done:(void (^)(NSError *))done {
  [self beginArticleOperation:operation note:note batch:nil message:nil done:done];
}
- (void)beginArticleOperation:(NSString *)operation note:(NSString *)note batch:(NSArray *)batch message:(NSString *)message done:(void (^)(NSError *))done {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.articleTask) {
      LBArticleTask *active = self.articleTask;
      if (([operation isEqual:@"sync"] || [operation isEqual:@"forceSync"]) && [active.operation isEqual:operation] && [active.github.repository.lowercaseString isEqual:LBStore.repo.lowercaseString] && [active.root isEqual:self.articlesFolderURL]) {
        if (done) [self.syncCallbacks addObject:[done copy]];
      } else if (done) done(MDError(409, @"文章同步或发布正在进行，请稍后重试"));
      return;
    }
    if (![operation isEqual:@"sync"] && ![operation isEqual:@"forceSync"] && ![operation isEqual:@"batch"] && ![operation isEqual:@"revert"] && !MDID(note)) { if (done) done(MDError(400, @"文章 ID 不安全")); return; }
    LBArticleTask *task = [LBArticleTask new]; task.store = self; task.operation = operation; task.note = note;
    task.batchItems = batch; task.message = message;
    task.root = self.articlesFolderURL; task.github = [[LBGitHub alloc] initWithRepository:LBStore.repo];
    self.articleTask = task; self.syncCallbacks = [NSMutableArray array]; if (done) [self.syncCallbacks addObject:[done copy]];
    // The store retains the task until finish; the task retains only this weak store
    // through its callback, avoiding a recursive block/self-release lifetime hazard.
    __weak LBMdStore *weakStore = self;
    task.done = ^(NSError *error) {
      LBMdStore *store = weakStore; NSArray *callbacks = [store.syncCallbacks copy];
      store.articleTask = nil; store.syncCallbacks = nil;
      [NSNotificationCenter.defaultCenter postNotificationName:LBMdStoreDidChange object:store];
      for (void (^callback)(NSError *) in callbacks) callback(error);
    };
    [task start];
  });
}

+ (instancetype)shared {
  static LBMdStore *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ store = [LBMdStore new]; });
  return store;
}

- (instancetype)init {
  if ((self = [super init])) {
    [self resolveFolder];
  }
  return self;
}

- (instancetype)initWithLocalFolderURL:(NSURL *)url error:(NSError **)error {
  if (!url.isFileURL || ![[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:error][NSFileType] isEqual:NSFileTypeDirectory]) {
    if (error && !*error) *error = MDError(400, @"本地工作区必须是已存在的非符号链接目录");
    return nil;
  }
  if ((self = [super init])) _activeFolderURL = url.URLByStandardizingPath;
  return self;
}

- (instancetype)initWithFolderBookmark:(NSData *)bookmark {
  if ((self = [super init])) [self resolveFolderWithBookmark:bookmark renew:NO];
  return self;
}

+ (NSArray<NSDictionary *> *)listArticlesForFolderBookmark:(NSData *)bookmark {
  // This instance never participates in editing/sync and retains its own scope
  // until the entire scan finishes, even if the UI selects another directory.
  LBMdStore *store = [[LBMdStore alloc] initWithFolderBookmark:bookmark];
  return [store listArticles];
}

- (void)dealloc {
  if (_accessingSecurityScope && _scopedFolderURL) {
    // Stop on the exact instance that started access; a standardized copy has no sandbox extension.
    [_scopedFolderURL stopAccessingSecurityScopedResource];
  }
}

- (void)resolveFolder {
  [self resolveFolderWithBookmark:[NSUserDefaults.standardUserDefaults dataForKey:@"LBArticlesFolderBookmark"] renew:YES];
}

- (void)resolveFolderWithBookmark:(NSData *)bookmarkData renew:(BOOL)renew {
  if (_accessingSecurityScope && _scopedFolderURL) {
    // Stop on the exact instance that started access; a standardized copy has no sandbox extension.
    [_scopedFolderURL stopAccessingSecurityScopedResource];
    _accessingSecurityScope = NO;
  }
  _activeFolderURL = nil;

  if (bookmarkData.length) {
    BOOL isStale = NO;
    NSError *err = nil;
    NSURL *resolved = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                options:NSURLBookmarkResolutionWithSecurityScope | NSURLBookmarkResolutionWithoutUI
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&isStale
                                                  error:&err];
    if (resolved.isFileURL && !err) {
      BOOL scoped = [resolved startAccessingSecurityScopedResource];
      NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:resolved.path error:nil];
      // Unsandboxed macOS can legitimately return NO for startAccessing; require
      // actual directory access rather than falling back merely on that result.
      if ([attributes[NSFileType] isEqual:NSFileTypeDirectory] && [NSFileManager.defaultManager isReadableFileAtPath:resolved.path]) {
        _accessingSecurityScope = scoped;
        _scopedFolderURL = scoped ? resolved : nil;
        _activeFolderURL = resolved;
        if (isStale && renew) {
          // Re-create stale bookmark
          NSData *renewed = [resolved bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                               includingResourceValuesForKeys:nil
                                                relativeToURL:nil
                                                        error:nil];
          if (renewed) [NSUserDefaults.standardUserDefaults setObject:renewed forKey:@"LBArticlesFolderBookmark"];
        }
        return;
      }
      if (scoped) [resolved stopAccessingSecurityScopedResource];
    }
  }

  // Internal storage never probes Documents or imports an arbitrary notes tree.
  NSURL *posts = [LBApplicationSupportURL() URLByAppendingPathComponent:@"Posts" isDirectory:YES];
  if (renew) [NSFileManager.defaultManager createDirectoryAtURL:posts withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
  _activeFolderURL = posts;
  // Empty folders are populated only by an explicit GitHub sync. Bundled/workspace
  // content has no repository ownership or SHA baseline and must not be auto-adopted.
}

- (NSURL *)articlesFolderURL {
  if (!_activeFolderURL) [self resolveFolder];
  return _activeFolderURL;
}

- (BOOL)isCustomFolder {
  return [NSUserDefaults.standardUserDefaults dataForKey:@"LBArticlesFolderBookmark"] != nil;
}

- (NSString *)folderDisplayName {
  NSString *customName = [NSUserDefaults.standardUserDefaults stringForKey:@"LBArticlesFolderName"];
  if (customName.length) return customName;
  if (self.isCustomFolder && _activeFolderURL.lastPathComponent.length) {
    return _activeFolderURL.lastPathComponent;
  }
  return @"默认目录 (Application Support/longBlog/Posts)";
}

- (BOOL)setFolderURL:(NSURL *)url error:(NSError **)outError {
  if (self.revertInstalling) { if (outError) *outError = MDError(409, @"正在安装本地撤销，暂不能修改文章或目录"); return NO; }
  if (self.articleTask) { if (outError) *outError = MDError(409, @"文章操作进行中，暂不能修改目录"); return NO; }
  if (!url.isFileURL) { if (outError) *outError = MDError(400, @"请选择本地文件夹"); return NO; }
  if (_accessingSecurityScope && _scopedFolderURL) {
    // Stop on the exact instance that started access; a standardized copy has no sandbox extension.
    [_scopedFolderURL stopAccessingSecurityScopedResource];
    _accessingSecurityScope = NO;
  }

  BOOL ok = [url startAccessingSecurityScopedResource];
  NSError *err = nil;
  NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&err];
  if (![attributes[NSFileType] isEqual:NSFileTypeDirectory] || ![NSFileManager.defaultManager isWritableFileAtPath:url.path]) {
    if (ok) [url stopAccessingSecurityScopedResource];
    if (outError) *outError = err ?: MDError(400, @"所选文件夹不可写或不是普通目录");
    [self resolveFolder];
    return NO;
  }
  NSData *data = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
               includingResourceValuesForKeys:nil
                                relativeToURL:nil
                                        error:&err];
  if (!data || err) {
    if (ok) [url stopAccessingSecurityScopedResource];
    if (outError) *outError = err ?: [NSError errorWithDomain:@"LBMdStore" code:500 userInfo:@{NSLocalizedDescriptionKey:@"无法创建文件夹安全书签"}];
    [self resolveFolder];
    return NO;
  }

  [NSUserDefaults.standardUserDefaults setObject:data forKey:@"LBArticlesFolderBookmark"];
  [NSUserDefaults.standardUserDefaults setObject:url.lastPathComponent ?: @"文章目录" forKey:@"LBArticlesFolderName"];
  _activeFolderURL = url.URLByStandardizingPath;
  _scopedFolderURL = url;
  _accessingSecurityScope = ok;

  [NSNotificationCenter.defaultCenter postNotificationName:LBMdStoreDidChange object:self];
  return YES;
}

- (void)resetFolderToDefault {
  if (self.revertInstalling) return;
  if (self.articleTask) return;
  if (_accessingSecurityScope && _scopedFolderURL) {
    // Stop on the exact instance that started access; a standardized copy has no sandbox extension.
    [_scopedFolderURL stopAccessingSecurityScopedResource];
    _accessingSecurityScope = NO;
  }
  [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LBArticlesFolderBookmark"];
  [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LBArticlesFolderName"];
  [self resolveFolder];
  [NSNotificationCenter.defaultCenter postNotificationName:LBMdStoreDidChange object:self];
}

- (NSURL *)assetsFolderForNote:(NSString *)noteId {
  if (!MDID(noteId)) return nil;
  NSURL *base = self.articlesFolderURL;
  NSURL *assets = MDURL(base, [@"assets/" stringByAppendingString:noteId]);
  if (!assets) return nil;
  [NSFileManager.defaultManager createDirectoryAtURL:assets withIntermediateDirectories:YES attributes:nil error:nil];
  return assets;
}

#pragma mark - Note ID Generator

- (NSString *)generateUniqueNoteID {
  static const char base62[] = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
  NSURL *dir = self.articlesFolderURL;
  NSFileManager *fm = NSFileManager.defaultManager;
  for (int attempt = 0; attempt < 100; attempt++) {
    char buf[13];
    for (int i = 0; i < 12; i++) {
      buf[i] = base62[arc4random_uniform(62)];
    }
    buf[12] = '\0';
    NSString *candidate = [NSString stringWithUTF8String:buf];
    NSString *mdPath = MDURL(dir, [candidate stringByAppendingString:@".md"]).path;
    NSString *htmlPath = MDURL(dir, [candidate stringByAppendingString:@".html"]).path;
    if (![fm fileExistsAtPath:mdPath] && ![fm fileExistsAtPath:htmlPath]) {
      return candidate;
    }
  }
  return [NSUUID.UUID.UUIDString.lowercaseString substringToIndex:12];
}

#pragma mark - Frontmatter Serialization & Parsing

+ (NSDictionary *)parseFrontmatterAndBody:(NSString *)markdown {
  if (![markdown isKindOfClass:NSString.class]) return @{@"markdown": @""};
  NSString *trimmed = [markdown stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (![trimmed hasPrefix:@"---"]) return @{@"markdown": markdown ?: @""};

  NSString *normalized = [[markdown stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
  NSArray<NSString *> *lines = [normalized componentsSeparatedByString:@"\n"];
  if (!lines.count || ![lines[0] isEqualToString:@"---"]) {
    return @{@"markdown": markdown};
  }

  NSInteger end = -1;
  for (NSInteger i = 1; i < (NSInteger)lines.count; i++) {
    if ([lines[i] isEqualToString:@"---"]) {
      end = i;
      break;
    }
  }
  if (end == -1) return @{@"markdown": markdown};

  NSMutableDictionary *dict = [NSMutableDictionary dictionary];
  for (NSInteger i = 1; i < end; i++) {
    NSString *line = lines[i];
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) continue;
    NSString *key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *valStr = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!key.length) continue;

    if ([valStr hasPrefix:@"\""] && [valStr hasSuffix:@"\""] && valStr.length >= 2) {
      NSData *json = [[@"[" stringByAppendingFormat:@"%@]", valStr] dataUsingEncoding:NSUTF8StringEncoding];
      NSArray *decoded = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
      NSString *unquoted = [decoded isKindOfClass:NSArray.class] && decoded.count && [decoded[0] isKindOfClass:NSString.class] ? decoded[0] : [valStr substringWithRange:NSMakeRange(1, valStr.length - 2)];
      dict[key] = unquoted;
    } else if ([valStr isEqualToString:@"true"] || [valStr isEqualToString:@"false"]) {
      dict[key] = @([valStr isEqualToString:@"true"]);
    } else if (valStr.length >= 2 && [valStr hasPrefix:@"["] && [valStr hasSuffix:@"]"]) {
      NSString *inner = [valStr substringWithRange:NSMakeRange(1, valStr.length - 2)];
      NSMutableArray *tags = [NSMutableArray array];
      for (NSString *t in [inner componentsSeparatedByString:@","]) {
        NSString *cleaned = [t stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \"'"]];
        if (cleaned.length) [tags addObject:cleaned];
      }
      dict[key] = tags;
    } else {
      dict[key] = valStr;
    }
  }
  // Hand-written frontmatter such as `title: true` or `summary: [a, b]` must not
  // leak NSNumber/NSArray into text fields (search predicates and -length crash).
  for (NSString *key in @[@"id", @"slug", @"title", @"summary", @"manualSummary", @"bodyFormat",
                          @"createdAt", @"publishedAt", @"updatedAt"]) {
    id value = dict[key];
    if ([value isKindOfClass:NSArray.class]) dict[key] = [value componentsJoinedByString:@", "];
    else if ([value isKindOfClass:NSNumber.class]) dict[key] = [value boolValue] ? @"true" : @"false";
  }

  // Preserve existing NSString/NSNumber boolValue/integerValue semantics,
  // including quoted scalars. Containers are not valid flags or versions:
  // fail closed in memory instead of sending numeric selectors to NSArray.
  for (NSString *key in @[@"publish", @"pinned", @"singleSourceVersion"]) {
    id value = dict[key];
    if (value && ![value isKindOfClass:NSString.class] && ![value isKindOfClass:NSNumber.class]) dict[key] = @0;
  }

  NSArray *bodyLines = [lines subarrayWithRange:NSMakeRange(end + 1, lines.count - (end + 1))];
  NSString *body = [bodyLines componentsJoinedByString:@"\n"];
  if ([dict[@"bodyFormat"] isEqual:@"html"]) {
    // Preserve exact embedded HTML bytes (including leading blank lines and CRLF).
    // Recompute the separator in the original string, not the normalized parser.
    NSUInteger cursor = 0;
    for (NSInteger i = 0; i <= end && cursor < markdown.length; i++) {
      NSRange newline = [markdown rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet options:0 range:NSMakeRange(cursor, markdown.length - cursor)];
      if (newline.location == NSNotFound) { cursor = markdown.length; break; }
      cursor = NSMaxRange(newline);
      if ([markdown characterAtIndex:newline.location] == '\r' && cursor < markdown.length && [markdown characterAtIndex:cursor] == '\n') cursor++;
    }
    body = [markdown substringFromIndex:cursor];
  } else while ([body hasPrefix:@"\n"]) body = [body substringFromIndex:1];
  dict[@"markdown"] = body ?: @"";
  return dict;
}

+ (NSString *)serializeFrontmatter:(NSDictionary *)meta body:(NSString *)body {
  NSMutableString *out = [NSMutableString stringWithString:@"---\n"];
  NSString *idVal = meta[@"id"] ?: @"";
  [out appendFormat:@"id: \"%@\"\n", MDQuote(idVal)];
  [out appendFormat:@"slug: \"%@\"\n", MDQuote(meta[@"slug"] ?: idVal)];

  [out appendFormat:@"title: \"%@\"\n", MDQuote(meta[@"title"])];

  BOOL pub = [meta[@"publish"] boolValue];
  [out appendFormat:@"publish: %@\n", pub ? @"true" : @"false"];

  if ([meta[@"createdAt"] length]) [out appendFormat:@"createdAt: \"%@\"\n", MDQuote(meta[@"createdAt"])];
  if ([meta[@"publishedAt"] length]) [out appendFormat:@"publishedAt: \"%@\"\n", MDQuote(meta[@"publishedAt"])];
  if ([meta[@"updatedAt"] length]) [out appendFormat:@"updatedAt: \"%@\"\n", MDQuote(meta[@"updatedAt"])];

  if ([meta[@"summary"] length]) [out appendFormat:@"summary: \"%@\"\n", MDQuote(meta[@"summary"])];
  if ([meta[@"manualSummary"] length]) [out appendFormat:@"manualSummary: \"%@\"\n", MDQuote(meta[@"manualSummary"])];
  if ([meta[@"tags"] isKindOfClass:NSArray.class] && [meta[@"tags"] count]) {
    NSMutableArray *escapedTags = [NSMutableArray array];
    for (NSString *t in meta[@"tags"]) {
      NSString *cleaned = MDQuote(t);
      [escapedTags addObject:[NSString stringWithFormat:@"\"%@\"", cleaned]];
    }
    [out appendFormat:@"tags: [%@]\n", [escapedTags componentsJoinedByString:@", "]];
  }
  if ([meta[@"pinned"] boolValue]) [out appendString:@"pinned: true\n"];
  // Explicit format, never infer HTML from tags in user-authored Markdown.
  for (NSString *key in @[@"bodyFormat", @"bodySource", @"singleSourceVersion"]) {
    id value = meta[key];
    if ([value isKindOfClass:NSString.class] && [value length]) [out appendFormat:@"%@: \"%@\"\n", key, MDQuote(value)];
    else if ([value isKindOfClass:NSNumber.class]) [out appendFormat:@"%@: %@\n", key, value];
  }
  // Preserve extension metadata across native save/publish rather than erasing it.
  NSSet *known = [NSSet setWithArray:@[@"id", @"slug", @"title", @"publish", @"createdAt", @"updatedAt", @"publishedAt", @"summary", @"manualSummary", @"tags", @"pinned", @"bodyFormat", @"bodySource", @"singleSourceVersion", @"markdown"]];
  for (NSString *key in [[meta allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    if ([known containsObject:key] || ![key isKindOfClass:NSString.class] || !key.length || [key rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet]].location != NSNotFound) continue;
    id value = meta[key];
    if ([value isKindOfClass:NSString.class]) [out appendFormat:@"%@: \"%@\"\n", key, MDQuote(value)];
    else if ([value isKindOfClass:NSNumber.class]) [out appendFormat:@"%@: %@\n", key, value];
  }

  BOOL embeddedHTML = [meta[@"bodyFormat"] isEqual:@"html"];
  [out appendString:embeddedHTML ? @"---\n" : @"---\n\n"];
  [out appendString:body ?: @""];
  if (!embeddedHTML && ![out hasSuffix:@"\n"]) [out appendString:@"\n"];
  return out;
}


#pragma mark - Store Operations

- (NSURL *)articleDirectoryURLForNote:(NSString *)noteId {
  if (!MDID(noteId)) return nil;
  return MDURL(self.articlesFolderURL, [noteId stringByAppendingString:@".md"]).URLByDeletingLastPathComponent;
}
- (NSURL *)resourceURLForLocalPath:(NSString *)path {
  NSString *local = MDDecodedLocalPath(path); if (!local) return nil;
  NSURL *url = MDURL(self.articlesFolderURL, local); if (!url) return nil;
  NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
  if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || [attrs[NSFileSize] unsignedLongLongValue] > 256ULL * 1024 * 1024) return nil;
  return url;
}
- (NSURL *)readOnlyAssetURLForNote:(NSString *)noteId filename:(NSString *)filename {
  if (!MDID(noteId) || ![filename isKindOfClass:NSString.class]) return nil;
  return [self resourceURLForLocalPath:[NSString stringWithFormat:@"assets/%@/%@", noteId, filename]];
}
- (BOOL)migrateToArticleFoldersWithError:(NSError **)error {
  if (self.articleTask) { if (error) *error = MDError(409, @"文章操作中，暂不能迁移"); return NO; }
  if (!MDArchiveAll(self.articlesFolderURL, error)) return NO;
  [NSNotificationCenter.defaultCenter postNotificationName:LBMdStoreDidChange object:self];
  return YES;
}
- (NSArray<NSDictionary *> *)listArticles {
  NSURL *dir = self.articlesFolderURL;
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *note in MDArticleIDs(dir)) {
    NSURL *url = MDURL(dir, [note stringByAppendingString:@".md"]);
    if (!url) continue;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    if (![attrs[NSFileType] isEqual:NSFileTypeRegular]) continue;
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (!text) continue;
    NSDictionary *parsed = [LBMdStore parseFrontmatterAndBody:text];
    if (parsed[@"id"] && ![parsed[@"id"] isEqual:note]) continue;
    NSMutableDictionary *post = [NSMutableDictionary dictionaryWithDictionary:MDDates(parsed, url)];
    post[@"id"] = note; post[@"slug"] = parsed[@"slug"] ?: note;
    post[@"title"] = parsed[@"title"] ?: @"未命名文章";
    post[@"bodyFormat"] = parsed[@"bodyFormat"] ?: @"markdown";
    post[@"singleSourceVersion"] = parsed[@"singleSourceVersion"] ?: @"";
    post[@"summary"] = parsed[@"summary"] ?: parsed[@"manualSummary"] ?: @"";
    post[@"manualSummary"] = parsed[@"manualSummary"] ?: post[@"summary"];
    post[@"publish"] = @([parsed[@"publish"] boolValue]);
    post[@"tags"] = [parsed[@"tags"] isKindOfClass:NSArray.class] ? parsed[@"tags"] : @[];
    post[@"pinned"] = @([parsed[@"pinned"] boolValue]); post[@"filePath"] = url.path;
    NSURL *html = MDURL(dir, [note stringByAppendingString:@".html"]);
    BOOL has = html && [[NSFileManager.defaultManager attributesOfItemAtPath:html.path error:nil][NSFileType] isEqual:NSFileTypeRegular];
    post[@"hasSidecarHtml"] = @(has); post[@"hasHTMLSidecar"] = @(has); post[@"htmlPath"] = has ? html.path : @"";
    BOOL hasImg = [text containsString:@"<img"] || [text containsString:@"!["];
    post[@"hasImage"] = @(hasImg);
    [items addObject:post];
  }
  [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return (NSComparisonResult)MDArticleOrder([a[@"publishedAt"] longLongValue], [a[@"createdAt"] longLongValue], [a[@"id"] UTF8String], [b[@"publishedAt"] longLongValue], [b[@"createdAt"] longLongValue], [b[@"id"] UTF8String]);
  }];
  return items;
}
- (NSDictionary *)loadArticle:(NSString *)noteId {
  if (!MDID(noteId)) return nil;
  NSURL *dir = self.articlesFolderURL, *url = MDURL(dir, [noteId stringByAppendingString:@".md"]);
  if (!url || ![[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil][NSFileType] isEqual:NSFileTypeRegular]) return nil;
  NSString *raw = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil]; if (!raw) return nil;
  NSDictionary *parsed = [LBMdStore parseFrontmatterAndBody:raw];
  if (parsed[@"id"] && ![parsed[@"id"] isEqual:noteId]) return nil;
  NSMutableDictionary *post = [parsed mutableCopy];
  [post addEntriesFromDictionary:MDDates(parsed, url)];
  post[@"id"] = noteId; post[@"slug"] = parsed[@"slug"] ?: noteId;
  post[@"title"] = parsed[@"title"] ?: @"未命名文章"; post[@"filePath"] = url.path;
  post[@"bodyFormat"] = parsed[@"bodyFormat"] ?: @"markdown";
  post[@"markdown"] = MDCanonicalReferences(parsed[@"markdown"] ?: @"");
  BOOL embeddedHTML = [post[@"bodyFormat"] isEqual:@"html"];
  NSURL *htmlURL = MDURL(dir, [noteId stringByAppendingString:@".html"]);
  NSString *html = nil;
  if (htmlURL && [[NSFileManager.defaultManager attributesOfItemAtPath:htmlURL.path error:nil][NSFileType] isEqual:NSFileTypeRegular]) html = [NSString stringWithContentsOfURL:htmlURL encoding:NSUTF8StringEncoding error:nil];
  post[@"hasHTMLSidecar"] = @(html.length > 0); post[@"hasSidecarHtml"] = post[@"hasHTMLSidecar"];
  post[@"htmlPath"] = html.length ? htmlURL.path : @"";
  // Conversion is lazy in the reader (marked); never convert every list/load on main.
  // A real sidecar is the authoritative fidelity representation, not Markdown fallback.
  if (embeddedHTML) {
    post[@"html"] = post[@"markdown"];
    post[@"hasHTMLSidecar"] = @NO; post[@"hasSidecarHtml"] = @NO; post[@"htmlPath"] = @"";
  } else if (html.length) post[@"html"] = MDCanonicalReferences(html);
  post[@"isLocalDraft"] = @(![parsed[@"publish"] boolValue]);
  return post;
}

- (BOOL)saveArticleWithId:(NSString *)noteId
                    title:(NSString *)title
                 markdown:(NSString *)markdown
                  summary:(NSString *)summary
                  publish:(BOOL)publish
                     tags:(NSArray<NSString *> *)tags
                    error:(NSError **)outError {
  if (self.revertInstalling) { if (outError) *outError = MDError(409, @"正在安装本地撤销，暂不能保存文章"); return NO; }
  if (!MDID(noteId)) {
    if (outError) *outError = [NSError errorWithDomain:@"LBMdStore" code:400 userInfo:@{NSLocalizedDescriptionKey:@"文章 ID 不能为空"}];
    return NO;
  }

  NSURL *dir = self.articlesFolderURL;
  if (!MDURL(dir, [noteId stringByAppendingString:@".md"]) || !MDURL(dir, [noteId stringByAppendingString:@".html"])) {
    if (outError) *outError = MDError(400, @"文章或侧件本地路径不安全"); return NO;
  }
  NSURL *oldURL = MDURL(dir, [noteId stringByAppendingString:@".md"]);
  NSData *oldData = MDRead(dir, [noteId stringByAppendingString:@".md"]);
  if ([NSFileManager.defaultManager fileExistsAtPath:oldURL.path] && (!oldData || ![[NSFileManager.defaultManager attributesOfItemAtPath:oldURL.path error:nil][NSFileType] isEqual:NSFileTypeRegular])) { if (outError) *outError = MDError(400, @"原文章不是可读取普通文件，拒绝覆盖"); return NO; }
  NSString *oldText = oldData ? [[NSString alloc] initWithData:oldData encoding:NSUTF8StringEncoding] : nil;
  NSDictionary *oldFm = [LBMdStore parseFrontmatterAndBody:oldText ?: @""];
  if (oldData && !oldText) { if (outError) *outError = MDError(400, @"原文无法读取，拒绝覆盖"); return NO; }
  NSMutableDictionary *meta = [oldFm mutableCopy];
  meta[@"id"] = noteId; meta[@"slug"] = oldFm[@"slug"] ?: noteId;
  meta[@"title"] = title.length ? title : @"未命名文章";
  (void)publish; // Only successful remote operations change publish state.
  meta[@"publish"] = @([oldFm[@"publish"] boolValue]);
  meta[@"summary"] = summary ?: @""; meta[@"manualSummary"] = summary ?: @"";
  if (tags) meta[@"tags"] = tags;
  NSString *nowStr = currentDateString();
  if (oldData) MDApplyDateStrings(meta, MDDates(oldFm, MDURL(dir, [noteId stringByAppendingString:@".md"])));
  else meta[@"createdAt"] = nowStr;
  meta[@"updatedAt"] = nowStr;
  NSFileManager *fm = NSFileManager.defaultManager;
  // Copy existing bytes to the target title/category before modifying the article.
  // On failure no old file is removed and save does not proceed.
  if (!MDArchive(dir, noteId, meta, outError)) return NO;

  NSString *serialized = [LBMdStore serializeFrontmatter:meta body:markdown ?: @""];
  NSError *writeErr = nil;
  BOOL ok = MDWrite(dir, [noteId stringByAppendingString:@".md"], [serialized dataUsingEncoding:NSUTF8StringEncoding], &writeErr);
  if (!ok) {
    if (outError) *outError = writeErr;
    return NO;
  }

  // Markdown edits invalidate the old fidelity sidecar locally. The remote
  // counterpart is removed in the same atomic tree during the next publish.
  NSURL *sidecar = MDURL(dir, [noteId stringByAppendingString:@".html"]);
  BOOL bodyChanged = !oldData || ![MDBodyDigest(oldData) isEqual:MDBodyDigest([serialized dataUsingEncoding:NSUTF8StringEncoding])];
  if (!sidecar || (bodyChanged && [fm fileExistsAtPath:sidecar.path] && ![fm removeItemAtURL:sidecar error:&writeErr])) {
    if (outError) *outError = writeErr ?: MDError(400, @"Markdown 已保存，但旧 HTML 侧件路径不安全；请处理后重试");
    return NO;
  }
  [NSNotificationCenter.defaultCenter postNotificationName:LBMdStoreDidChange object:self];
  return YES;
}

- (BOOL)deleteArticleWithId:(NSString *)noteId error:(NSError **)outError {
  if (self.revertInstalling) { if (outError) *outError = MDError(409, @"正在安装本地撤销，暂不能修改文章或目录"); return NO; }
  if (!MDID(noteId)) return NO;
  NSURL *dir = self.articlesFolderURL;
  NSString *mdPath = MDURL(dir, [noteId stringByAppendingString:@".md"]).path;
  NSString *htmlPath = MDURL(dir, [noteId stringByAppendingString:@".html"]).path;

  if (!MDURL(dir, [noteId stringByAppendingString:@".md"]) || !MDURL(dir, [noteId stringByAppendingString:@".html"])) { if (outError) *outError = MDError(400, @"本地删除路径不安全"); return NO; }
  NSFileManager *fm = NSFileManager.defaultManager;
  NSError *err = nil;
  if ([fm fileExistsAtPath:mdPath]) {
    [fm removeItemAtPath:mdPath error:&err];
  }
  if ([fm fileExistsAtPath:htmlPath]) {
    [fm removeItemAtPath:htmlPath error:nil];
  }

  if (err && outError) *outError = err;
  [NSNotificationCenter.defaultCenter postNotificationName:LBMdStoreDidChange object:self];
  return err == nil;
}

- (NSString *)currentHeadCommit {
  NSError *e = nil;
  NSDictionary *state = MDLoadState(self.articlesFolderURL, LBStore.repo, &e);
  return state[@"head"];
}

- (BOOL)stageUnpublishArticle:(NSString *)noteId error:(NSError **)outError {
  if (self.revertInstalling) { if (outError) *outError = MDError(409, @"正在安装本地撤销，暂不能修改文章或目录"); return NO; }
  if (!MDID(noteId)) return NO;
  NSURL *dir = self.articlesFolderURL;
  NSData *data = MDRead(dir, [noteId stringByAppendingString:@".md"]);
  if (!data) return NO;
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!text) { if (outError) *outError = MDError(400, @"原文不是 UTF-8，拒绝暂存覆盖"); return NO; }
  NSDictionary *parsed = [LBMdStore parseFrontmatterAndBody:text ?: @""];
  NSMutableDictionary *meta = [parsed mutableCopy];
  meta[@"id"] = noteId;
  meta[@"publish"] = @NO;
  meta[@"updatedAt"] = currentDateString();
  if (!MDArchive(dir, noteId, meta, outError)) return NO;
  NSString *body = parsed[@"markdown"] ?: @"";
  NSString *serialized = [LBMdStore serializeFrontmatter:meta body:body];
  BOOL ok = MDWrite(dir, [noteId stringByAppendingString:@".md"], [serialized dataUsingEncoding:NSUTF8StringEncoding], outError);
  if (ok) [NSNotificationCenter.defaultCenter postNotificationName:LBMdStoreDidChange object:self];
  return ok;
}

- (BOOL)stagePublishArticle:(NSString *)noteId error:(NSError **)outError {
  if (self.revertInstalling) { if (outError) *outError = MDError(409, @"正在安装本地撤销，暂不能修改文章或目录"); return NO; }
  if (!MDID(noteId)) return NO;
  NSURL *dir = self.articlesFolderURL;
  NSData *data = MDRead(dir, [noteId stringByAppendingString:@".md"]);
  if (!data) return NO;
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!text) { if (outError) *outError = MDError(400, @"原文不是 UTF-8，拒绝暂存覆盖"); return NO; }
  NSDictionary *parsed = [LBMdStore parseFrontmatterAndBody:text ?: @""];
  NSMutableDictionary *meta = [parsed mutableCopy];
  meta[@"id"] = noteId;
  meta[@"publish"] = @YES;
  meta[@"updatedAt"] = currentDateString();
  if (![meta[@"publishedAt"] length]) meta[@"publishedAt"] = currentDateString();
  if (!MDArchive(dir, noteId, meta, outError)) return NO;
  NSString *body = parsed[@"markdown"] ?: @"";
  NSString *serialized = [LBMdStore serializeFrontmatter:meta body:body];
  BOOL ok = MDWrite(dir, [noteId stringByAppendingString:@".md"], [serialized dataUsingEncoding:NSUTF8StringEncoding], outError);
  if (ok) [NSNotificationCenter.defaultCenter postNotificationName:LBMdStoreDidChange object:self];
  return ok;
}

- (NSArray<NSDictionary *> *)stagedArticles {
  return [self stagedArticlesForArticles:[self listArticles]];
}

- (NSArray<NSDictionary *> *)stagedArticlesForArticles:(NSArray<NSDictionary *> *)all {
  NSError *e = nil;
  NSDictionary *state = MDLoadState(self.articlesFolderURL, LBStore.repo, &e);
  NSDictionary *files = [state[@"files"] isKindOfClass:NSDictionary.class] ? state[@"files"] : @{};
  NSMutableArray *staged = [NSMutableArray array];
  // Baseline alignments are collected and saved once. Saving inside the loop
  // rebuilt state from the original records each time, so with two or more
  // aligned articles only the last survived and the file was rewritten on
  // every list refresh.
  NSMutableDictionary *alignedFiles = nil;
  
  for (NSDictionary *p in all) {
    NSString *noteId = p[@"id"];
    if (!MDID(noteId)) continue;
    BOOL localPub = [p[@"publish"] boolValue];
    NSString *localMD = [noteId stringByAppendingString:@".md"];
    NSDictionary *rec = files[localMD];
    NSData *localData = MDRead(self.articlesFolderURL, localMD);
    NSString *localHash = MDDigest(localData);

    if (rec) {
      if (!localPub) {
        [staged addObject:@{
          @"id": noteId,
          @"title": p[@"title"] ?: noteId,
          @"action": @"unpublish",
          @"actionTitle": @"下架",
          @"summary": p[@"summary"] ?: @"",
          @"p": p
        }];
      } else {
        // Legacy records lack a semantic baseline: treat any changed bytes as
        // staged rather than guessing that all non-body changes are timestamps.
        BOOL contentChanged = rec[@"contentBaseline"] ? ![MDContentDigest(localData) isEqualToString:rec[@"contentBaseline"]]
                                                      : ![localHash isEqualToString:rec[@"baseline"]];
        if (contentChanged) {
          [staged addObject:@{
            @"id": noteId,
            @"title": p[@"title"] ?: noteId,
            @"action": @"update",
            @"actionTitle": @"更新",
            @"summary": p[@"summary"] ?: @"",
            @"p": p
          }];
        } else if (![localHash isEqualToString:rec[@"baseline"]]) {
          // Body identical; align timestamp baseline silently
          NSMutableDictionary *mutRec = [rec mutableCopy];
          mutRec[@"baseline"] = localHash;
          if (!alignedFiles) alignedFiles = [files mutableCopy];
          alignedFiles[localMD] = mutRec;
        }
      }
    } else {
      if (localPub) {
        [staged addObject:@{
          @"id": noteId,
          @"title": p[@"title"] ?: noteId,
          @"action": @"publish",
          @"actionTitle": @"发布",
          @"summary": p[@"summary"] ?: @"",
          @"p": p
        }];
      }
    }
  }
  if (alignedFiles && state && !state[@"pending"]) {
    NSURL *root = self.articlesFolderURL; NSString *repo = [LBStore.repo copy];
    void (^align)(void) = ^{
      if (self.articleTask || ![root isEqual:self.articlesFolderURL] || ![repo isEqual:LBStore.repo]) return;
      NSDictionary *latest = MDLoadState(root, repo, nil);
      if (!latest || latest[@"pending"]) return;
      NSMutableDictionary *latestFiles = [latest[@"files"] mutableCopy];
      for (NSString *local in alignedFiles) {
        if ([latestFiles[local] isEqual:files[local]]) latestFiles[local] = alignedFiles[local];
      }
      NSMutableDictionary *mutState = [latest mutableCopy]; mutState[@"files"] = latestFiles;
      MDSaveState(root, mutState, nil);
    };
    if (NSThread.isMainThread) align(); else dispatch_sync(dispatch_get_main_queue(), align);
  }
  // Mint tokens AFTER any timestamp-only state alignment. Each token is tied to
  // actual bytes, layout and complete confirmed state, not stale list metadata.
  NSDictionary *revertState = MDLoadState(self.articlesFolderURL, LBStore.repo, nil);
  for (NSUInteger i = 0; i < staged.count; i++) {
    NSMutableDictionary *item = [staged[i] mutableCopy];
    NSDictionary *guard = MDRevertGuard(self.articlesFolderURL, LBStore.repo, revertState, item[@"id"]);
    if (guard) item[@"revertGuard"] = guard;
    staged[i] = item;
  }
  return staged;
}

- (void)revertStagedArticles:(NSArray<NSDictionary *> *)staged done:(void (^)(NSError *))done {
  // JSON round-trip deep-freezes the confirmation tokens as well as the selection.
  NSError *error = nil;
  NSData *data = [NSJSONSerialization isValidJSONObject:staged] ? [NSJSONSerialization dataWithJSONObject:staged options:0 error:&error] : nil;
  NSArray *frozen = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
  if (!frozen || !MDBatchItemsValid(frozen)) {
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(MDError(400, @"撤销选择无效，请重新打开确认框")); }); return;
  }
  [self beginArticleOperation:@"revert" note:nil batch:frozen message:nil done:done];
}

- (void)commitStagedArticles:(NSArray<NSDictionary *> *)staged
                     message:(NSString *)message
                        done:(void (^)(NSError * _Nullable error))done {
  // Freeze the selection, not mutable editor/list dictionaries. The task reads
  // and validates the actual source bytes after acquiring the article mutex.
  NSMutableArray *selection = [NSMutableArray array];
  for (id item in staged) {
    if (![item isKindOfClass:NSDictionary.class]) { [selection addObject:NSNull.null]; continue; }
    id note = item[@"id"], action = item[@"action"];
    [selection addObject:@{@"id":[note isKindOfClass:NSString.class] ? [note copy] : NSNull.null,
                          @"action":[action isKindOfClass:NSString.class] ? [action copy] : NSNull.null}];
  }
  [self beginArticleOperation:@"batch" note:nil batch:[selection copy] message:[message copy] done:done];
}

@end

@implementation LBArticleTask
- (BOOL)current {
  return [self.github.repository.lowercaseString isEqual:LBStore.repo.lowercaseString] && [self.root isEqual:self.store.articlesFolderURL];
}
- (void)finish:(NSError *)error {
  if (NSThread.isMainThread) {
    self.store.revertInstalling = NO;
    void (^callback)(NSError *) = self.done; self.done = nil; if (callback) callback(error);
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      self.store.revertInstalling = NO;
      void (^callback)(NSError *) = self.done; self.done = nil; if (callback) callback(error);
    });
  }
}
- (void)start {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *e = nil;
    self.state = [MDLoadState(self.root, self.github.repository, &e) mutableCopy];
    if (!self.state) return [self finish:e];
    self.records = [self.state[@"files"] mutableCopy];
    self.staged = [NSMutableDictionary dictionary]; self.before = [NSMutableDictionary dictionary];
    self.protectedGroups = [NSMutableSet set];
    if ([self.operation isEqual:@"revert"] && (self.state[@"pending"] || self.state[@"singleSourcePendingReview"])) return [self finish:MDError(409, @"存在待确认发布记录；撤销不会恢复、重发或清除 pending，请先人工核对")];
    if ([self.operation isEqual:@"revert"] && !self.batchItems.count) return [self finish:nil];
    if (self.state[@"pending"]) {
      if (![self.state[@"pending"] isKindOfClass:NSDictionary.class]) return [self finish:MDError(400, @"待确认发布记录损坏")];
      return [self resumePending:self.state[@"pending"]];
    }
    if ([self.operation isEqual:@"batch"] && !self.batchItems.count) return [self finish:nil];
    [self.github articleSnapshot:^(NSDictionary *snapshot, NSError *error) {
      if (error) return [self finish:error];
      if (![self current]) return [self finish:MDError(409, @"仓库或目录已改变，请重新同步")];
      self.snapshot = snapshot;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if ([self.operation isEqual:@"sync"] || [self.operation isEqual:@"forceSync"]) [self prepareSync];
        else if ([self.operation isEqual:@"revert"]) [self prepareRevert];
        else if ([self.operation isEqual:@"batch"]) [self prepareBatch];
        else [self preparePublish];
      });
    }];
  });
}
- (BOOL)revertSelectionCurrent:(NSError **)error {
  if (![self current]) { if (error) *error = MDError(409, @"仓库或目录已改变，未撤销文章"); return NO; }
  NSDictionary *latest = MDLoadState(self.root, self.github.repository, error);
  if (!latest || !MDRevertJournalClear(self.root, error)) return NO;
  for (NSDictionary *item in self.batchItems) {
    NSDictionary *guard = MDRevertGuard(self.root, self.github.repository, latest, item[@"id"]);
    if (!guard || ![item[@"revertGuard"] isKindOfClass:NSDictionary.class] || ![guard isEqual:item[@"revertGuard"]]) {
      if (error) *error = MDError(409, @"确认后文章、附件或同步基线已改变；已保留新内容，请重新核对撤销选择"); return NO;
    }
  }
  return YES;
}
- (void)prepareRevert {
  NSError *error = nil;
  if (!MDBatchItemsValid(self.batchItems) || ![self revertSelectionCurrent:&error]) return [self finish:error ?: MDError(400, @"撤销选择无效")];
  NSMutableSet *download = [NSMutableSet set];
  for (NSDictionary *item in self.batchItems) {
    NSString *note = item[@"id"], *md = [note stringByAppendingString:@".md"], *html = [note stringByAppendingString:@".html"];
    NSData *source = MDRead(self.root, md);
    NSString *text = source ? [[NSString alloc] initWithData:source encoding:NSUTF8StringEncoding] : nil;
    NSDictionary *meta = text ? [LBMdStore parseFrontmatterAndBody:text] : nil;
    NSDictionary *record = self.records[md];
    NSString *action = record ? ([meta[@"publish"] boolValue] ? @"update" : @"unpublish") : @"publish";
    if (!text || (meta[@"id"] && ![meta[@"id"] isEqual:note]) || ![item[@"action"] isEqual:action] || (!record && ![meta[@"publish"] boolValue])) return [self finish:MDError(409, @"文章暂存状态已改变，未撤销")];
    // No ownership record means no permission to remove/replace remote or local data.
    for (NSString *local in @[md, html]) {
      NSString *remote = [@"content/posts/" stringByAppendingString:local];
      if (!self.records[local] && self.snapshot[@"files"][remote]) return [self finish:MDError(409, @"远端存在未认领文章，不能推测撤销基线；请先核对同步")];
    }
    if (!record) {
      NSData *draft = MDRevertDraftData(source);
      if (!draft) return [self finish:MDError(409, @"草稿发布字段不是可无损撤销的标准格式，原文及附件已保留")];
      // Only the publish scalar changes; comments, metadata and body are exact.
      self.staged[md] = draft;
    }
    for (NSString *local in self.records) {
      if (![MDGroup(local) isEqual:note]) continue;
      if (![local hasPrefix:@"assets/"] && ![local isEqual:md] && ![local isEqual:html]) return [self finish:MDError(409, @"文章基线路径不受支持，未撤销")];
      NSDictionary *rec = self.records[local], *entry = self.snapshot[@"files"][rec[@"remote"]];
      if (![entry[@"sha"] isEqual:rec[@"sha"]] || ![@[@"100644", @"100755"] containsObject:entry[@"mode"]]) return [self finish:MDError(409, @"远端文章或附件已改变／删除；未用旧基线覆盖，请先核对同步")];
      for (NSString *remote in self.snapshot[@"files"]) {
        if ([MDLocalPath(remote) isEqual:local] && ![remote isEqual:rec[@"remote"]]) return [self finish:MDError(409, @"远端存在重名兼容路径，撤销基线不唯一")];
      }
      [download addObject:local];
    }
    NSDictionary *files = item[@"revertGuard"][@"files"];
    [self.before addEntriesFromDictionary:files];
  }
  self.paths = [download.allObjects sortedArrayUsingSelector:@selector(compare:)]; self.index = 0;
  [self downloadRevertNext];
}
- (void)downloadRevertNext {
  while (self.index < self.paths.count) {
    NSString *local = self.paths[self.index++]; NSDictionary *record = self.records[local];
    NSData *existing = MDRead(self.root, local);
    if ([MDGitBlobDigest(existing) isEqual:record[@"sha"]]) continue; // No staging, backup or rewrite of unchanged assets.
    // Baseline records normally hold hashes, not recoverable bytes. Fetch the
    // immutable confirmed blob; getBlobData verifies its Git object SHA using GET.
    [self.github getBlobData:record[@"sha"] done:^(NSData *data, NSError *error) {
      if (error || !data || ![MDGitBlobDigest(data) isEqual:record[@"sha"]]) return [self finish:error ?: MDError(409, @"远端基线内容校验失败，未撤销")];
      self.staged[local] = data; [self downloadRevertNext];
    }]; return;
  }
  for (NSDictionary *item in self.batchItems) {
    NSString *note = item[@"id"], *md = [note stringByAppendingString:@".md"];
    if (!self.records[md]) continue;
    NSString *text = [[NSString alloc] initWithData:self.staged[md] ?: MDRead(self.root, md) encoding:NSUTF8StringEncoding];
    NSDictionary *meta = text ? [LBMdStore parseFrontmatterAndBody:text] : nil;
    if (!text || ![meta[@"publish"] boolValue] || (meta[@"id"] && ![meta[@"id"] isEqual:note])) return [self finish:MDError(409, @"已确认的远端基线不是可恢复的已发布文章，未撤销")];
    if (MDSingleSource(self.root, note) && ([meta[@"singleSourceVersion"] integerValue] < 1 || self.staged[[note stringByAppendingString:@".html"]])) return [self finish:MDError(409, @"远端基线仍为旧侧件格式；未降级单源文章，请人工核对")];
  }
  // A second read-only snapshot refuses even unrelated remote movement while
  // baseline bytes were downloading. No ref is ever written by this operation.
  [self.github articleSnapshot:^(NSDictionary *snapshot, NSError *error) {
    if (error || ![snapshot[@"head"] isEqual:self.snapshot[@"head"]]) return [self finish:error ?: MDError(409, @"核验期间远端版本已改变，未撤销")];
    dispatch_async(dispatch_get_main_queue(), ^{ [self applyRevert]; });
  }];
}
- (void)applyRevert {
  NSError *error = nil;
  if (![self revertSelectionCurrent:&error]) return [self finish:error];
  NSMutableDictionary *records = [self.records mutableCopy], *backups = [NSMutableDictionary dictionary], *payloads = [NSMutableDictionary dictionary];
  for (NSString *local in self.staged) {
    NSData *old = MDRead(self.root, local), *data = self.staged[local];
    backups[local] = old ? [old base64EncodedStringWithOptions:0] : (id)NSNull.null;
    payloads[local] = [data base64EncodedStringWithOptions:0];
    NSDictionary *record = records[local];
    if (record) records[local] = MDRecord(record[@"remote"], record[@"sha"], local, data);
  }
  NSMutableDictionary *newState = [self.state mutableCopy]; newState[@"files"] = records;
  NSMutableDictionary *guards = [self.state[@"singleSource"] isKindOfClass:NSDictionary.class] ? [self.state[@"singleSource"] mutableCopy] : [NSMutableDictionary dictionary];
  for (NSDictionary *item in self.batchItems) {
    NSString *note = item[@"id"], *md = [note stringByAppendingString:@".md"];
    NSDictionary *record = records[md]; if (!record) continue;
    NSData *data = self.staged[md] ?: MDRead(self.root, md);
    // Also realign semantic records when current bytes already equal the Git
    // blob, without staging/re-writing that file (e.g. an old timestamp record).
    records[md] = MDRecord(record[@"remote"], record[@"sha"], md, data);
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSDictionary *meta = [LBMdStore parseFrontmatterAndBody:text ?: @""];
    if ([meta[@"singleSourceVersion"] integerValue] >= 1 || [meta[@"bodyFormat"] isEqual:@"html"]) guards[note] = @{@"version":@1, @"status":@"published", @"mdBaseline":MDDigest(data)};
  }
  if (guards.count) newState[@"singleSource"] = guards;
  // Deliberately leave head/pending/tombstones unchanged. No new cloud baseline
  // is invented; untracked files are neither deleted nor silently adopted.
  NSString *name = [NSString stringWithFormat:@".longblog-revert-%@.json", NSUUID.UUID.UUIDString];
  NSURL *journalURL = MDHiddenURL(self.root, name, &error);
  NSMutableDictionary *journal = [@{@"version":@1, @"phase":@"prepared", @"repository":self.github.repository.lowercaseString,
    @"root":MDSafePathStripPrivate(self.root.path), @"remoteHead":self.snapshot[@"head"], @"selection":self.batchItems,
    @"before":backups, @"after":payloads, @"stateBefore":self.state, @"stateAfter":newState} mutableCopy];
  NSData *journalData = [NSJSONSerialization dataWithJSONObject:journal options:NSJSONWritingSortedKeys error:&error];
  if (!journalURL || !journalData || ![journalData writeToURL:journalURL options:NSDataWritingAtomic error:&error]) return [self finish:error ?: MDError(500, @"无法建立撤销备份，原文未修改")];
  journal[@"layoutBefore"] = MDLayout(self.root) ?: @{};
  NSMutableDictionary *metas = [NSMutableDictionary dictionary];
  for (NSDictionary *item in self.batchItems) {
    NSString *note = item[@"id"], *md = [note stringByAppendingString:@".md"];
    NSString *text = [[NSString alloc] initWithData:self.staged[md] ?: MDRead(self.root, md) encoding:NSUTF8StringEncoding];
    metas[note] = [LBMdStore parseFrontmatterAndBody:text ?: @""];
  }
  journalData = [NSJSONSerialization dataWithJSONObject:journal options:NSJSONWritingSortedKeys error:&error];
  if (!journalData || ![journalData writeToURL:journalURL options:NSDataWritingAtomic error:&error]) return [self finish:error];
  self.store.revertInstalling = YES;
  // Existing verified package/manifest migration restores 草稿/已发布 and title
  // paths, retaining arbitrary author files. It skips unchanged paths. Package
  // copying on a real rename is necessarily proportional to assets, so never
  // run it on main. During this short install phase native mutators fail 409.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *archiveError = nil;
    if (![self current] || !MDArchiveMany(self.root, metas, &archiveError)) return [self finish:archiveError ?: MDError(409, @"仓库或目录已改变，保留撤销恢复日志")];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSError *installError = nil;
      // Archive changes only physical mapping, not bytes. Recheck the ENTIRE
      // frozen set before the first overwrite, including unchanged attachments.
      if (![self current] || ![MDLoadState(self.root, self.github.repository, &installError) isEqual:self.state]) return [self finish:installError ?: MDError(409, @"仓库、目录或同步状态已变化，保留撤销恢复日志")];
      for (NSString *local in self.before) {
        if (![MDDigest(MDRead(self.root, local)) isEqual:self.before[local]]) return [self finish:MDError(409, @"安装前文件发生变化；保留原文备份与恢复日志，未自动回放")];
      }
      for (NSString *local in [self.staged.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (![MDDigest(MDRead(self.root, local)) isEqual:self.before[local]]) return [self finish:MDError(409, @"写入前文件发生变化；已保留撤销恢复日志")];
        if (!MDWrite(self.root, local, self.staged[local], &installError)) return [self finish:installError];
      }
      if (!MDSaveState(self.root, newState, &installError)) return [self finish:installError];
      journal[@"phase"] = @"applied"; journal[@"layoutAfter"] = MDLayout(self.root) ?: @{};
      NSData *finished = [NSJSONSerialization dataWithJSONObject:journal options:NSJSONWritingSortedKeys error:&installError];
      if (!finished || ![finished writeToURL:journalURL options:NSDataWritingAtomic error:&installError]) return [self finish:installError];
      [self finish:nil];
    });
  });
}

- (void)resumePending:(NSDictionary *)pending {
  // Migration preserves exact pending payloads for audit. Replaying an old HTML
  // transaction could resurrect sidecars or delete a migrated source, even when
  // its before digest happens to match. Fail closed; never clear it implicitly.
  if (self.state[@"singleSourcePendingReview"] || (MDID(pending[@"note"]) && MDSingleSource(self.root, pending[@"note"]) && [pending[@"singleSourceVersion"] integerValue] < 1)) return [self finish:MDError(409, @"MD 单源迁移保留了旧发布记录；请先核对远端提交及备份，未回放、未清除 pending")];
  if (![self.github matchesPendingIdentity:pending]) return [self finish:MDError(-999, @"GitHub 账号或凭据已改变；保留上次发布记录，拒绝用新账号恢复")];
  NSString *commit = pending[@"commit"], *base = pending[@"base"];
  BOOL batch = [pending[@"operation"] isEqual:@"batch"];
  if (batch && !MDBatchItemsValid(pending[@"items"])) return [self finish:MDError(400, @"待确认批量选择损坏，未应用本地")];
  if (![commit isKindOfClass:NSString.class] || commit.length != 40 || ![base isKindOfClass:NSString.class] || base.length != 40 || ![pending[@"repository"] isEqual:self.github.repository.lowercaseString] || (!batch && !MDID(pending[@"note"])) || ![@[@"publish", @"unpublish", @"delete", @"batch"] containsObject:pending[@"operation"]] || ![pending[@"before"] isKindOfClass:NSDictionary.class] || ![pending[@"payloads"] isKindOfClass:NSDictionary.class] || ![pending[@"shas"] isKindOfClass:NSDictionary.class]) return [self finish:MDError(400, @"待确认发布记录损坏；未重发，请保留文件夹后人工核对")];
  [self.github confirmCommit:commit base:base done:^(NSDictionary *confirmation, NSError *error) {
    if (error) return [self finish:error];
    if (![self current]) return [self finish:MDError(409, @"目录或仓库已改变，保留待确认发布")];
    NSString *status = confirmation[@"state"];
    if (!MDRecoveryAction(status.UTF8String ?: "unknown")) {
      NSString *message = [status isEqual:@"unchanged"] ? @"上次发布尚未确认应用（远端仍为原版本）；已保留本地及待确认记录，未自动重发。请在 GitHub 核对后处理。" : @"上次发布与远端历史冲突；保留本地及待确认记录，请人工核对，未重发。";
      return [self finish:MDError(409, message)];
    }
    NSString *requestedOperation = self.operation, *requestedNote = self.note;
    self.operation = pending[@"operation"]; self.note = pending[@"note"];
    if (batch) self.batchItems = pending[@"items"];
    self.before = [pending[@"before"] mutableCopy]; self.changes = [NSMutableDictionary dictionary]; self.staged = [NSMutableDictionary dictionary];
    if (batch) {
      for (NSDictionary *item in self.batchItems) {
        for (NSString *ext in @[@"md", @"html"]) {
          if (![self.before[[item[@"id"] stringByAppendingPathExtension:ext]] isKindOfClass:NSString.class]) return [self finish:MDError(400, @"待确认批量基线不完整")];
        }
      }
      for (NSString *local in self.before) {
        if (!MDPath(local) || !MDGroup(local) || ![self.before[local] isKindOfClass:NSString.class]) return [self finish:MDError(400, @"待确认批量基线路径损坏")];
      }
    }
    for (NSString *remote in pending[@"payloads"]) {
      NSString *local = MDLocalPath(remote); id encoded = pending[@"payloads"][remote];
      if (!MDPath(local) || ![self.before[local] isKindOfClass:NSString.class]) return [self finish:MDError(400, @"待确认发布路径损坏，未应用本地")];
      if (batch) {
        BOOL allowed = [remote hasPrefix:@"public/assets/"] && MDID(MDGroup(local)) && encoded != NSNull.null;
        for (NSDictionary *item in self.batchItems) {
          BOOL articlePath = [remote isEqual:[NSString stringWithFormat:@"content/posts/%@.md", item[@"id"]]] || [remote isEqual:[NSString stringWithFormat:@"content/posts/%@.html", item[@"id"]]];
          if (articlePath && (![item[@"action"] isEqual:@"unpublish"] || encoded == NSNull.null)) allowed = YES;
        }
        if (!allowed) return [self finish:MDError(400, @"待确认批量内容超出选择范围")];
      }
      if (encoded == NSNull.null) self.changes[remote] = NSNull.null;
      else {
        NSData *data = [encoded isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:encoded options:0] : nil;
        if (!data || ![pending[@"shas"][remote] isKindOfClass:NSString.class] || [pending[@"shas"][remote] length] != 40) return [self finish:MDError(400, @"待确认发布内容损坏，未应用本地")];
        self.changes[remote] = data; self.staged[local] = data;
      }
    }
    // Recovery only applies the already-confirmed transaction. Never implicitly run
    // the user's newly requested operation (delete/publish could mean something else).
    BOOL differentRequest = batch || [requestedOperation isEqual:@"batch"] || ![requestedOperation isEqual:self.operation] || (requestedNote && ![requestedNote isEqual:self.note]);
    self.recoveredDifferentRequest = differentRequest;
    if (batch) dispatch_async(dispatch_get_main_queue(), ^{ [self applyBatch:@{@"commit":commit, @"shas":pending[@"shas"]}]; });
    else dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      [self applyPublish:@{@"commit":commit, @"shas":pending[@"shas"]}];
    });
  }];
}
- (void)prepareSync {
  NSMutableDictionary *map = [NSMutableDictionary dictionary], *folded = [NSMutableDictionary dictionary];
  NSDictionary *files = self.snapshot[@"files"];
  NSMutableSet *ids = [NSMutableSet set];
  for (NSString *remote in files) {
    if (![remote hasPrefix:@"content/posts/"] || ![remote.pathExtension isEqual:@"md"]) continue;
    NSString *local = MDLocalPath(remote), *note = local.stringByDeletingPathExtension;
    if (!MDID(note) || ![files[remote][@"mode"] isEqual:@"100644"]) return [self finish:MDError(400, @"文章路径或类型不安全")];
    [ids addObject:note]; map[local] = remote;
  }
  for (NSString *remote in [[files allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    NSString *local = MDLocalPath(remote); if (!local) continue;
    NSString *group = MDGroup(local);
    BOOL sidecar = [local.pathExtension isEqual:@"html"] && [local componentsSeparatedByString:@"/"].count == 1 && [ids containsObject:group];
    BOOL asset = [local hasPrefix:@"assets/"];
    if (!asset && !sidecar) continue;
    if (asset && (!MDID(group) || [local componentsSeparatedByString:@"/"].count < 3)) return [self finish:MDError(400, @"附件必须位于 assets/<id>/<file> 内")];
    if (!MDPath(local) || ![files[remote][@"mode"] isEqual:@"100644"] || !MDURL(self.root, local)) return [self finish:MDError(400, @"附件或侧件路径不安全")];
    // During migration prefer the canonical file only when bytes are identical;
    // differing aliases are a conflict, never an arbitrary last-write-wins.
    if (map[local] && ![files[map[local]][@"sha"] isEqual:files[remote][@"sha"]]) return [self finish:MDError(409, @"旧新附件路径映射重名且内容不同")];
    if (!map[local] || [remote hasPrefix:@"public/assets/"]) map[local] = remote;
  }
  for (NSString *local in map) {
    NSString *key = local.precomposedStringWithCanonicalMapping.lowercaseString;
    if (folded[key] && ![folded[key] isEqual:local]) return [self finish:MDError(409, @"远端存在大小写或 Unicode 同名文件")];
    folded[key] = local;
    if (!MDURL(self.root, local)) return [self finish:MDError(400, @"本地路径不安全")];
    NSData *existing = MDRead(self.root, local); self.before[local] = MDDigest(existing);
    NSDictionary *record = self.records[local];
    if (existing && (!record || ![MDDigest(existing) isEqual:record[@"baseline"]])) [self.protectedGroups addObject:MDGroup(local)];
    if (existing && ![local hasPrefix:@"assets/"] && [local.pathExtension isEqual:@"md"]) {
      NSString *text = [[NSString alloc] initWithData:existing encoding:NSUTF8StringEncoding];
      if (![[LBMdStore parseFrontmatterAndBody:text][@"publish"] boolValue]) [self.protectedGroups addObject:MDGroup(local)];
    }
  }
  for (NSString *note in ids) {
    NSString *html = [note stringByAppendingString:@".html"];
    if (MDRead(self.root, html) && !self.records[html]) [self.protectedGroups addObject:note];
  }
  // Protect the whole article if *any* previously tracked sidecar or asset changed,
  // including a local deletion, even when that remote path disappeared.
  for (NSString *local in self.records) {
    if (!MDPath(local) || !MDGroup(local)) return [self finish:MDError(400, @"同步状态包含不安全路径")];
    if (![MDDigest(MDRead(self.root, local)) isEqual:self.records[local][@"baseline"]]) [self.protectedGroups addObject:MDGroup(local)];
  }
  // APFS usually folds case. Do not overwrite untracked Foo.md as foo.md.
  NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:self.root includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
  for (NSURL *url in enumerator) {
    NSString *rootPath = self.root.path.stringByStandardizingPath;
    NSString *prefix = [rootPath isEqual:@"/"] ? @"/" : [rootPath stringByAppendingString:@"/"];
    if (![url.path hasPrefix:prefix]) continue;
    NSString *local = [url.path substringFromIndex:prefix.length];
    NSString *other = folded[local.precomposedStringWithCanonicalMapping.lowercaseString];
    if (other && ![other isEqual:local]) return [self finish:MDError(409, @"本地存在大小写或 Unicode 同名文件")];
  }
  self.mapping = map; self.paths = [[map allKeys] sortedArrayUsingSelector:@selector(compare:)];
  [self downloadNext];
}
- (BOOL)canDownloadLocal:(NSString *)local {
  if ([self.operation isEqual:@"forceSync"]) return YES;
  NSString *note = MDGroup(local);
  if (MDSingleSource(self.root, note) || self.state[@"singleSource"][note]) {
    // Only a verified single-source remote Markdown may replace a clean source.
    // Old repo HTML and lossy Markdown remain remote baselines, never local truth.
    NSData *remote = self.staged[local];
    NSString *text = remote && ![local hasPrefix:@"assets/"] ? [[NSString alloc] initWithData:remote encoding:NSUTF8StringEncoding] : nil;
    NSDictionary *meta = [LBMdStore parseFrontmatterAndBody:text ?: @""];
    NSDictionary *guard = self.state[@"singleSource"][note];
    if (!MDSingleSourceAllowsDownload(1, [local hasPrefix:@"assets/"], [local.pathExtension isEqual:@"html"], [guard[@"status"] isEqual:@"needs-publish"], remote != nil, [meta[@"singleSourceVersion"] intValue])) return NO;
  }
  if (![self.protectedGroups containsObject:MDGroup(local)]) return YES;
  // Upgrade from previously seeded/untracked Markdown: protect all existing bytes,
  // but still fill missing, never-tracked assets so offline images become usable.
  return [local hasPrefix:@"assets/"] && !self.records[local] && ![self.before[local] length] && !MDRead(self.root, local);
}
- (void)downloadNext {
  while (self.index < self.paths.count) {
    NSString *local = self.paths[self.index++];
    if (![self canDownloadLocal:local] && self.records[local]) continue;
    NSString *remote = self.mapping[local]; NSDictionary *entry = self.snapshot[@"files"][remote];
    NSURL *localURL = MDURL(self.root, local);
    BOOL exists = localURL && [NSFileManager.defaultManager fileExistsAtPath:localURL.path];
    if (![self.operation isEqual:@"forceSync"] && [self.records[local][@"sha"] isEqual:entry[@"sha"]] && [self.records[local][@"remote"] isEqual:remote] && exists) continue;
    [self.github getBlobData:entry[@"sha"] done:^(NSData *data, NSError *e) {
      if (e) return [self finish:e];
      if (![local hasPrefix:@"assets/"]) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) return [self finish:MDError(400, @"文章或侧件不是 UTF-8")];
        if ([local.pathExtension isEqual:@"md"]) {
          id note = [LBMdStore parseFrontmatterAndBody:text][@"id"];
          if (note && (![note isKindOfClass:NSString.class] || ![note isEqual:local.stringByDeletingPathExtension])) return [self finish:MDError(409, @"文章 ID 与文件名不一致")];
        }
        // Preserve bytes exactly on disk, including legacy references. Canonicalize only
        // at render/publish boundaries so the downloaded .html remains lossless.
      }
      self.staged[local] = data;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self downloadNext];
      });
    }];
    return;
  }
  [self applySync];
}
- (void)applySync {
  if (![self current]) return [self finish:MDError(409, @"仓库或目录已改变，同步取消")];
  if ([self.operation isEqual:@"forceSync"]) {
    [self.protectedGroups removeAllObjects];
  } else {
    for (NSString *local in self.paths) {
      @autoreleasepool {
        if (![MDDigest(MDRead(self.root, local)) isEqual:self.before[local]]) [self.protectedGroups addObject:MDGroup(local)];
      }
    }
    for (NSString *local in self.records) {
      @autoreleasepool {
        if (![MDDigest(MDRead(self.root, local)) isEqual:self.records[local][@"baseline"]]) [self.protectedGroups addObject:MDGroup(local)];
      }
    }
  }
  NSError *e = nil;
  // Persist the repository binding before writing any files; a failed download never
  // binds, and a failed filesystem write cannot allow another repository to adopt them.
  self.state[@"files"] = self.records;
  if (!MDSaveState(self.root, self.state, &e)) return [self finish:e];
  for (NSString *local in self.paths) {
    @autoreleasepool {
      if (![self canDownloadLocal:local]) {
        // Safely adopt an existing upgrade file only after the remote blob was
        // downloaded and verified. Never overwrite local bytes or accept arbitrary edits.
        NSData *localData = MDRead(self.root, local), *remoteData = self.staged[local];
        BOOL equivalent = localData && remoteData && [localData isEqual:remoteData];
        if (!equivalent && ![local hasPrefix:@"assets/"] && localData && remoteData) {
          NSString *left = [[NSString alloc] initWithData:localData encoding:NSUTF8StringEncoding];
          NSString *right = [[NSString alloc] initWithData:remoteData encoding:NSUTF8StringEncoding];
          equivalent = left && right && [MDCanonicalReferences(left) isEqual:MDCanonicalReferences(right)];
        }
        if (!self.records[local] && equivalent && [MDDigest(localData) isEqual:self.before[local]]) {
          NSString *remote = self.mapping[local];
          self.records[local] = MDRecord(remote, self.snapshot[@"files"][remote][@"sha"], local, localData);
        }
        continue;
      }
      NSData *data = self.staged[local];
      if (data && !MDWrite(self.root, local, data, &e)) return [self finish:e];
      NSString *remote = self.mapping[local];
      self.records[local] = MDRecord(remote, self.snapshot[@"files"][remote][@"sha"], local, data ?: MDRead(self.root, local));
    }
  }
  // A remote deletion removes only our clean published mirror. Drafts, untracked
  // articles and locally edited files remain untouched; retained SHA records act as
  // tombstones and prevent accidentally recreating a deleted article on publish.
  for (NSString *local in [self.records.allKeys copy]) {
    if ([local hasPrefix:@"assets/"] || ![local.pathExtension isEqual:@"md"] || self.mapping[local] || [self.protectedGroups containsObject:MDGroup(local)]) continue;
    if (MDSingleSource(self.root, MDGroup(local)) || self.state[@"singleSource"][MDGroup(local)]) continue;
    NSData *data = MDRead(self.root, local);
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (![[LBMdStore parseFrontmatterAndBody:text][@"publish"] boolValue]) continue;
    for (NSString *articleFile in @[local, [MDGroup(local) stringByAppendingString:@".html"]]) {
      if (!self.records[articleFile]) continue;
      NSURL *url = MDURL(self.root, articleFile);
      if (!url) return [self finish:MDError(400, @"远端删除对应的本地路径不安全")];
      if ([NSFileManager.defaultManager fileExistsAtPath:url.path] && ![NSFileManager.defaultManager removeItemAtURL:url error:&e]) return [self finish:e];
    }
  }
  // A removed remote HTML must not keep shadowing newly downloaded Markdown.
  for (NSString *local in [self.records.allKeys copy]) {
    if ([local hasPrefix:@"assets/"] || ![local.pathExtension isEqual:@"html"] || self.mapping[local] || [self.protectedGroups containsObject:MDGroup(local)]) continue;
    if (![self.mapping[[MDGroup(local) stringByAppendingString:@".md"]] length]) continue;
    NSURL *url = MDURL(self.root, local);
    if (url && [NSFileManager.defaultManager fileExistsAtPath:url.path] && ![NSFileManager.defaultManager removeItemAtURL:url error:&e]) return [self finish:e];
    [self.records removeObjectForKey:local];
  }
  if ([self.operation isEqual:@"forceSync"]) {
    for (NSString *note in MDArticleIDs(self.root)) {
      NSString *htmlName = [note stringByAppendingString:@".html"];
      if (!self.mapping[htmlName]) {
        NSURL *url = MDURL(self.root, htmlName);
        if (url && [NSFileManager.defaultManager fileExistsAtPath:url.path]) {
          [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        }
        [self.records removeObjectForKey:htmlName];
      }
    }
  }
  self.state[@"files"] = self.records; self.state[@"head"] = self.snapshot[@"head"];
  if (!MDSaveState(self.root, self.state, &e)) return [self finish:e];
  if (!MDArchiveAll(self.root, &e)) return [self finish:e];
  [self finish:nil];
}
- (BOOL)checkBatchRemote:(NSString *)remote local:(NSString *)local removing:(BOOL)removing error:(NSError **)error {
  NSDictionary *entry = self.snapshot[@"files"][remote], *record = self.records[local];
  NSString *folded = local.precomposedStringWithCanonicalMapping.lowercaseString;
  for (NSString *other in self.snapshot[@"files"]) {
    NSString *path = MDLocalPath(other);
    if (!path || ![path.precomposedStringWithCanonicalMapping.lowercaseString isEqual:folded]) continue;
    if (![path isEqual:local] || (entry && ![self.snapshot[@"files"][other][@"sha"] isEqual:entry[@"sha"]])) {
      if (error) *error = MDError(409, @"远端存在重名或旧新附件冲突，批量提交已取消"); return NO;
    }
  }
  if (entry) {
    BOOL migration = [local hasPrefix:@"assets/"] && [record[@"remote"] hasPrefix:MDLegacyAssets()];
    if (![entry[@"mode"] isEqual:@"100644"] || !record || ![entry[@"sha"] isEqual:record[@"sha"]] || (!migration && ![record[@"remote"] isEqual:remote])) {
      if (error) *error = MDError(409, @"远端文章、侧件或附件不属于已确认基线；请先同步核对，未批量覆盖"); return NO;
    }
  } else if (record && !removing) {
    NSDictionary *legacy = self.snapshot[@"files"][record[@"remote"]];
    BOOL migration = [local hasPrefix:@"assets/"] && [record[@"remote"] hasPrefix:MDLegacyAssets()] && [legacy[@"mode"] isEqual:@"100644"] && [legacy[@"sha"] isEqual:record[@"sha"]];
    if (!migration) { if (error) *error = MDError(409, @"远端文件已删除，未批量重建；请先核对"); return NO; }
  }
  return YES;
}
- (void)prepareBatch {
  NSError *e = nil;
  if (!MDBatchItemsValid(self.batchItems)) return [self finish:MDError(400, @"批量文章 ID、操作或重复选择不安全")];
  self.changes = [NSMutableDictionary dictionary];
  for (NSDictionary *item in self.batchItems) {
    NSString *note = item[@"id"], *md = [note stringByAppendingString:@".md"], *html = [note stringByAppendingString:@".html"];
    NSString *remoteMD = [@"content/posts/" stringByAppendingString:md], *remoteHTML = [@"content/posts/" stringByAppendingString:html];
    BOOL removing = [item[@"action"] isEqual:@"unpublish"];
    if (!MDURL(self.root, md) || !MDURL(self.root, html)) return [self finish:MDError(400, @"批量文章路径不安全")];
    NSData *source = MDRead(self.root, md), *sidecar = MDRead(self.root, html);
    if (!sidecar && [NSFileManager.defaultManager fileExistsAtPath:MDURL(self.root, html).path]) return [self finish:MDError(400, @"本地 HTML 侧件存在但不可读取；整批未提交")];
    NSString *text = source ? [[NSString alloc] initWithData:source encoding:NSUTF8StringEncoding] : nil;
    if (!text) return [self finish:MDError(404, @"批量文章缺失或不是可读取 UTF-8；整批未提交")];
    NSDictionary *parsed = [LBMdStore parseFrontmatterAndBody:text];
    if ((parsed[@"id"] && ![parsed[@"id"] isEqual:note]) || [parsed[@"publish"] boolValue] == removing) return [self finish:MDError(409, @"暂存状态已改变，请重新核对批量选择")];
    if (![self checkBatchRemote:remoteMD local:md removing:removing error:&e] || ![self checkBatchRemote:remoteHTML local:html removing:YES error:&e]) return [self finish:e];
    self.before[md] = MDDigest(source); self.before[html] = MDDigest(sidecar);
    if (removing) {
      if (self.snapshot[@"files"][remoteMD]) self.changes[remoteMD] = NSNull.null;
      if (self.snapshot[@"files"][remoteHTML]) self.changes[remoteHTML] = NSNull.null;
      continue; // A staged unpublish always retains the local draft and sidecar.
    }
    if (sidecar && ((self.records[html] && ![MDDigest(sidecar) isEqual:self.records[html][@"baseline"]]) || (!self.records[html] && self.records[md]))) return [self finish:MDError(409, @"本地 HTML 侧件有独立修改或尚未认领，未批量删除保真内容；请先核对")];
    NSMutableDictionary *meta = [parsed mutableCopy]; meta[@"id"] = note; meta[@"publish"] = @YES;
    MDApplyDateStrings(meta, MDDates(parsed, MDURL(self.root, md)));
    meta[@"updatedAt"] = currentDateString();
    if (![meta[@"publishedAt"] length]) meta[@"publishedAt"] = currentDateString();
    NSString *body = MDCanonicalReferences(parsed[@"markdown"] ?: @"");
    NSData *payload = [[LBMdStore serializeFrontmatter:meta body:body] dataUsingEncoding:NSUTF8StringEncoding];
    self.changes[remoteMD] = payload; self.staged[md] = payload;
    BOOL sameBody = [MDBodyDigest(source) isEqual:self.records[md][@"bodyBaseline"]] || [MDDigest(source) isEqual:self.records[md][@"baseline"]];
    BOOL importedSidecar = sidecar && !self.records[md] && !self.records[html];
    BOOL singleSource = [parsed[@"singleSourceVersion"] integerValue] >= 1 || [parsed[@"bodyFormat"] isEqual:@"html"];
    BOOL lossless = !singleSource && sidecar && (importedSidecar || (sameBody && [MDDigest(sidecar) isEqual:self.records[html][@"baseline"]]));
    NSString *htmlText = @"";
    if (lossless) {
      if (![self checkBatchRemote:remoteHTML local:html removing:NO error:&e]) return [self finish:e];
      htmlText = [[NSString alloc] initWithData:sidecar encoding:NSUTF8StringEncoding];
      if (!htmlText) return [self finish:MDError(400, @"HTML 侧件不是 UTF-8，整批未提交")];
      htmlText = MDCanonicalReferences(htmlText);
      NSData *htmlPayload = [htmlText dataUsingEncoding:NSUTF8StringEncoding];
      self.changes[remoteHTML] = htmlPayload; self.staged[html] = htmlPayload;
    } else if (self.snapshot[@"files"][remoteHTML]) self.changes[remoteHTML] = NSNull.null;
    NSArray *assets = MDAssetReferences(body, htmlText, &e);
    if (!assets) return [self finish:e];
    for (NSString *local in assets) {
      NSData *data = MDRead(self.root, local); NSString *remote = [@"public/" stringByAppendingString:local];
      if (!data) return [self finish:MDError(404, @"文章引用的本地附件缺失或不可读取；整批未提交")];
      if (self.before[local] && ![self.before[local] isEqual:MDDigest(data)]) return [self finish:MDError(409, @"准备提交期间共享附件有修改，整批未提交")];
      if (![self checkBatchRemote:remote local:local removing:NO error:&e]) return [self finish:e];
      self.before[local] = MDDigest(data); self.changes[remote] = data; self.staged[local] = data;
    }
  }
  if (![self current]) return [self finish:MDError(409, @"目录或仓库已改变，未批量提交")];
  if (!MDSaveState(self.root, self.state, &e)) return [self finish:e];
  if (!self.changes.count) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self applyBatch:@{@"shas":@{}, @"commit":self.snapshot[@"head"]}]; });
    return;
  }
  NSDictionary *changes = self.changes;
  NSString *message = self.message.length ? self.message : [NSString stringWithFormat:@"content: 批量更新 %lu 篇文章发布与下架状态", (unsigned long)self.batchItems.count];
  [self.github commitChanges:changes snapshot:self.snapshot message:message prepared:^BOOL(NSDictionary *pending, NSError **saveError) {
    if (![self current]) { if (saveError) *saveError = MDError(409, @"目录或仓库已改变，未批量提交"); return NO; }
    NSMutableDictionary *record = [pending mutableCopy], *payloads = [NSMutableDictionary dictionary];
    for (NSString *remote in self.changes) {
      id value = self.changes[remote]; payloads[remote] = value == NSNull.null ? NSNull.null : [value base64EncodedStringWithOptions:0];
    }
    record[@"operation"] = @"batch"; record[@"items"] = self.batchItems; record[@"singleSourceVersion"] = @1;
    record[@"before"] = self.before; record[@"payloads"] = payloads;
    self.state[@"pending"] = record;
    return MDSaveState(self.root, self.state, saveError);
  } done:^(NSDictionary *result, NSError *error) {
    if (error) return [self finish:error];
    // App saves/staging run synchronously on main; do not interleave them with
    // the preflight+apply window. External file-provider races still need QA.
    dispatch_async(dispatch_get_main_queue(), ^{ [self applyBatch:result]; });
  }];
}
- (void)applyBatch:(NSDictionary *)result {
  if (![self current]) return [self finish:MDError(409, @"远端已成功，但目录或仓库已改变；保留待确认批量记录")];
  BOOL changedDuringUpload = NO;
  BOOL confirmed = [self.state[@"pending"][@"confirmed"] boolValue];
  NSMutableSet *removableHTML = [NSMutableSet set];
  for (NSDictionary *item in self.batchItems) {
    NSString *html = [item[@"id"] stringByAppendingString:@".html"];
    if (![item[@"action"] isEqual:@"unpublish"] && !self.staged[html]) [removableHTML addObject:html];
  }
  // Conservative transaction-wide protection also covers shared/cross-note assets.
  // Baselines still describe exactly the remote payload, never a newer local edit.
  for (NSString *local in self.before) {
    NSString *digest = MDDigest(MDRead(self.root, local));
    BOOL alreadyApplied = (self.staged[local] && [digest isEqual:MDDigest(self.staged[local])]) || ([removableHTML containsObject:local] && [digest isEqual:@""]);
    if (MDKeepLocalEdit([digest isEqual:self.before[local]], confirmed, alreadyApplied, 0)) changedDuringUpload = YES;
  }
  NSError *e = nil;
  if (self.state[@"pending"]) {
    NSMutableDictionary *pending = [self.state[@"pending"] mutableCopy]; pending[@"confirmed"] = @YES; self.state[@"pending"] = pending;
    if (!MDSaveState(self.root, self.state, &e)) return [self finish:e];
  }
  for (NSString *remote in self.changes) {
    NSString *local = MDLocalPath(remote); id payload = self.changes[remote];
    if (payload == NSNull.null) { [self.records removeObjectForKey:local]; continue; }
    if (!changedDuringUpload && ![local hasPrefix:@"assets/"] && !MDWrite(self.root, local, payload, &e)) return [self finish:e];
    self.records[local] = MDRecord(remote, result[@"shas"][remote], local, payload);
  }
  NSMutableDictionary *guards = [self.state[@"singleSource"] mutableCopy] ?: [NSMutableDictionary dictionary];
  for (NSDictionary *item in self.batchItems) {
    NSString *note = item[@"id"], *md = [note stringByAppendingString:@".md"], *html = [note stringByAppendingString:@".html"];
    if ([item[@"action"] isEqual:@"unpublish"]) {
      // Even an already-absent remote is a successful idempotent unpublish.
      [self.records removeObjectForKey:md]; [self.records removeObjectForKey:html];
    } else if ([removableHTML containsObject:html]) {
      if (!changedDuringUpload) {
        NSURL *url = MDURL(self.root, html);
        if (!url) return [self finish:MDError(400, @"本地侧件路径不安全，保留待确认批量记录")];
        if ([NSFileManager.defaultManager fileExistsAtPath:url.path] && ![NSFileManager.defaultManager removeItemAtURL:url error:&e]) return [self finish:e];
      }
      [self.records removeObjectForKey:html];
    }
    if (!changedDuringUpload) {
      NSString *text = [[NSString alloc] initWithData:MDRead(self.root, md) encoding:NSUTF8StringEncoding];
      if (!text || !MDArchive(self.root, note, [LBMdStore parseFrontmatterAndBody:text], &e)) return [self finish:e ?: MDError(400, @"本地文章无法归档，保留待确认批量记录")];
      if (MDSingleSource(self.root, note)) guards[note] = @{@"version":@1, @"status":[item[@"action"] isEqual:@"unpublish"] ? @"needs-publish" : @"published", @"mdBaseline":MDDigest(MDRead(self.root, md))};
    }
  }
  self.state[@"files"] = self.records; self.state[@"head"] = result[@"commit"]; self.state[@"singleSource"] = guards;
  [self.state removeObjectForKey:@"pending"];
  if (!MDSaveState(self.root, self.state, &e)) return [self finish:e];
  if (changedDuringUpload) return [self finish:MDError(409, @"远端批量提交已成功；上传期间本地有修改，已完整保留，请重新核对最新内容")];
  [self finish:self.recoveredDifferentRequest ? MDError(409, @"已恢复上次成功批量提交；本次新操作未执行，请重新选择") : nil];
}

- (BOOL)checkRemote:(NSString *)remote local:(NSString *)local error:(NSError **)error {
  NSString *folded = local.precomposedStringWithCanonicalMapping.lowercaseString;
  for (NSString *otherRemote in self.snapshot[@"files"]) {
    NSString *otherLocal = MDLocalPath(otherRemote);
    if (otherLocal && ![otherLocal isEqual:local] && [otherLocal.precomposedStringWithCanonicalMapping.lowercaseString isEqual:folded]) {
      if (error) *error = MDError(409, @"远端存在大小写或 Unicode 同名目标，拒绝发布"); return NO;
    }
  }
  NSDictionary *entry = self.snapshot[@"files"][remote], *record = self.records[local];
  if (entry) {
    if (![entry[@"mode"] isEqual:@"100644"]) {
      if (error) *error = MDError(400, @"远端目标不是普通文件，无法操作"); return NO;
    }
    // Unpublish and delete change state or remove the target; they must never be
    // blocked by a missing or historical baseline on an article written elsewhere.
    if ([self.operation isEqual:@"unpublish"] || [self.operation isEqual:@"delete"]) {
      return YES;
    }
    // Publishing an article written outside the app or imported externally
    // cleanly establishes ownership and pushes the user's latest version.
    if (!record) {
      return YES;
    }
    if (![record[@"remote"] isEqual:remote] || ![record[@"sha"] isEqual:entry[@"sha"]]) {
      if (error) *error = MDError(409, @"远端文章、侧件或附件与同步基线冲突，请先同步并核对"); return NO;
    }
    return YES;
  } else if ([record[@"remote"] isEqual:remote] && [record[@"sha"] length]) {
    if (error) *error = MDError(409, @"远端文件已删除，请核对后使用新 ID 保存"); return NO;
  }
  return YES;
}
- (void)preparePublish {
  NSString *md = [self.note stringByAppendingString:@".md"], *html = [self.note stringByAppendingString:@".html"];
  NSString *remoteMD = [@"content/posts/" stringByAppendingString:md], *remoteHTML = [@"content/posts/" stringByAppendingString:html];
  NSError *e = nil;
  if (!([self.operation isEqual:@"delete"] && !self.snapshot[@"files"][remoteMD]) && ![self checkRemote:remoteMD local:md error:&e]) return [self finish:e];
  if (self.snapshot[@"files"][remoteHTML] && ![self.operation isEqual:@"unpublish"] && ![self.operation isEqual:@"delete"] && ![self checkRemote:remoteHTML local:html error:&e]) return [self finish:e];
  NSData *source = MDRead(self.root, md);
  NSString *text = source ? [[NSString alloc] initWithData:source encoding:NSUTF8StringEncoding] : nil;
  if (!text) return [self finish:MDError(404, @"未找到可读取的本地文章")];
  NSDictionary *parsed = [LBMdStore parseFrontmatterAndBody:text];
  if (parsed[@"id"] && ![parsed[@"id"] isEqual:self.note]) return [self finish:MDError(409, @"文章 ID 与文件名不一致")];
  self.changes = [NSMutableDictionary dictionary]; self.before[md] = MDDigest(source);
  self.before[html] = MDDigest(MDRead(self.root, html));
  if ([self.operation isEqual:@"delete"]) {
    if (self.snapshot[@"files"][remoteMD]) self.changes[remoteMD] = NSNull.null;
    if (self.snapshot[@"files"][remoteHTML]) self.changes[remoteHTML] = NSNull.null;
  } else {
    BOOL publishing = [self.operation isEqual:@"publish"];
    NSMutableDictionary *meta = [parsed mutableCopy]; meta[@"id"] = self.note;
    MDApplyDateStrings(meta, MDDates(parsed, MDURL(self.root, md)));
    meta[@"publish"] = @(publishing); meta[@"updatedAt"] = currentDateString();
    if (publishing && ![meta[@"publishedAt"] length]) meta[@"publishedAt"] = currentDateString();
    NSString *body = MDCanonicalReferences(parsed[@"markdown"] ?: @"");
    NSData *payload = [[LBMdStore serializeFrontmatter:meta body:body] dataUsingEncoding:NSUTF8StringEncoding];
    self.changes[remoteMD] = payload; self.staged[md] = payload;
    // Sidecar is retained only if both the Markdown baseline and the sidecar baseline
    // are untouched. Otherwise remove it in the SAME tree as the changed Markdown.
    NSData *sidecar = MDRead(self.root, html);
    BOOL sameBody = [MDBodyDigest(source) isEqual:self.records[md][@"bodyBaseline"]] || [MDDigest(source) isEqual:self.records[md][@"baseline"]];
    BOOL importedSidecar = sidecar && !self.records[md] && !self.records[html];
    BOOL singleSource = [parsed[@"singleSourceVersion"] integerValue] >= 1 || [parsed[@"bodyFormat"] isEqual:@"html"];
    BOOL lossless = !singleSource && sidecar && (importedSidecar || (sameBody && [MDDigest(sidecar) isEqual:self.records[html][@"baseline"]]));
    if (lossless) {
      NSString *rawHTML = [[NSString alloc] initWithData:sidecar encoding:NSUTF8StringEncoding];
      if (!rawHTML) return [self finish:MDError(400, @"HTML 侧件不是 UTF-8")];
      NSData *canonical = [MDCanonicalReferences(rawHTML) dataUsingEncoding:NSUTF8StringEncoding];
      self.changes[remoteHTML] = canonical; self.staged[html] = canonical;
    } else if (self.snapshot[@"files"][remoteHTML]) self.changes[remoteHTML] = NSNull.null;
    if (publishing) {
      NSString *htmlText = lossless ? [[NSString alloc] initWithData:self.staged[html] encoding:NSUTF8StringEncoding] : @"";
      NSArray *assetPaths = MDAssetReferences(body, htmlText, &e);
      if (!assetPaths) return [self finish:e];
      for (NSString *local in assetPaths) {
        NSData *data = MDRead(self.root, local); NSString *remote = [@"public/" stringByAppendingString:local];
        if (!data) return [self finish:MDError(404, @"文章引用的本地附件缺失或不可读取")];
        self.before[local] = MDDigest(data);
        NSDictionary *entry = self.snapshot[@"files"][remote];
        // A legacy-to-canonical move is safe only if the existing canonical blob is
        // the exact baseline blob; otherwise normal SHA ownership is mandatory.
        BOOL migrationSame = [self.records[local][@"remote"] hasPrefix:MDLegacyAssets()] && [self.records[local][@"sha"] isEqual:entry[@"sha"]];
        if (!migrationSame && ![self checkRemote:remote local:local error:&e]) return [self finish:e];
        self.changes[remote] = data; self.staged[local] = data;
      }
    }
  }
  if (![self current]) return [self finish:MDError(409, @"仓库或目录已改变，发布取消")];
  // Establish repository ownership before the remote write, even when this is the
  // first locally-created article in a brand-new folder.
  if (!MDSaveState(self.root, self.state, &e)) return [self finish:e];
  if (!self.changes.count) { [self applyPublish:@{@"shas":@{}, @"commit":self.snapshot[@"head"]}]; return; }
  [self.github commitChanges:self.changes snapshot:self.snapshot message:[NSString stringWithFormat:@"%@: %@", self.operation, self.note] prepared:^BOOL(NSDictionary *pending, NSError **saveError) {
    if (![self current]) { if (saveError) *saveError = MDError(409, @"目录或仓库已改变，未发布"); return NO; }
    NSMutableDictionary *record = [pending mutableCopy], *payloads = [NSMutableDictionary dictionary];
    for (NSString *remote in self.changes) {
      id value = self.changes[remote]; payloads[remote] = value == NSNull.null ? NSNull.null : [value base64EncodedStringWithOptions:0];
    }
    record[@"operation"] = self.operation; record[@"note"] = self.note;
    if (MDSingleSource(self.root, self.note)) record[@"singleSourceVersion"] = @1;
    record[@"before"] = self.before; record[@"payloads"] = payloads;
    self.state[@"pending"] = record;
    return MDSaveState(self.root, self.state, saveError);
  } done:^(NSDictionary *result, NSError *error) {
    if (error) return [self finish:error]; // preserve all local draft bytes and assets
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      [self applyPublish:result];
    });
  }];
}
- (void)applyPublish:(NSDictionary *)result {
  if (![self current]) return [self finish:MDError(409, @"远端已成功，但目录或仓库已改变；未修改本地，请重新同步核对")];
  NSString *md = [self.note stringByAppendingString:@".md"], *html = [self.note stringByAppendingString:@".html"];
  BOOL changedDuringUpload = NO;
  for (NSString *local in self.before) {
    NSString *digest = MDDigest(MDRead(self.root, local));
    BOOL removedPayload = self.changes[[@"content/posts/" stringByAppendingString:local]] == NSNull.null;
    BOOL alreadyApplied = [self.state[@"pending"][@"confirmed"] boolValue] && ((self.staged[local] && [digest isEqual:MDDigest(self.staged[local])]) || (([self.operation isEqual:@"delete"] || removedPayload) && [digest isEqual:@""]));
    if (MDKeepLocalEdit([digest isEqual:self.before[local]], [self.state[@"pending"][@"confirmed"] boolValue], alreadyApplied, [self.operation isEqual:@"delete"] && [digest isEqual:@""])) changedDuringUpload = YES;
  }
  NSError *e = nil;
  if (self.state[@"pending"]) {
    NSMutableDictionary *pending = [self.state[@"pending"] mutableCopy];
    pending[@"confirmed"] = @YES; self.state[@"pending"] = pending;
    if (!MDSaveState(self.root, self.state, &e)) return [self finish:e];
  }
  if ([self.operation isEqual:@"delete"]) {
    if (changedDuringUpload) return [self finish:MDError(409, @"远端已删除；本地上传期间有修改，已保留本地草稿")];
    for (NSString *local in @[md, html]) {
      NSURL *url = MDURL(self.root, local);
      if (!url) return [self finish:MDError(400, @"本地删除路径不安全")];
      if ([NSFileManager.defaultManager fileExistsAtPath:url.path] && ![NSFileManager.defaultManager removeItemAtURL:url error:&e]) return [self finish:e];
      [self.records removeObjectForKey:local];
    }
  } else {
    for (NSString *remote in self.changes) {
      NSString *local = MDLocalPath(remote); id payload = self.changes[remote];
      if (payload == NSNull.null) {
        if (!changedDuringUpload) {
          NSURL *url = MDURL(self.root, local);
          if (url && [NSFileManager.defaultManager fileExistsAtPath:url.path] && ![NSFileManager.defaultManager removeItemAtURL:url error:&e]) return [self finish:e];
        }
        [self.records removeObjectForKey:local]; continue;
      }
      if (![local hasPrefix:@"assets/"] && !changedDuringUpload && !MDWrite(self.root, local, payload, &e)) return [self finish:e];
      self.records[local] = MDRecord(remote, result[@"shas"][remote], local, payload);
    }
    // Even when the old HTML was not in Git, invalidate it locally after changing md.
    if (!self.staged[html] && !changedDuringUpload) {
      NSURL *url = MDURL(self.root, html);
      if (url && [NSFileManager.defaultManager fileExistsAtPath:url.path] && ![NSFileManager.defaultManager removeItemAtURL:url error:&e]) return [self finish:e];
      [self.records removeObjectForKey:html];
    }
  }
  if (![self.operation isEqual:@"delete"] && !changedDuringUpload) {
    NSString *text = [[NSString alloc] initWithData:MDRead(self.root, md) encoding:NSUTF8StringEncoding];
    if (!MDArchive(self.root, self.note, [LBMdStore parseFrontmatterAndBody:text], &e)) return [self finish:e];
  }
  self.state[@"files"] = self.records; self.state[@"head"] = result[@"commit"];
  if (!changedDuringUpload && MDSingleSource(self.root, self.note)) {
    NSMutableDictionary *guards = [self.state[@"singleSource"] mutableCopy] ?: [NSMutableDictionary dictionary];
    guards[self.note] = @{@"version":@1, @"status":@"published", @"mdBaseline":MDDigest(MDRead(self.root, md))};
    self.state[@"singleSource"] = guards;
  }
  [self.state removeObjectForKey:@"pending"];
  if (!MDSaveState(self.root, self.state, &e)) return [self finish:e];
  if (changedDuringUpload) return [self finish:MDError(409, @"远端已成功；上传期间本地有修改，已完整保留，请再次发布最新内容")];
  [self finish:self.recoveredDifferentRequest ? MDError(409, @"已恢复上次成功发布；本次新操作未执行，请重新选择") : nil];
}
@end
