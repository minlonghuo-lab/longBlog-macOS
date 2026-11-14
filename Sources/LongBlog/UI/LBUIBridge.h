#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Main-queue UI facade. Results retain opaque Core transaction guards, never JSON-roundtrip them.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *LBUIConnectionSettings(void);
FOUNDATION_EXPORT void LBUIRequest(NSString *operation, NSDictionary<NSString *, id> *arguments,
    void (^completion)(NSDictionary<NSString *, id> * _Nullable result, NSError * _Nullable error));
NS_ASSUME_NONNULL_END
