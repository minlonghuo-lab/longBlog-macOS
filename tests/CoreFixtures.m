// Native fixtures use temporary note folders and simulated Security.framework items.
// The isolated credential-slot preference is removed after the test.
#import "LongBlog-Bridging-Header.h"
#include <stdio.h>
#include <stdlib.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <LocalAuthentication/LocalAuthentication.h>

static NSUInteger checks;
#define CHECK(...) do { checks++; if (!(__VA_ARGS__)) { \
  fprintf(stderr, "Core fixture failed at %s:%d: %s\n", __FILE__, __LINE__, #__VA_ARGS__); abort(); \
} } while (0)

// This fixture executable replaces the Security.framework read at link time.
// No credentials are read; a blocked quiet request can be retried explicitly.
static NSUInteger fixtureSecretReads;
static BOOL fixtureKeychainUnlocked;
static NSMutableDictionary<NSString *, NSData *> *fixtureItems;
static NSString *fixtureAccount;
static void CheckQuietMode(void) {
  Boolean allowed = true;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CHECK(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess && !allowed);
#pragma clang diagnostic pop
}
OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
  NSDictionary *query = (__bridge NSDictionary *)attributes;
  NSString *account = query[(__bridge id)kSecAttrAccount];
  CHECK(fixtureAccount && [account hasPrefix:[fixtureAccount stringByAppendingString:@"."]]);
  CheckQuietMode();
  fixtureItems[account] = query[(__bridge id)kSecValueData];
  return errSecSuccess;
}
OSStatus SecItemDelete(CFDictionaryRef attributes) {
  NSString *account = ((__bridge NSDictionary *)attributes)[(__bridge id)kSecAttrAccount];
  CHECK(fixtureItems[account] != nil);
  CheckQuietMode();
  [fixtureItems removeObjectForKey:account];
  return errSecSuccess;
}
OSStatus SecItemCopyMatching(CFDictionaryRef attributes, CFTypeRef *result) {
  NSDictionary *query = (__bridge NSDictionary *)attributes;
  NSString *account = query[(__bridge id)kSecAttrAccount];
  CHECK([account isEqual:@"offline-fixture-token"] || [account hasPrefix:fixtureAccount ?: @"offline-fixture-token"]);
  fixtureSecretReads++;
  LAContext *context = query[(__bridge id)kSecUseAuthenticationContext];
  CHECK(context.interactionNotAllowed);
  Boolean allowed = true;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CHECK(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess && !allowed);
#pragma clang diagnostic pop
  if (fixtureItems) {
    NSData *item = fixtureItems[account];
    if (!item) return errSecInteractionNotAllowed; // old build has an inaccessible item
    *result = CFBridgingRetain(item); return errSecSuccess;
  }
  if (!fixtureKeychainUnlocked) return errSecInteractionNotAllowed;
  *result = CFBridgingRetain([@"fixture" dataUsingEncoding:NSUTF8StringEncoding]);
  return errSecSuccess;
}
static void QuietCredentialFixtures(void) {
  CHECK([LBKeychain getWithoutPrompt:@"offline-fixture-token"] == nil);
  CHECK([LBKeychain get:@"offline-fixture-token"] == nil);
  fixtureKeychainUnlocked = YES;
  CHECK([[LBKeychain get:@"offline-fixture-token"] isEqual:@"fixture"]);
  CHECK([[LBKeychain getWithoutPrompt:@"offline-fixture-token"] isEqual:@"fixture"]);
  CHECK(fixtureSecretReads == 3);
  fixtureItems = [NSMutableDictionary dictionary];
  fixtureAccount = [@"fixture-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSString *key = [@"LBCredentialSlot." stringByAppendingString:fixtureAccount];
  @try {
    [LBKeychain set:@"first input" account:fixtureAccount];
    NSString *slot = [NSUserDefaults.standardUserDefaults stringForKey:key];
    CHECK(slot && fixtureItems[slot]);
    CHECK([[LBKeychain getWithoutPrompt:fixtureAccount] isEqual:@"first input"]);
    [LBKeychain set:@"replacement" account:fixtureAccount];
    CHECK(fixtureItems.count == 1 && !fixtureItems[slot]);
    CHECK([[LBKeychain get:fixtureAccount] isEqual:@"replacement"]);
    [LBKeychain set:@"" account:fixtureAccount];
    CHECK(fixtureItems.count == 0 && ![LBKeychain get:fixtureAccount]);
  } @finally {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
  }
}

@interface OfflineGit : LBGitHub
@property NSUInteger blobReads;
@end
@implementation OfflineGit
- (NSString *)frozenRepository { return @"example/blog"; }
- (void)headCommit:(void (^)(NSDictionary *, NSError *))done { done(@{@"treeSHA":@"tree"}, nil); }
- (void)request:(NSString *)method suffix:(NSString *)suffix body:(NSDictionary *)body done:(void (^)(NSDictionary *, NSError *))done {
  CHECK([method isEqual:@"GET"] && [suffix isEqual:@"/git/trees/tree"]);
  done(@{@"tree":@[@{@"path":@".env", @"sha":[@"a" stringByPaddingToLength:40 withString:@"a" startingAtIndex:0], @"type":@"blob", @"mode":@"100644"}]},nil);
}
- (void)getBlobData:(NSString *)sha done:(void (^)(NSData *, NSError *))done {
  self.blobReads++; done([@"PUBLIC_SITE_TITLE=test" dataUsingEncoding:NSUTF8StringEncoding], nil);
}
@end

@interface OfflineMemos : LBMemosClient
@property (copy) NSArray *responseRows;
@property NSInteger responseStatus;
@property (copy) NSString *receivedValidator;
@end
@implementation OfflineMemos
- (NSError *)ready { return nil; }
- (NSDictionary *)user { return @{@"id":@42}; }
- (NSURLSessionTask *)request:(NSString *)method path:(NSString *)path query:(NSArray *)query json:(id)json
                    bodyFile:(NSURL *)file contentType:(NSString *)type download:(NSURL *)url mutation:(BOOL)mutation
                    progress:(void (^)(double))progress validator:(NSString *)validator done:(void (^)(id,NSInteger,NSError *))done {
  CHECK([method isEqual:@"GET"] && [path isEqual:@"/api/v1/memo"] && !mutation);
  self.receivedValidator = validator; done(self.responseRows, self.responseStatus, nil); return nil;
}
@end

static void MemoCacheFixtures(NSURL *temporary) {
  NSURL *dir = [temporary URLByAppendingPathComponent:@"account"];
  NSURL *metadata = [dir URLByAppendingPathComponent:@"snapshot.json"];
  LBMemosDiskCache *(^makeCache)(void) = ^{
    LBMemosDiskCache *cache = [[LBMemosDiskCache alloc] initWithBase:@"https://example.invalid" userID:@42];
    [cache setValue:dir forKey:@"root"]; [cache setValue:metadata forKey:@"metadata"];
    [cache setValue:[dir URLByAppendingPathComponent:@"originals"] forKey:@"files"]; return cache;
  };
  NSDictionary *latest = @{@"id":@2,@"creatorId":@42,@"content":@"latest", @"visibility":@"PRIVATE",@"rowStatus":@"NORMAL",
      @"createdTs":@2,@"updatedTs":@2,@"displayTs":@2,@"pinned":@NO,@"resourceList":@[],@"tagList":@[]};
  NSMutableDictionary *older = [latest mutableCopy]; older[@"id"] = @1;
  NSArray *before = @[latest, [older copy]];
  LBMemosDiskCache *cache = makeCache();
  void (^waitForIO)(void (^)(void (^)(NSError *))) = ^(void (^operation)(void (^)(NSError *))) {
    __block BOOL complete = NO;
    operation(^(NSError *e){ CHECK(!e); complete = YES; });
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:4];
    while (!complete && limit.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    CHECK(complete);
  };
  waitForIO(^(void (^done)(NSError *)){ [cache replaceState:@"NORMAL" rows:before validator:@"v1" done:done]; });
  LBMemosDiskCache *cold = makeCache();
  waitForIO(^(void (^done)(NSError *)){ [cold load:done]; });
  CHECK([cold.snapshots[@"NORMAL"] isEqual:before] && [cold.validators[@"NORMAL"] isEqual:@"v1"]);
  OfflineMemos *client = [OfflineMemos new]; [client setValue:cold forKey:@"diskCache"];
  client.responseStatus = 304;
  [client allState:@"NORMAL" text:@"" tag:@"" done:^(NSArray *rows, NSError *e){ CHECK(!e && [rows isEqual:before]); }];
  CHECK([client.receivedValidator isEqual:@"v1"]);
  older[@"content"] = @"edited older memo"; client.responseRows = @[latest, [older copy]]; client.responseStatus = 200;
  [client allState:@"NORMAL" text:@"" tag:@"" done:^(NSArray *rows, NSError *e){ CHECK(!e && [rows.lastObject[@"content"] isEqual:@"edited older memo"]); }];
  CHECK(cold.validators[@"NORMAL"] == nil);
  client.responseRows = @[];
  [client allState:@"NORMAL" text:@"" tag:@"" done:^(NSArray *rows, NSError *e){ CHECK(!e && rows.count == 0); }];
  // The reload queues behind prior snapshot writes, including the empty state.
  LBMemosDiskCache *empty = makeCache();
  waitForIO(^(void (^done)(NSError *)){ [empty load:done]; });
  CHECK([empty.snapshots[@"NORMAL"] isEqual:@[]] && !empty.snapshots[@"ARCHIVED"]);
}

static void EnvFixtures(void) {
  OfflineGit *git = [OfflineGit new]; __block NSString *blob;
  [git checkEnvSinceBlob:nil done:^(NSString *text, NSString *sha, NSError *e){ CHECK(!e && text.length); blob = sha; }];
  [git checkEnvSinceBlob:blob done:^(NSString *text, NSString *sha, NSError *e){ CHECK(!e && !text && [sha isEqual:blob]); }];
  CHECK(git.blobReads == 1);
  NSString *publicText = [LBEnvFile parse:@"PRIVATE_KEY=secret-one\n# secret-two\nPUBLIC_SITE_TITLE='site # title' # secret-three"].publicSnapshotText;
  CHECK(![publicText containsString:@"secret"] && ![publicText containsString:@"PRIVATE_KEY"]);
  CHECK([[[LBEnvFile parse:publicText] valueFor:@"PUBLIC_SITE_TITLE"] isEqual:@"site # title"]);

  NSString *original = @"# untouched comment\r\nexport PUBLIC_SITE_TITLE='first' # keep\r\nPUBLIC_SITE_TITLE=last\r\nPUBLIC_SITE_AUTHOR=author\r\nPUBLIC_SITE_URL=https://example.invalid\r\nPUBLIC_FOOTER_SHOW_RUNTIME=false\r\n";
  LBEnvFile *env = [LBEnvFile parse:original];
  CHECK([[env serialize] isEqual:original]);
  CHECK([[env valueFor:@"PUBLIC_SITE_TITLE"] isEqual:@"last"]);
  CHECK([env validate].count == 0);
  CHECK([env updateValue:@"last" forKey:@"PUBLIC_SITE_TITLE"] == nil);
  CHECK([[env serialize] isEqual:original]);
  CHECK([env updateValue:@"测试 # title" forKey:@"PUBLIC_SITE_TITLE"] == nil);
  CHECK([[[LBEnvFile parse:env.serialize] valueFor:@"PUBLIC_SITE_TITLE"] isEqual:@"测试 # title"]);
  CHECK([env updateValue:@"secret" forKey:@"PRIVATE_TOKEN"] != nil);
  CHECK([env updateValue:@"$EXPAND" forKey:@"PUBLIC_SITE_TITLE"] != nil);
  CHECK([env updateValue:@"line\nbreak" forKey:@"PUBLIC_SITE_TITLE"] != nil);
  CHECK([env updateValue:@"literal\\n" forKey:@"PUBLIC_SITE_TITLE"] != nil);
  CHECK([env updateValue:@"all\"'`quotes" forKey:@"PUBLIC_SITE_TITLE"] != nil);
  CHECK([env updateValue:@"valid \"quote\"" forKey:@"PUBLIC_SITE_TITLE"] == nil);
  CHECK([[[LBEnvFile parse:env.serialize] valueFor:@"PUBLIC_SITE_TITLE"] isEqual:@"valid \"quote\""]);
  NSInteger friend = [env addFriend];
  CHECK(friend == 1);
  CHECK([env.friendIndexes isEqual:@[@1]]);
  CHECK([[env valueFor:@"PUBLIC_FRIEND_1_ENABLED"] isEqual:@"false"]);
  CHECK(env.validate.count == 0); // disabled incomplete friends do not break builds
  [env removeFriend:friend];
  CHECK(env.friendIndexes.count == 0);
  LBEnvFile *bad = [LBEnvFile parse:@"PUBLIC_SITE_TITLE=\"unclosed\n"];
  CHECK([bad updateValue:@"replacement" forKey:@"PUBLIC_SITE_TITLE"] != nil);
}

static void FrontmatterFixtures(void) {
  NSDictionary *meta = @{@"id":@"Fixture00001", @"slug":@"fixture", @"title":@"标题 \"quote\" \\ path",
    @"summary":@"hello\nworld", @"publish":@NO, @"pinned":@YES,
    @"tags":@[@"macOS", @"中文"], @"createdAt":@"2026-01-02T03:04:05Z",
    @"bodyFormat":@"markdown", @"singleSourceVersion":@1, @"custom":@"preserved"};
  NSString *serialized = [LBMdStore serializeFrontmatter:meta body:@"# Body\n\nHello **world**.\n"];
  NSDictionary *parsed = [LBMdStore parseFrontmatterAndBody:serialized];
  for (NSString *key in @[@"id", @"slug", @"title", @"summary", @"tags", @"bodyFormat", @"custom"]) CHECK([parsed[key] isEqual:meta[key]]);
  CHECK(![parsed[@"publish"] boolValue]);
  CHECK([parsed[@"pinned"] boolValue]);
  CHECK([parsed[@"singleSourceVersion"] integerValue] == 1);
  CHECK([parsed[@"markdown"] isEqual:@"# Body\n\nHello **world**.\n"]);
  NSString *html = @"\r\n<div data-key=\"x\">\r\n<p>原始 HTML</p>\r\n</div>";
  NSString *htmlSource = [@"---\r\nid: \"HTMLFixture\"\r\nbodyFormat: \"html\"\r\n---\r\n" stringByAppendingString:html];
  CHECK([[LBMdStore parseFrontmatterAndBody:htmlSource][@"markdown"] isEqual:html]);
  CHECK([[LBMdStore parseFrontmatterAndBody:[LBMdStore serializeFrontmatter:@{@"bodyFormat":@"html"} body:html]][@"markdown"] isEqual:html]);
  CHECK([[LBMdStore parseFrontmatterAndBody:@"plain\r\ntext"][@"markdown"] isEqual:@"plain\r\ntext"]);
  CHECK([[LBMdStore parseFrontmatterAndBody:@"---\nno closing delimiter"][@"markdown"] isEqual:@"---\nno closing delimiter"]);
  NSDictionary *malformed = [LBMdStore parseFrontmatterAndBody:@"---\ntitle: true\nsummary: [a, b]\npublish: [yes]\npinned: [yes]\nsingleSourceVersion: [1]\n---\nbody"];
  CHECK([malformed[@"title"] isEqual:@"true"]);
  CHECK([malformed[@"summary"] isEqual:@"a, b"]);
  CHECK(![malformed[@"publish"] boolValue]);
  CHECK(![malformed[@"pinned"] boolValue]);
  CHECK([malformed[@"singleSourceVersion"] integerValue] == 0);
}

static void PureBoundaryFixtures(void) {
  NSString *id32 = @"0123456789abcdef0123456789abcdef";
  NSDictionary *valid = @{@"id":id32, @"sender":@"user", @"text":@"hello", @"createdAt":@1000, @"sequence":@1};
  LBMessage *message = [LBMessage fromJSON:valid];
  CHECK(message != nil && message.fromVisitor && message.sequence == 1);
  NSMutableDictionary *bad = [valid mutableCopy]; bad[@"sequence"] = @YES;
  CHECK([LBMessage fromJSON:bad] == nil);
  bad = [valid mutableCopy]; bad[@"id"] = @"../bad";
  CHECK([LBMessage fromJSON:bad] == nil);
  bad = [valid mutableCopy]; bad[@"text"] = @"";
  CHECK([LBMessage fromJSON:bad] == nil);
  LBSession *session = [LBSession fromJSON:@{@"sessionId":id32, @"createdAt":@1000, @"expiresAt":@2000,
    @"sequence":@1, @"lastUserSequence":@1, @"last":valid}];
  CHECK(session != nil && [session.shortId isEqual:@"01234567"]);
  CHECK([LBMemoVisibility(@"PRIVATE") isEqual:@"仅自己"]);
  CHECK([LBMemoPlain(@"# Title\n**bold** ![alt](https://example.invalid/a.png)") isEqual:@"Title\nbold [图片]"]);
  CHECK([LBMarkdownToHTML(@"# Hello\n\n**bold**") containsString:@"<strong>bold</strong>"]);
  CHECK([LBHTMLToMarkdown(@"<h1>Title</h1><p>Hello <strong>world</strong></p>") containsString:@"**world**"]);
  NSDictionary *resource = @{@"id":@1, @"creatorId":@2, @"size":@3, @"updatedTs":@4, @"type":@"image/png", @"filename":@"中文.png"};
  NSString *fingerprint = [LBMemosDiskCache fingerprint:resource];
  CHECK(fingerprint.length == 64);
  CHECK([fingerprint isEqual:[LBMemosDiskCache fingerprint:resource]]);
  CHECK([LBMemosDiskCache fingerprint:@{@"id":@YES}] == nil);
  CHECK([LBApplicationSupportURL().lastPathComponent isEqual:@"longBlog"]); // no IO
  // Deliberately do not call LBKeychain or client singletons: no credentials.
}

@interface LBWorkspacePresenter : NSObject <NSFilePresenter>
- (instancetype)initWithURL:(NSURL *)url;
@property (nonatomic) BOOL active;
@end

static void WorkspaceObserverFixture(NSURL *folder) {
  LBWorkspacePresenter *presenter = [[LBWorkspacePresenter alloc] initWithURL:folder];
  presenter.active = YES;
  __block BOOL changed = NO;
  id observer = [NSNotificationCenter.defaultCenter addObserverForName:@"LBWorkspaceFilesDidChange"
      object:folder queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){ changed = YES; }];
  [NSFileCoordinator addFilePresenter:presenter];
  NSURL *url = [folder URLByAppendingPathComponent:@"change.md"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateWritingItemAtURL:url options:0 error:nil
        byAccessor:^(NSURL *file){ [@"external edit" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]; }];
  });
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:5];
  while (!changed && end.timeIntervalSinceNow > 0)
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  [NSFileCoordinator removeFilePresenter:presenter];
  presenter.active = NO;
  [NSNotificationCenter.defaultCenter removeObserver:observer];
  CHECK(changed);
}

static void DashboardFixture(void) {
  // Simulate independent services so this also works offline and with a locked login keychain.
  Method json = class_getClassMethod(LBHTTP.class, @selector(JSON:url:headers:body:done:));
  Method cert = class_getClassMethod(LBHTTP.class, @selector(certificateExpiry:done:));
  Method configured = class_getInstanceMethod(LBGitHub.class, @selector(configured));
  Method head = class_getInstanceMethod(LBGitHub.class, @selector(headCommit:));
  Method env = class_getInstanceMethod(LBGitHub.class, @selector(checkEnvSinceBlob:done:));
  Method hosts = class_getClassMethod(LBStore.class, @selector(certHosts));
  IMP jsonStub = imp_implementationWithBlock(^(id obj, NSString *method, NSURL *url, NSDictionary *headers, NSDictionary *body, void (^done)(id,NSInteger,NSError *)){
    NSDictionary *fixtures = @{@"snapshot.json":@{@"memos":@[@{@"content":@"fixture"}]},
        @"version.json":@{@"checkedAt":@12345}, @"build-info.json":@{@"schemaVersion":@1,@"builtAt":@"2026-01-01T00:00:00Z",@"commit":@"fixture"}};
    CHECK(fixtures[url.lastPathComponent] != nil);
    done(fixtures[url.lastPathComponent],200,nil);
  });
  IMP certStub = imp_implementationWithBlock(^(id obj, NSString *host, void (^done)(NSDate *,NSError *)){ done([NSDate dateWithTimeIntervalSinceNow:864000],nil); });
  IMP configuredStub = imp_implementationWithBlock(^BOOL(id obj){ return YES; });
  IMP headStub = imp_implementationWithBlock(^(id obj, void (^done)(NSDictionary *,NSError *)){ done(@{@"sha":@"fixture"},nil); });
  IMP envStub = imp_implementationWithBlock(^(id obj, NSString *known, void (^done)(NSString *,NSString *,NSError *)){ done(@"PUBLIC_FRIEND_1_NAME=Example", @"fixture", nil); });
  IMP hostsStub = imp_implementationWithBlock(^NSArray *(id obj){ return @[@"fixture.invalid"]; });
  Method methods[] = {json,cert,configured,head,env,hosts};
  IMP stubs[] = {jsonStub,certStub,configuredStub,headStub,envStub,hostsStub};
  IMP originals[6];
  for (int i=0; i<6; i++) originals[i] = method_setImplementation(methods[i],stubs[i]);
  @try {
    LBSiteData *site = [LBSiteData new];
    __block BOOL finished = NO;
    [site refreshDashboardForUserAction:NO done:^{ finished = YES; }];
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!finished && end.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(finished && site.memos.count == 1 && [site.memosVersion[@"checkedAt"] isEqual:@12345]);
    CHECK([LBEnvFile parse:site.envText].friendIndexes.count == 1);
    CHECK([site.head[@"sha"] isEqual:@"fixture"] && [site.build[@"commit"] isEqual:@"fixture"]);
    CHECK([site.certs[@"fixture.invalid"] isKindOfClass:NSDate.class]);
  } @finally {
    for (int i=0; i<6; i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(stubs[i]); }
  }
}

static void WorkspaceFixtures(NSURL *root) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSError *error = nil;
  CHECK([fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]);
  LBMdStore *store = [[LBMdStore alloc] initWithLocalFolderURL:root error:&error];
  CHECK(store != nil && error == nil);
  CHECK(store.listArticles.count == 0);
  NSString *note = @"Fixture00001";
  CHECK([store saveArticleWithId:note title:@"中文 / safe : title" markdown:@"# Fixture\n\nLocal draft\n" summary:@"summary" publish:YES tags:@[@"fixture"] error:&error]);
  NSDictionary *loaded = [store loadArticle:note];
  CHECK(loaded != nil);
  CHECK([loaded[@"markdown"] containsString:@"Local draft"]);
  CHECK(![loaded[@"publish"] boolValue]); // a local save must never publish
  CHECK([loaded[@"createdAt"] longLongValue] > 0);
  CHECK([loaded[@"publishedAt"] longLongValue] == 0);
  CHECK(store.listArticles.count == 1);
  NSURL *articleURL = [NSURL fileURLWithPath:loaded[@"filePath"]];
  CHECK([articleURL.lastPathComponent isEqual:@"index.md"]);
  CHECK([articleURL.path hasPrefix:[root.path stringByAppendingString:@"/"]]);
  CHECK([[store articleDirectoryURLForNote:note].path isEqual:articleURL.URLByDeletingLastPathComponent.path]);
  CHECK([store resourceURLForLocalPath:[note stringByAppendingString:@".md"]] == nil); // asset resolver is intentionally asset-only
  NSURL *index = [[root.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"index"] URLByAppendingPathComponent:@"posts.plist"];
  NSArray *first = [store listArticlesWithIndexAtURL:index];
  CHECK([first isEqual:[store cachedArticleListAtURL:index]]);
  NSDate *mtime = [fm attributesOfItemAtPath:index.path error:nil][NSFileModificationDate];
  CHECK([[store listArticlesWithIndexAtURL:index] isEqual:first]);
  CHECK([mtime isEqual:[fm attributesOfItemAtPath:index.path error:nil][NSFileModificationDate]]);
  // Two independent editors open the same bytes before either saves.
  LBMdStore *second = [[LBMdStore alloc] initWithLocalFolderURL:root error:&error];
  NSString *base = [second loadArticle:note][@"sourceRevision"];
  CHECK(base.length == 64 && [base isEqual:loaded[@"sourceRevision"]]);
  NSDictionary *winner = nil;
  CHECK([store saveArticleWithId:note title:@"First device" markdown:@"version A" summary:nil publish:NO tags:nil expectedRevision:base savedPost:&winner error:&error]);
  CHECK(![winner[@"sourceRevision"] isEqual:base]);
  CHECK([[second loadArticle:note][@"markdown"] containsString:@"version A"]);
  CHECK(![second saveArticleWithId:note title:@"Concurrent draft" markdown:@"version B" summary:nil publish:NO tags:nil expectedRevision:base savedPost:nil error:&error]);
  CHECK(error.code == 409);
  CHECK([[store loadArticle:note][@"sourceRevision"] isEqual:winner[@"sourceRevision"]]);
  NSURL *copies = [[root URLByAppendingPathComponent:@"冲突副本"] URLByAppendingPathComponent:note];
  NSArray *copyFiles = [fm contentsOfDirectoryAtURL:copies includingPropertiesForKeys:nil options:0 error:&error];
  CHECK(copyFiles.count == 1);
  CHECK([[NSString stringWithContentsOfURL:copyFiles.firstObject encoding:NSUTF8StringEncoding error:&error] containsString:@"version B"]);
  CHECK([second saveArticleWithId:note title:@"Second device" markdown:@"version C" summary:nil publish:NO tags:nil expectedRevision:winner[@"sourceRevision"] savedPost:nil error:&error]);
  CHECK([[store loadArticle:note][@"markdown"] containsString:@"version C"]);
  NSString *created = loaded[@"createdAtString"];
  CHECK([store saveArticleWithId:note title:@"Renamed" markdown:@"Changed body\n" summary:nil publish:NO tags:nil error:&error]);
  CHECK([[[store loadArticle:note] objectForKey:@"createdAtString"] isEqual:created]);
  CHECK([[[store listArticlesWithIndexAtURL:index] firstObject][@"title"] isEqual:@"Renamed"]);
  NSURL *other = [root.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"other"];
  [fm createDirectoryAtURL:other withIntermediateDirectories:YES attributes:nil error:nil];
  CHECK([[[LBMdStore alloc] initWithLocalFolderURL:other error:nil] cachedArticleListAtURL:index] == nil);
  CHECK(store.listArticles.count == 1);
  for (NSString *unsafe in @[@"../escape", @"/absolute", @"a/b", @"bad%2Fname", @"bad\\name", @".hidden"]) {
    error = nil;
    CHECK(![store saveArticleWithId:unsafe title:@"unsafe" markdown:@"body" summary:nil publish:NO tags:nil error:&error]);
    CHECK([store loadArticle:unsafe] == nil);
  }
  NSURL *assets = [store assetsFolderForNote:note];
  CHECK(assets != nil);
  NSURL *asset = [assets URLByAppendingPathComponent:@"image.txt"];
  CHECK([@"fixture asset" writeToURL:asset atomically:YES encoding:NSUTF8StringEncoding error:&error]);
  CHECK([store readOnlyAssetURLForNote:note filename:@"image.txt"] != nil);
  CHECK([store resourceURLForLocalPath:[NSString stringWithFormat:@"assets/%@/missing.txt", note]] == nil);
  for (NSString *path in @[@"../escape", @"assets/../../escape", @"%2e%2e/escape", @"assets//bad", @"https://example.invalid/a", @"file:///etc/passwd", @".longblog-sync.json"]) CHECK([store resourceURLForLocalPath:path] == nil);
  NSURL *link = [assets URLByAppendingPathComponent:@"link.txt"];
  CHECK([fm createSymbolicLinkAtPath:link.path withDestinationPath:asset.path error:&error]);
  CHECK([store readOnlyAssetURLForNote:note filename:@"link.txt"] == nil);
  CHECK(!LBProtectLocalURL(link, NULL));
  NSURL *dirLink = [root URLByAppendingPathComponent:@"directory-link"];
  CHECK([fm createSymbolicLinkAtPath:dirLink.path withDestinationPath:assets.path error:&error]);
  error = nil;
  CHECK([[LBMdStore alloc] initWithLocalFolderURL:dirLink error:&error] == nil);
  CHECK(error != nil);
  CHECK(LBProtectLocalURL(asset, &error));
  CHECK(([[fm attributesOfItemAtPath:asset.path error:NULL][NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0600);
  CHECK(LBProtectLocalURL(assets, &error));
  CHECK(([[fm attributesOfItemAtPath:assets.path error:NULL][NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0700);
  WorkspaceObserverFixture(root);
}

int main(void) {
  @autoreleasepool {
    NSURL *temporary = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"longblog-core-fixtures-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    int status = 0;
    @try {
      QuietCredentialFixtures(); DashboardFixture(); EnvFixtures(); FrontmatterFixtures(); PureBoundaryFixtures();
      WorkspaceFixtures([temporary URLByAppendingPathComponent:@"Posts" isDirectory:YES]);
      MemoCacheFixtures(temporary);
      printf("CoreFixtures: %lu assertions passed (offline; temporary workspace only).\n", (unsigned long)checks);
    } @catch (NSException *exception) {
      fprintf(stderr, "CoreFixtures raised %s: %s\n", exception.name.UTF8String, exception.reason.UTF8String);
      status = 1;
    } @finally {
      [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];
    }
    return status;
  }
}
