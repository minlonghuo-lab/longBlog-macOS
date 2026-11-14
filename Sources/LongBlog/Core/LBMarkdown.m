#import "LBMarkdown.h"

NSString *LBMarkdownToHTML(NSString *md) {
  if (!md.length) return @"<p></p>";
  NSArray<NSString *> *lines = [md componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
  NSMutableString *html = [NSMutableString new];
  BOOL inCode = NO;
  NSString *codeLang = @"";
  NSMutableString *codeBuf = [NSMutableString new];
  __block BOOL inList = NO;
  __block BOOL orderedList = NO;

  void (^closeListIfNeeded)(void) = ^{
    if (inList) {
      [html appendString:orderedList ? @"</ol>\n" : @"</ul>\n"];
      inList = NO;
      orderedList = NO;
    }
  };

  for (NSString *rawLine in lines) {
    NSString *line = rawLine;

    // Code block toggle
    if ([line hasPrefix:@"```"]) {
      closeListIfNeeded();
      if (!inCode) {
        inCode = YES;
        codeLang = [line substringFromIndex:3];
        codeLang = [codeLang stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [codeBuf setString:@""];
      } else {
        inCode = NO;
        NSString *escaped = [codeBuf stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
        escaped = [escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
        escaped = [escaped stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
        if (codeLang.length) {
          [html appendFormat:@"<pre><code class=\"language-%@\">%@</code></pre>\n", codeLang, escaped];
        } else {
          [html appendFormat:@"<pre><code>%@</code></pre>\n", escaped];
        }
      }
      continue;
    }

    if (inCode) {
      [codeBuf appendFormat:@"%@\n", line];
      continue;
    }

    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) {
      closeListIfNeeded();
      continue;
    }

    // Horizontal Rule
    if ([trimmed isEqualToString:@"---"] || [trimmed isEqualToString:@"***"]) {
      closeListIfNeeded();
      [html appendString:@"<hr />\n"];
      continue;
    }

    // Headings
    if ([trimmed hasPrefix:@"# "]) {
      closeListIfNeeded();
      [html appendFormat:@"<h1>%@</h1>\n", [trimmed substringFromIndex:2]];
      continue;
    }
    if ([trimmed hasPrefix:@"## "]) {
      closeListIfNeeded();
      [html appendFormat:@"<h2>%@</h2>\n", [trimmed substringFromIndex:3]];
      continue;
    }
    if ([trimmed hasPrefix:@"### "]) {
      closeListIfNeeded();
      [html appendFormat:@"<h3>%@</h3>\n", [trimmed substringFromIndex:4]];
      continue;
    }
    if ([trimmed hasPrefix:@"#### "]) {
      closeListIfNeeded();
      [html appendFormat:@"<h4>%@</h4>\n", [trimmed substringFromIndex:5]];
      continue;
    }

    // Blockquote
    if ([trimmed hasPrefix:@"> "]) {
      closeListIfNeeded();
      [html appendFormat:@"<blockquote><p>%@</p></blockquote>\n", [trimmed substringFromIndex:2]];
      continue;
    }

    // Lists
    if ([trimmed hasPrefix:@"- "] || [trimmed hasPrefix:@"* "]) {
      if (!inList || orderedList) {
        closeListIfNeeded();
        inList = YES;
        orderedList = NO;
        [html appendString:@"<ul>\n"];
      }
      [html appendFormat:@"<li>%@</li>\n", [trimmed substringFromIndex:2]];
      continue;
    }

    NSRegularExpression *numRegex = [NSRegularExpression regularExpressionWithPattern:@"^(\\d+)\\.\\s+(.+)$" options:0 error:nil];
    NSTextCheckingResult *match = [numRegex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    if (match) {
      if (!inList || !orderedList) {
        closeListIfNeeded();
        inList = YES;
        orderedList = YES;
        [html appendString:@"<ol>\n"];
      }
      NSString *itemContent = [trimmed substringWithRange:[match rangeAtIndex:2]];
      [html appendFormat:@"<li>%@</li>\n", itemContent];
      continue;
    }

    // Regular paragraph
    closeListIfNeeded();

    // Inline formatting: Images, links, bold, italic, code
    NSMutableString *p = [trimmed mutableCopy];
    // Inline images: ![alt](url) -> <figure class="image"><img src="url" alt="alt" /></figure>
    NSRegularExpression *imgRegex = [NSRegularExpression regularExpressionWithPattern:@"!\\[([^\\]]*)\\]\\(([^\\)]+)\\)" options:0 error:nil];
    [imgRegex replaceMatchesInString:p options:0 range:NSMakeRange(0, p.length) withTemplate:@"<figure class=\"image\"><img src=\"$2\" alt=\"$1\" /></figure>"];

    // Inline links: [text](url) -> <a href="url">text</a>
    NSRegularExpression *linkRegex = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\]]+)\\]\\(([^\\)]+)\\)" options:0 error:nil];
    [linkRegex replaceMatchesInString:p options:0 range:NSMakeRange(0, p.length) withTemplate:@"<a href=\"$2\">$1</a>"];

    // Bold: **text** -> <strong>text</strong>
    NSRegularExpression *boldRegex = [NSRegularExpression regularExpressionWithPattern:@"\\*\\*([^\\*]+)\\*\\*" options:0 error:nil];
    [boldRegex replaceMatchesInString:p options:0 range:NSMakeRange(0, p.length) withTemplate:@"<strong>$1</strong>"];

    // Italic: *text* -> <em>text</em>
    NSRegularExpression *italicRegex = [NSRegularExpression regularExpressionWithPattern:@"\\*([^\\*]+)\\*" options:0 error:nil];
    [italicRegex replaceMatchesInString:p options:0 range:NSMakeRange(0, p.length) withTemplate:@"<em>$1</em>"];

    // Strikethrough: ~~text~~ -> <del>text</del>
    NSRegularExpression *delRegex = [NSRegularExpression regularExpressionWithPattern:@"~~([^~]+)~~" options:0 error:nil];
    [delRegex replaceMatchesInString:p options:0 range:NSMakeRange(0, p.length) withTemplate:@"<del>$1</del>"];

    // Inline code: `code` -> <code>code</code>
    NSRegularExpression *codeRegex = [NSRegularExpression regularExpressionWithPattern:@"`([^`]+)`" options:0 error:nil];
    [codeRegex replaceMatchesInString:p options:0 range:NSMakeRange(0, p.length) withTemplate:@"<code>$1</code>"];

    [html appendFormat:@"<p>%@</p>\n", p];
  }

  closeListIfNeeded();
  return html;
}

/// Converts semantic HTML back to readable Markdown for legacy local drafts.
NSString *LBHTMLToMarkdown(NSString *html) {
  if (!html.length) return @"";
  NSMutableString *md = [html mutableCopy];

  // Headings
  for (int i = 4; i >= 1; i--) {
    NSString *hashes = [@"" stringByPaddingToLength:i withString:@"#" startingAtIndex:0];
    NSString *startPattern = [NSString stringWithFormat:@"<h%d[^>]*>", i];
    NSString *endPattern = [NSString stringWithFormat:@"</h%d>", i];
    NSRegularExpression *r1 = [NSRegularExpression regularExpressionWithPattern:startPattern options:NSRegularExpressionCaseInsensitive error:nil];
    [r1 replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:[NSString stringWithFormat:@"\n\n%@ ", hashes]];
    NSRegularExpression *r2 = [NSRegularExpression regularExpressionWithPattern:endPattern options:NSRegularExpressionCaseInsensitive error:nil];
    [r2 replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"\n\n"];
  }

  // Pre / Code blocks
  NSRegularExpression *preRegex = [NSRegularExpression regularExpressionWithPattern:@"<pre><code(?: class=\"language-([^\"]+)\")?>([\\s\\S]*?)</code></pre>" options:NSRegularExpressionCaseInsensitive error:nil];
  [preRegex replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"\n\n```$1\n$2\n```\n\n"];

  // Blockquotes
  NSRegularExpression *bqRegex = [NSRegularExpression regularExpressionWithPattern:@"<blockquote[^>]*>([\\s\\S]*?)</blockquote>" options:NSRegularExpressionCaseInsensitive error:nil];
  [bqRegex replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"\n\n> $1\n\n"];

  // Paragraphs
  NSRegularExpression *pStart = [NSRegularExpression regularExpressionWithPattern:@"<p[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
  [pStart replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"\n\n"];
  NSRegularExpression *pEnd = [NSRegularExpression regularExpressionWithPattern:@"</p>" options:NSRegularExpressionCaseInsensitive error:nil];
  [pEnd replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"\n\n"];

  // List items
  NSRegularExpression *liRegex = [NSRegularExpression regularExpressionWithPattern:@"<li[^>]*>([\\s\\S]*?)</li>" options:NSRegularExpressionCaseInsensitive error:nil];
  [liRegex replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"\n- $1"];

  // Images in figure or plain
  NSRegularExpression *figImgRegex = [NSRegularExpression regularExpressionWithPattern:@"<figure[^>]*>\\s*<img[^>]+src=\"([^\"]+)\"[^>]*(?:alt=\"([^\"]*)\")?[^>]*>\\s*</figure>" options:NSRegularExpressionCaseInsensitive error:nil];
  [figImgRegex replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"\n\n![$2]($1)\n\n"];

  NSRegularExpression *imgRegex = [NSRegularExpression regularExpressionWithPattern:@"<img[^>]+src=\"([^\"]+)\"[^>]*(?:alt=\"([^\"]*)\")?[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
  [imgRegex replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"![$2]($1)"];

  // Links
  NSRegularExpression *aRegex = [NSRegularExpression regularExpressionWithPattern:@"<a[^>]+href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>" options:NSRegularExpressionCaseInsensitive error:nil];
  [aRegex replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"[$2]($1)"];

  // Bold & Italic & Code
  NSRegularExpression *bRegex = [NSRegularExpression regularExpressionWithPattern:@"<(?:strong|b)[^>]*>([\\s\\S]*?)</(?:strong|b)>" options:NSRegularExpressionCaseInsensitive error:nil];
  [bRegex replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"**$1**"];

  NSRegularExpression *iRegex = [NSRegularExpression regularExpressionWithPattern:@"<(?:em|i)[^>]*>([\\s\\S]*?)</(?:em|i)>" options:NSRegularExpressionCaseInsensitive error:nil];
  [iRegex replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"*$1*"];

  NSRegularExpression *cRegex = [NSRegularExpression regularExpressionWithPattern:@"<code[^>]*>([\\s\\S]*?)</code>" options:NSRegularExpressionCaseInsensitive error:nil];
  [cRegex replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"`$1`"];

  // Clean any remaining tags
  NSRegularExpression *remTag = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
  [remTag replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@""];

  // Unescape HTML entities
  [md replaceOccurrencesOfString:@"&nbsp;" withString:@" " options:0 range:NSMakeRange(0, md.length)];
  [md replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, md.length)];
  [md replaceOccurrencesOfString:@"&lt;" withString:@"<" options:0 range:NSMakeRange(0, md.length)];
  [md replaceOccurrencesOfString:@"&gt;" withString:@">" options:0 range:NSMakeRange(0, md.length)];
  [md replaceOccurrencesOfString:@"&quot;" withString:@"\"" options:0 range:NSMakeRange(0, md.length)];

  // Clean extra blank lines
  NSRegularExpression *multiLines = [NSRegularExpression regularExpressionWithPattern:@"\n{3,}" options:0 error:nil];
  [multiLines replaceMatchesInString:md options:0 range:NSMakeRange(0, md.length) withTemplate:@"\n\n"];

  return [md stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
