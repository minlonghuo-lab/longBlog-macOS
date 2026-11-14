// Native macOS fixture executable. No network, real Keychain, standard defaults,
// singleton stores, or user note folders are accessed. All IO is temporary.
#import "LongBlog-Bridging-Header.h"
#include <stdio.h>
#include <stdlib.h>

static NSUInteger checks;
#define CHECK(...) do { checks++; if (!(__VA_ARGS__)) { \
  fprintf(stderr, "Core fixture failed at %s:%d: %s\n", __FILE__, __LINE__, #__VA_ARGS__); abort(); \
} } while (0)

static void EnvFixtures(void) {
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
  NSString *created = loaded[@"createdAtString"];
  CHECK([store saveArticleWithId:note title:@"Renamed" markdown:@"Changed body\n" summary:nil publish:NO tags:nil error:&error]);
  CHECK([[[store loadArticle:note] objectForKey:@"createdAtString"] isEqual:created]);
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
}

int main(void) {
  @autoreleasepool {
    NSURL *temporary = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"longblog-core-fixtures-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    int status = 0;
    @try {
      EnvFixtures(); FrontmatterFixtures(); PureBoundaryFixtures();
      WorkspaceFixtures([temporary URLByAppendingPathComponent:@"Posts" isDirectory:YES]);
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
