#import "LB.h"
#import <UserNotifications/UserNotifications.h>
// macOS uses Foundation scheduling instead of mobile background task APIs.

NSString *const LBRefreshTaskID = @"com.huowenlong.longblog.macos.refresh";
NSString *const LBSyncDidChange = @"LBSyncDidChange";
NSString *const LBOpenSessionRequest = @"LBOpenSessionRequest";
static NSString *const kRead = @"LBReadUserSequence";       // sid -> last visitor sequence the owner has seen
static NSString *const kNotified = @"LBNotifiedUserSequence"; // sid -> last visitor sequence a banner was posted for
static NSString *const kBaseline = @"LBBaselineDone";

@implementation LBSync {
  NSTimer *_timer;
  NSBackgroundActivityScheduler *_backgroundScheduler;
  BOOL _inFlight;
  NSUInteger _generation;
  NSMutableArray *_waiters;
}
+ (instancetype)shared {
  static LBSync *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [LBSync new]; });
  return s;
}
- (instancetype)init {
  if ((self = [super init])) { _sessions = @[]; _waiters = [NSMutableArray array]; }
  return self;
}
- (NSMutableDictionary *)map:(NSString *)key {
  return [[NSUserDefaults.standardUserDefaults dictionaryForKey:key] ?: @{} mutableCopy];
}
- (void)save:(NSDictionary *)m key:(NSString *)key { [NSUserDefaults.standardUserDefaults setObject:m forKey:key]; }

- (BOOL)isUnread:(LBSession *)s {
  if (s.archived || s.expiresAt <= (long long)(NSDate.date.timeIntervalSince1970 * 1000)) return NO;
  return s.lastUserSequence > [[self map:kRead][s.sessionId] integerValue];
}
- (NSInteger)unreadCount {
  NSInteger n = 0;
  for (LBSession *s in _sessions) n += [self isUnread:s];
  return n;
}
- (void)markRead:(NSString *)sid upTo:(NSInteger)seq {
  NSMutableDictionary *r = [self map:kRead], *n = [self map:kNotified];
  if (seq > [r[sid] integerValue]) r[sid] = @(seq);
  if (seq > [n[sid] integerValue]) n[sid] = @(seq);
  [self save:r key:kRead];
  [self save:n key:kNotified];
  [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:@[ sid ]];
  [self updateBadge];
  [NSNotificationCenter.defaultCenter postNotificationName:LBSyncDidChange object:self];
}
- (void)resetBaseline {
  [self stopForegroundPolling];
  _generation++;
  _inFlight = NO;
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kBaseline];
  _sessions = @[];
  _lastError = nil;
  _lastSync = nil;
  self.activeSession = nil;
  [self updateBadge];
  [self finish:NO];
}
- (void)updateBadge {
  NSInteger count = [self unreadCount];
  NSApplication.sharedApplication.dockTile.badgeLabel = count ? [NSString stringWithFormat:@"%ld", (long)count] : nil;
}

- (void)refresh:(void (^)(BOOL))done {
  if (done) [_waiters addObject:[done copy]];
  if (_inFlight) return;
  if (![LBAPI.shared configured]) { [self finish:NO]; return; }
  _inFlight = YES;
  NSUInteger generation = _generation;
  [LBAPI.shared fetchSessions:^(NSArray<LBSession *> *list, NSError *e) {
    if (generation != self->_generation) return;
    self->_inFlight = NO;
    self->_lastError = e;
    if (e) { [self finish:NO]; return; }
    self->_lastSync = [NSDate date];
    self->_sessions = list;
    BOOL fresh = [self notifyNewMessages:list];
    // Forget local state for sessions that expired server-side.
    NSSet *alive = [NSSet setWithArray:[list valueForKey:@"sessionId"]];
    for (NSString *key in @[ kRead, kNotified ]) {
      NSMutableDictionary *m = [self map:key];
      for (NSString *sid in m.allKeys) if (![alive containsObject:sid]) [m removeObjectForKey:sid];
      [self save:m key:key];
    }
    [self updateBadge];
    [self finish:fresh];
  }];
}
- (void)finish:(BOOL)fresh {
  NSArray *w = [_waiters copy];
  [_waiters removeAllObjects];
  [NSNotificationCenter.defaultCenter postNotificationName:LBSyncDidChange object:self];
  for (void (^b)(BOOL) in w) b(fresh);
}

/// Posts one local banner per conversation that has unseen visitor messages.
/// The very first successful sync only records a baseline, so connecting the app
/// does not flood the lock screen with old conversations.
- (BOOL)notifyNewMessages:(NSArray<LBSession *> *)list {
  NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
  NSMutableDictionary *n = [self map:kNotified];
  BOOL baseline = ![u boolForKey:kBaseline], fresh = NO;
  for (LBSession *s in list) {
    NSInteger seen = [n[s.sessionId] integerValue];
    if (s.lastUserSequence <= seen) continue;
    n[s.sessionId] = @(s.lastUserSequence);
    fresh = YES;
    if (baseline || [s.sessionId isEqualToString:self.activeSession]) continue;
    UNMutableNotificationContent *c = [UNMutableNotificationContent new];
    c.title = [NSString stringWithFormat:@"终端新留言 · #%@", s.shortId];
    c.body = [s.last fromVisitor] ? s.last.text : @"访客发来了新消息";
    c.sound = UNNotificationSound.defaultSound;
    c.threadIdentifier = s.sessionId;
    c.userInfo = @{ @"sessionId" : s.sessionId };
    c.categoryIdentifier = @"LB_MESSAGE";
    // Same identifier per conversation: a newer banner replaces the older one.
    UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:s.sessionId content:c trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:r withCompletionHandler:nil];
  }
  [self save:n key:kNotified];
  [u setBool:YES forKey:kBaseline];
  return fresh;
}

#pragma mark Scheduling
- (void)startForegroundPolling {
  if (_timer.valid) return;
  _timer = [NSTimer scheduledTimerWithTimeInterval:12 repeats:YES block:^(NSTimer *t) { [self refresh:nil]; }];
  _timer.tolerance = 3;
  [self refresh:nil];
}
- (void)stopForegroundPolling {
  [_timer invalidate];
  _timer = nil;
}
- (void)scheduleBackgroundRefresh {
  if (_backgroundScheduler) return;
  _backgroundScheduler = [[NSBackgroundActivityScheduler alloc] initWithIdentifier:LBRefreshTaskID];
  _backgroundScheduler.interval = 15 * 60;
  _backgroundScheduler.tolerance = 5 * 60;
  _backgroundScheduler.repeats = YES;
  _backgroundScheduler.qualityOfService = NSQualityOfServiceUtility;
  __weak LBSync *weakSelf = self;
  [_backgroundScheduler scheduleWithBlock:^(NSBackgroundActivityCompletionHandler completion) {
    dispatch_async(dispatch_get_main_queue(), ^{
      LBSync *sync = weakSelf;
      if (!sync) { completion(NSBackgroundActivityResultFinished); return; }
      [sync refresh:^(BOOL fresh) { completion(NSBackgroundActivityResultFinished); }];
    });
  }];
}
@end
