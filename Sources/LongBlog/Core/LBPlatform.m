#import "LBPlatform.h"

NSURL *LBApplicationSupportURL(void) {
  NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
  // Foundation always supplies this directory on macOS. Do not silently fall
  // back to Documents, the process working directory, or a user's notes folder.
  NSCAssert(support != nil, @"Application Support directory is unavailable");
  return [support URLByAppendingPathComponent:@"longBlog" isDirectory:YES];
}

BOOL LBProtectLocalURL(NSURL *url, NSError **error) {
  NSFileManager *fm = NSFileManager.defaultManager;
  if (!url.isFileURL) {
    if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInvalidFileNameError userInfo:nil];
    return NO;
  }
  NSDictionary *attributes = [fm attributesOfItemAtPath:url.path error:error];
  NSString *type = attributes[NSFileType];
  BOOL directory = [type isEqual:NSFileTypeDirectory];
  if (!directory && ![type isEqual:NSFileTypeRegular]) {
    if (error && attributes) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
    return NO;
  }
  if (![fm setAttributes:@{NSFilePosixPermissions:directory ? @0700 : @0600} ofItemAtPath:url.path error:error]) return NO;
  return [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:error];
}
