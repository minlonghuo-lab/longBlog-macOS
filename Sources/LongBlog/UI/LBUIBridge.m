#import "LBUIBridge.h"
#import "LB.h"
#import "LBMdStore.h"
#import "LBMemos.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSError *UIError(NSString *message) { return [NSError errorWithDomain:@"LongBlog.UI" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
static void Finish(void (^done)(NSDictionary *, NSError *), NSDictionary *result, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(result, error); });
}
static dispatch_queue_t ArticleQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.longblog.mac.ui.article-io", DISPATCH_QUEUE_SERIAL); });
    return q;
}
NSDictionary *LBUIConnectionSettings(void) {
    return @{ @"site":LBStore.siteURL ?: @"", @"repo":LBStore.repo ?: @"", @"hosts":[LBStore.certHosts componentsJoinedByString:@", "],
        @"githubToken":LBGitHub.shared.token ?: @"", @"inboxURL":LBAPI.shared.baseURL ?: @"", @"inboxToken":LBAPI.shared.ownerKey ?: @"",
        @"memosURL":LBMemosClient.shared.baseURL ?: @"", @"memosToken":LBMemosClient.shared.token ?: @"", @"folder":LBMdStore.shared.folderDisplayName ?: @"Posts" };
}
static NSDictionary *Message(LBMessage *m) {
    return @{ @"id":m.mid ?: @"", @"text":m.text ?: @"", @"visitor":@([m fromVisitor]), @"createdAt":@(m.createdAt), @"sequence":@(m.sequence), @"pending":@(m.pending), @"failed":@(m.failed) };
}
static NSArray *Sessions(NSArray<LBSession *> *rows) {
    NSMutableArray *result = [NSMutableArray array];
    for (LBSession *s in rows) [result addObject:@{ @"id":s.sessionId, @"title":s.shortId, @"createdAt":@(s.createdAt), @"expiresAt":@(s.expiresAt), @"archived":@(s.archived), @"lastUserSequence":@(s.lastUserSequence), @"unread":@([LBSync.shared isUnread:s]), @"last":s.last ? Message(s.last) : @{} }];
    return result;
}
static NSDictionary *EnvResult(NSString *text, NSString *sha, NSString *repo) {
    LBEnvFile *f = [LBEnvFile parse:text];
    NSMutableArray *sections = [NSMutableArray array];
    for (NSDictionary *original in f.sections) {
        NSMutableDictionary *s = [original mutableCopy]; NSMutableArray *keys = [s[@"keys"] mutableCopy];
        if ([s[@"friends"] boolValue]) for (NSNumber *index in f.friendIndexes) {
            NSString *prefix = [NSString stringWithFormat:@"PUBLIC_FRIEND_%@_", index];
            for (LBEnvLine *line in f.lines) if ([line.key hasPrefix:prefix]) [keys addObject:@{@"key":line.key, @"help":@"友链公开配置"}];
        }
        for (NSUInteger i = 0; i < keys.count; i++) {
            NSMutableDictionary *key = [keys[i] mutableCopy]; key[@"label"] = [LBEnvFile labelFor:key[@"key"]]; key[@"boolean"] = @([LBEnvFile isBoolean:key[@"key"]]); keys[i] = key;
        }
        s[@"keys"] = keys; [sections addObject:s];
    }
    return @{@"text":text, @"sha":sha ?: @"", @"repo":repo ?: @"", @"values":f.values, @"sections":sections};
}
void LBUIRequest(NSString *op, NSDictionary *a, void (^done)(NSDictionary *, NSError *)) {
    NSCAssert(NSThread.isMainThread, @"UI requests must start on main");
    LBMdStore *store = LBMdStore.shared;
    if ([op isEqual:@"posts.list"] || [op isEqual:@"posts.load"] || [op isEqual:@"posts.new"] || [op isEqual:@"posts.save"] || [op isEqual:@"posts.stage"] || [op isEqual:@"posts.import"]) {
        dispatch_async(ArticleQueue(), ^{
            NSError *error = nil; NSDictionary *result = nil;
            if ([op isEqual:@"posts.list"]) { NSArray *rows = store.listArticles; result = @{@"rows":rows, @"staged":[store stagedArticlesForArticles:rows], @"folder":store.folderDisplayName}; }
            if ([op isEqual:@"posts.new"]) result = @{@"id":store.generateUniqueNoteID, @"title":@"", @"markdown":@"", @"summary":@"", @"publish":@NO, @"tags":@[]};
            if ([op isEqual:@"posts.load"]) {
                NSMutableDictionary *row = [[store loadArticle:a[@"id"]] mutableCopy];
                if (row) { NSURL *dir = [store articleDirectoryURLForNote:a[@"id"]]; if (dir) row[@"directory"] = dir; result = row; }
                else error = UIError(@"文章无法读取；原文件未修改。");
            }
            if ([op isEqual:@"posts.save"]) {
                BOOL ok = [store saveArticleWithId:a[@"id"] title:a[@"title"] markdown:a[@"markdown"] summary:a[@"summary"] publish:[a[@"publish"] boolValue] tags:a[@"tags"] error:&error];
                if (ok) {
                    NSMutableDictionary *row = [[store loadArticle:a[@"id"]] mutableCopy];
                    NSURL *directory = [store articleDirectoryURLForNote:a[@"id"]];
                    if (directory) row[@"directory"] = directory;
                    result = row;
                    if (!row) error = UIError(@"文件已保存，但重新读取失败；请检查工作区后刷新。");
                }
            }
            if ([op isEqual:@"posts.stage"]) {
                BOOL ok = [a[@"publish"] boolValue] ? [store stagePublishArticle:a[@"id"] error:&error] : [store stageUnpublishArticle:a[@"id"] error:&error];
                if (ok) result = @{};
            }
            if ([op isEqual:@"posts.import"]) {
                NSURL *source = a[@"url"]; BOOL access = [source startAccessingSecurityScopedResource];
                NSNumber *size = nil; [source getResourceValue:&size forKey:NSURLFileSizeKey error:&error];
                if (!error && (!size || size.unsignedLongLongValue > 32*1024*1024)) error = UIError(@"附件必须是 32 MiB 以内的常规文件。");
                NSNumber *regular = nil; [source getResourceValue:&regular forKey:NSURLIsRegularFileKey error:&error];
                if (!error && !regular.boolValue) error = UIError(@"只能导入常规文件。");
                if (!error) {
                    NSString *filename = [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, source.lastPathComponent];
                    NSURL *dir = [store assetsFolderForNote:a[@"id"]]; NSURL *target = [dir URLByAppendingPathComponent:filename];
                    if ([[NSFileManager defaultManager] copyItemAtURL:source toURL:target error:&error]) result = @{@"path":[NSString stringWithFormat:@"/assets/%@/%@", a[@"id"], filename], @"filename":source.lastPathComponent, @"directory":[store articleDirectoryURLForNote:a[@"id"]] ?: dir};
                }
                if (access) [source stopAccessingSecurityScopedResource];
            }
            Finish(done, result, error);
        }); return;
    }
    if ([op isEqual:@"posts.sync"]) { [store syncFromGitHub:^(NSError *e){ Finish(done, @{}, e); }]; return; }
    if ([op isEqual:@"posts.commit"]) { [store commitStagedArticles:a[@"rows"] message:a[@"message"] done:^(NSError *e){ Finish(done, @{}, e); }]; return; }
    if ([op isEqual:@"posts.revert"]) { [store revertStagedArticles:a[@"rows"] done:^(NSError *e){ Finish(done, @{}, e); }]; return; }
    if ([op isEqual:@"site.refresh"]) {
        [LBSiteData.shared refreshAll:^{
            LBSiteData *s = LBSiteData.shared; NSMutableDictionary *errors = [NSMutableDictionary dictionary];
            [s.errors enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSError *e, BOOL *stop){ errors[k] = e.localizedDescription; }];
            NSMutableDictionary *certs = [NSMutableDictionary dictionary];
            [s.certs enumerateKeysAndObjectsUsingBlock:^(NSString *k, id value, BOOL *stop){ certs[k] = [value isKindOfClass:NSError.class] ? [value localizedDescription] : value; }];
            Finish(done, @{@"postsCount":s.posts ? @(s.posts.count) : NSNull.null, @"publicMemosCount":s.memos ? @(s.memos.count) : NSNull.null,
                @"head":s.head ?: @{}, @"build":s.build ?: @{}, @"memosVersion":s.memosVersion ?: @{}, @"certs":certs, @"errors":errors,
                @"deployState":[s deployState:nil pending:nil]}, nil);
        }]; return;
    }
    if ([op isEqual:@"inbox.list"]) {
        if (!LBAPI.shared.configured) { Finish(done,nil,UIError(@"请在连接设置填写留言接口与站长密钥。")); return; }
        [LBSync.shared refresh:^(BOOL fresh){ Finish(done, @{@"rows":Sessions(LBSync.shared.sessions), @"unread":@(LBSync.shared.unreadCount)}, LBSync.shared.lastError); }]; return;
    }
    if ([op isEqual:@"inbox.archives"]) { [LBAPI.shared fetchArchivedSessions:a[@"cursor"] done:^(NSArray *rows, NSString *cursor, NSError *e){ Finish(done,@{@"rows":Sessions(rows ?: @[]), @"cursor":cursor ?: @""},e); }]; return; }
    if ([op isEqual:@"inbox.messages"]) {
        void (^completion)(NSArray *, NSInteger, NSError *) = ^(NSArray *rows, NSInteger cursor, NSError *e) {
            NSMutableArray *messages = [NSMutableArray array]; for (LBMessage *m in rows) [messages addObject:Message(m)];
            Finish(done, @{@"rows":messages, @"cursor":@(cursor)},e);
        };
        if ([a[@"archived"] boolValue]) [LBAPI.shared fetchArchivedMessages:a[@"id"] after:[a[@"cursor"] integerValue] done:completion];
        else [LBAPI.shared fetchMessages:a[@"id"] after:[a[@"cursor"] integerValue] done:completion]; return;
    }
    if ([op isEqual:@"inbox.read"]) { [LBSync.shared markRead:a[@"id"] upTo:[a[@"sequence"] integerValue]]; Finish(done,@{},nil); return; }
    if ([op isEqual:@"inbox.contact"]) { [LBAPI.shared fetchSessionContact:a[@"id"] done:^(NSDictionary *contact, NSError *e){ Finish(done,contact ?: @{},e); }]; return; }
    if ([op isEqual:@"inbox.reply"]) { [LBAPI.shared reply:a[@"id"] messageId:a[@"messageID"] text:a[@"text"] done:^(LBMessage *m, NSError *e){ Finish(done,m ? Message(m) : nil,e); }]; return; }
    LBMemosClient *memos = LBMemosClient.shared;
    if ([op isEqual:@"memos.validate"]) { [memos validate:^(NSDictionary *user, NSError *e){ Finish(done,user,e); }]; return; }
    if ([op isEqual:@"memos.list"]) { [memos listState:a[@"state"] text:a[@"text"] ?: @"" tag:@"" offset:[a[@"offset"] unsignedIntegerValue] done:^(NSArray *rows, BOOL more, NSError *e){ Finish(done,@{@"rows":rows ?: @[], @"more":@(more)},e); }]; return; }
    if ([op isEqual:@"memos.save"]) { [memos saveOriginal:a[@"original"] content:a[@"content"] visibility:a[@"visibility"] resourceIDs:a[@"resourceIDs"] done:^(NSDictionary *row, NSError *e){ Finish(done,row,e); }]; return; }
    if ([op isEqual:@"memos.update"]) { [memos updateMemo:a[@"original"] fields:a[@"fields"] done:^(NSDictionary *row, NSError *e){ Finish(done,row,e); }]; return; }
    if ([op isEqual:@"memos.upload"]) {
        NSURL *url = a[@"url"]; BOOL access = [url startAccessingSecurityScopedResource];
        UTType *type = [UTType typeWithFilenameExtension:url.pathExtension];
        [memos uploadFile:url filename:url.lastPathComponent type:type.preferredMIMEType ?: @"application/octet-stream" progress:nil done:^(NSDictionary *resource, NSError *e){ if (access) [url stopAccessingSecurityScopedResource]; Finish(done,resource,e); }]; return;
    }
    if ([op isEqual:@"memos.download"]) { [memos downloadResource:a[@"resource"] done:^(NSURL *url, NSError *e){ Finish(done,url ? @{@"url":url} : nil,e); }]; return; }
    if ([op isEqual:@"env.load"]) {
        if (!LBGitHub.shared.configured) { Finish(done,nil,UIError(@"请先配置 GitHub 仓库与令牌。")); return; }
        LBGitHub *client = [[LBGitHub alloc] initWithRepository:LBStore.repo];
        [client getFile:@".env" ref:@"main" done:^(NSString *text, NSString *sha, NSError *e){ Finish(done,text ? EnvResult(text,sha,client.repository) : nil,e); }]; return;
    }
    if ([op isEqual:@"env.preview"] || [op isEqual:@"env.save"]) {
        LBEnvFile *file = [LBEnvFile parse:a[@"text"]]; NSString *failure = nil;
        NSDictionary *values = a[@"values"];
        for (NSString *key in values) { if ([[file valueFor:key] isEqual:values[key]]) continue; failure = [file updateValue:values[key] forKey:key]; if (failure) break; }
        if (!failure && file.validate.count) failure = [file.validate componentsJoinedByString:@"\n"];
        if (failure) { Finish(done,nil,UIError(failure)); return; }
        NSString *edited = file.serialize;
        if ([op isEqual:@"env.preview"]) { Finish(done,EnvResult(edited,a[@"sha"],a[@"repo"]),nil); return; }
        if (![a[@"repo"] isEqual:LBStore.repo] || ![a[@"sha"] length]) { Finish(done,nil,UIError(@"仓库已变化或缺少基准 SHA，请重新载入配置。")); return; }
        LBGitHub *client = [[LBGitHub alloc] initWithRepository:a[@"repo"]];
        [client putFile:@".env" text:edited sha:a[@"sha"] message:a[@"message"] ?: @"Update site configuration from longBlog macOS" done:^(NSString *sha, NSError *e){
            if (sha && !e) [LBSiteData.shared didCommitEnv:edited commit:sha]; Finish(done,sha ? @{@"commit":sha, @"text":edited} : nil,e);
        }]; return;
    }
    if ([op isEqual:@"settings.folder"]) {
        NSError *error = nil; BOOL ok = [store setFolderURL:a[@"url"] error:&error]; Finish(done,ok ? @{} : nil,error); return;
    }
    if ([op isEqual:@"settings.save"]) {
        NSString *site = [a[@"site"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *repo = [a[@"repo"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSURL *siteURL = [NSURL URLWithString:site];
        if (site.length && (![siteURL.scheme isEqual:@"https"] || !siteURL.host.length || siteURL.user || siteURL.password || siteURL.query || siteURL.fragment)) { Finish(done,nil,UIError(@"站点 URL 必须是没有内嵌凭据的 HTTPS 地址。")); return; }
        if (repo.length && [repo rangeOfString:@"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$" options:NSRegularExpressionSearch].location == NSNotFound) { Finish(done,nil,UIError(@"仓库格式应为 owner/repository。")); return; }
        for (NSString *key in @[@"inboxURL",@"memosURL"]) {
            NSString *value = a[key]; NSURL *url = [NSURL URLWithString:value];
            if (value.length && (![url.scheme isEqual:@"https"] || !url.host.length || url.user || url.password || url.query || url.fragment)) { Finish(done,nil,UIError(@"服务接口必须使用 HTTPS，不含凭据、查询参数或片段。")); return; }
        }
        for (NSString *key in @[@"githubToken",@"inboxToken",@"memosToken"]) if ([a[key] rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) { Finish(done,nil,UIError(@"令牌不能包含空格或换行。")); return; }
        for (NSString *item in [a[@"hosts"] componentsSeparatedByString:@","]) {
            NSString *host = [item stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (host.length && (host.length > 253 || [host rangeOfString:@"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$" options:NSRegularExpressionSearch].location == NSNotFound)) { Finish(done,nil,UIError(@"证书监控只接受逗号分隔的域名。")); return; }
        }
        if (![memos configureBaseURL:a[@"memosURL"] token:a[@"memosToken"]]) { Finish(done,nil,UIError(@"Memos 钥匙串保存失败；请检查签名和钥匙串权限。")); return; }
        LBAPI.shared.ownerKey = a[@"inboxToken"]; LBGitHub.shared.token = a[@"githubToken"];
        if (![LBAPI.shared.ownerKey ?: @"" isEqual:a[@"inboxToken"]] || ![LBGitHub.shared.token ?: @"" isEqual:a[@"githubToken"]]) { Finish(done,nil,UIError(@"钥匙串保存失败，部分其他连接可能已保存。请检查钥匙串权限。")); return; }
        LBAPI.shared.baseURL = a[@"inboxURL"]; LBStore.siteURL = site; LBStore.repo = repo; [LBStore setCertHosts:a[@"hosts"]];
        [LBSync.shared resetBaseline]; [LBSiteData.shared resetConnection]; Finish(done,@{},nil); return;
    }
    Finish(done,nil,UIError([@"未实现的 UI 操作：" stringByAppendingString:op]));
}
