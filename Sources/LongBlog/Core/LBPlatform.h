#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Returns ~/Library/Application Support/longBlog (sandbox-aware), without IO.
FOUNDATION_EXPORT NSURL *LBApplicationSupportURL(void);
/// Keychain service / storage namespace. Release builds use the fixed release bundle ID;
/// side-by-side dev builds (bundle ID with a suffix) get isolated Keychain items and data.
FOUNDATION_EXPORT NSString *LBAppNamespace(void);
/// macOS local privacy: regular files 0600, directories 0700; excludes from backup.
/// Refuses symlinks/non-file URLs. This is not iOS Data Protection or encryption.
FOUNDATION_EXPORT BOOL LBProtectLocalURL(NSURL *url, NSError * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
