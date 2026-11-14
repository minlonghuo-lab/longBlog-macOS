#import "LB.h"
#import "LBMemos.h"

NSString *LBRelativeTime(long long ms) {
  NSTimeInterval d = [NSDate date].timeIntervalSince1970 - ms / 1000.0;
  if (d < 60) return @"刚刚";
  if (d < 3600) return [NSString stringWithFormat:@"%d 分钟前", (int)(d / 60)];
  NSDate *date = [NSDate dateWithTimeIntervalSince1970:ms / 1000.0];
  // Creating a formatter per call was measurable while scrolling the memo list.
  static NSDateFormatter *today, *other;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    today = [NSDateFormatter new]; today.dateFormat = @"HH:mm";
    other = [NSDateFormatter new]; other.dateFormat = @"M月d日 HH:mm";
    for (NSDateFormatter *f in @[ today, other ]) {
      f.locale = NSLocale.autoupdatingCurrentLocale;
      f.timeZone = NSTimeZone.localTimeZone; // auto-updating
    }
  });
  return [([[NSCalendar currentCalendar] isDateInToday:date] ? today : other) stringFromDate:date];
}

NSString *LBRemaining(long long expiresAtMs) {
  NSTimeInterval d = expiresAtMs / 1000.0 - [NSDate date].timeIntervalSince1970;
  if (d <= 0) return @"已过期";
  if (d < 3600) return [NSString stringWithFormat:@"剩 %d 分钟", (int)(d / 60) + 1];
  return [NSString stringWithFormat:@"剩 %d 小时", (int)(d / 3600)];
}

NSString *LBMemoVisibility(NSString *value) {
  if ([value isEqual:@"PRIVATE"]) return @"仅自己";
  if ([value isEqual:@"PROTECTED"]) return @"登录可见";
  return @"公开";
}
NSString *LBMemoPlain(NSString *markdown) {
  NSString *s = markdown ?: @"";
  for (NSArray *pair in @[ @[ @"!\\[[^\\]]*\\]\\([^)]*\\)", @"[图片]" ], @[ @"\\[([^\\]]+)\\]\\([^)]*\\)", @"$1" ], @[ @"(?m)^#{1,6}\\s+", @"" ], @[ @"(\\*\\*|__|~~)", @"" ] ])
    s = [s stringByReplacingOccurrencesOfString:pair[0] withString:pair[1] options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)];
  return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
