# macOS 离线阅读器移植说明

## UI 集成 API

```swift
ReaderView(markdown: body, baseDirectory: articleDirectory)
ReaderView(html: htmlBody, baseDirectory: articleDirectory)
ReaderView(markdown: body, baseDirectory: articleDirectory, bodyFormat: .html)
```

`ReaderView` 是 Swift 5 / macOS 14 的 `NSViewRepresentable`。`ReaderView.BodyFormat` 为 `.markdown` / `.html`，默认 `.markdown`；不会根据正文外观猜测格式。`baseDirectory` 默认 `nil`，此时仍离线渲染正文、数学和图表，但不读取用户文件。HTML 与 Markdown 使用相同的净化边界。

必须传 `LBMdStore.articleDirectoryURLForNote` 返回的**单篇文章目录**，不能传整个文库、其父目录或 `assets` 子目录。目录结构是 `index.md` 加 `assets/…`。调用方 LBMdStore 持有安全作用域授权，覆盖 ReaderView 整个可见期；Reader 不自行启动或停止 security-scoped access。视图销毁时关闭文章描述符。正文更新通过 `callAsyncJavaScript(arguments:)` 传结构化对象，不拼接正文为 JavaScript 源码。

如果 UI 的格式字段是 String：`bodyFormat == "html"` 时使用 `ReaderView(html: …)`，否则用 `ReaderView(markdown: …)`，不要把 HTML 文本送入默认 Markdown 分支。

## 文件与打包

本次专属实现：

- `Sources/LongBlog/Reader/ReaderView.swift`：SwiftUI 封装、更新生命周期、原生导航策略。
- `Sources/LongBlog/Reader/ReaderResources.swift`：受限 `WKURLSchemeHandler`、描述符读取与 MIME 边界。
- `Resources/MacReader/index.html`、`reader.css`、`reader.js`：独立 macOS 阅读壳与可信渲染器。
- `tests/test_reader_contract.py`：纯 Python 契约检查及可选 Node 实际解析器测试。
- 本文档。

完整 iOS `resources/Reader` 原样复制到 macOS `Resources/Reader`，保留 vendor、字体、许可证和第三方声明。MacReader 用 `../Reader/vendor/…`，并复用 `../Reader/reader-mermaid.js` 的严格 Mermaid 边界；不加载原 iOS `Reader/index.html` / `reader.js`。没有 CDN、下载或包管理依赖。

构建应递归包含两个 Swift 文件，链接 WebKit / SwiftUI / AppKit / Foundation，资源应保持：

```text
LongBlog.app/Contents/Resources/
  MacReader/index.html
  MacReader/reader.css
  MacReader/reader.js
  Reader/reader-mermaid.js
  Reader/vendor/marked.umd.js
  Reader/vendor/katex.min.js
  Reader/vendor/katex.min.css
  Reader/vendor/mermaid.min.js
  Reader/vendor/fonts/KaTeX_*
  Reader/vendor/…原样保留的许可证与资源…
```

## 安全边界

1. **不授予 WebKit 文件访问**：不调用 `loadFileURL`，不把文库 `file://` URL 暴露给网页。根页面是 `lbmac-resource://app/MacReader/index.html`；app 主机只提供明确列出的可信壳、渲染库和 KaTeX 字体，不能借 app 路径读取文章。
2. **按文章隔离**：文章资源主机为每个根目录生成 `article-UUID`。根改变时重载页面并撤销旧主机，避免旧资源能力或图片缓存跨文章复用。源正文不能直接指定自定义协议 URL。
3. **文件系统约束**：拒绝文章根自身为符号链接。先固定规范父目录，再用 `openat(O_DIRECTORY|O_NOFOLLOW)` 打开文章叶目录；内部每个目录及文件继续 `openat` / `O_NOFOLLOW`，并在读取同一描述符前 `fstat`，只允许 regular file。`O_NONBLOCK` 避免 FIFO 打开阻塞；没有先检查路径后按同一路径另行读取的附件竞态。系统祖先允许预先规范化，文章内部任何 symlink 都拒绝。
4. **路径校验**：仅 GET；逐段解码一次；拒绝 `.` / `..`、空段、斜杠编码、反斜杠、控制字符、残留 `%`、查询、片段、凭据、端口及过长路径。即使前端校验失效，native 仍独立校验和描述符约束。
5. **最小 MIME**：文章只允许 PNG / JPEG / GIF / WebP，并验证文件头；拒绝 SVG、HTML、JS、CSS、PDF、音视频和任意附件下载。单图片上限 24 MiB，可信包资源上限 12 MiB。响应包含 `no-store` 与 `nosniff`；只有公共打包字体允许匿名 CORS，不给文章资源 CORS 授权。
6. **不执行作者 HTML**：Marked 输出和 HTML 原文先进入 inert template，再递归从白名单新建节点；不直接附加原始节点。移除 script、style、iframe、foreignObject、SVG、表单、事件、style、srcset、ping、name/id/data 指令等。保留安全段落、标题、列表、表格、代码、图片与折叠区。代码保持可选择复制；作者 id 被重新生成的标题 id 替代。
7. **CSP**：`default-src 'none'`；脚本仅 `lbmac-resource://app`，无 inline-script / unsafe-eval；connect、media、object、frame、worker、base、form 全禁用。style 的 `unsafe-inline` 仅用于可信 KaTeX / Mermaid 生成样式；作者 style 标签和属性均已删除。图片 data URL 仅由可信 Mermaid SVG 重建器生成，作者 data 图片被拒绝。
8. **无认证网页请求**：使用 nonpersistent 数据存储，不注入凭据、Authorization、cookies 或原生 message bridge。远程图片、字体、音视频、脚本和自动 fetch 全部禁用。页面里的 HTTPS 链接也不交给 WebKit 请求；只有 `.linkActivated` 且主 frame 的 HTTPS 无凭据链接交给 `NSWorkspace.open`。链接清除 ping / target，附 no-referrer；程序点击在 DOM 层取消。
9. **数学与图表**：数学先分词再经过 Marked，避免下标、反斜杠被吞；KaTeX `trust:false`、限制展开次数与尺寸。Mermaid 使用已打包的 strict 验证器，拒绝配置、HTML、外部资源、点击回调；重建安全 SVG 后只以 inert data-image 展示。不调用 `bindFunctions`，保留可展开的完整源码及失败说明。

## 本地图片映射

以 `baseDirectory = …/已发布/文章_NOTE` 为例：

| 正文引用 | 读取位置 |
| --- | --- |
| `./assets/photo.png` 或 `assets/photo.png` | `baseDirectory/assets/photo.png` |
| `/assets/NOTE/photo.png` | `baseDirectory/assets/photo.png` |
| `/trilium-assets/NOTE/photo.png` | 同上，兼容旧前缀 |
| `images/photo.png` | `baseDirectory/images/photo.png` |
| `../别的文章/photo.png`、远程 URL、data URL、伪造自定义协议 | 拒绝 |

canonical 路径中的 NOTE 仅作为语法标签移除，**不会**用于查询其他笔记目录；所有引用最终都限定在传入的一篇文章目录。需要跨笔记图片时，应由 Store 显式复制到本篇 assets 后再引用，不扩展 Reader 访问范围。

## 内容与视觉

暖纸色 / 炭色自适应、响应式正文宽度、系统中文字体、衬线标题、等宽代码、可横向滚动表格与公式。离线 GFM 表格和代码块、HTML 正文、美元 / LaTeX 定界公式、Mermaid 图表均可用。正文先完整附加，图表与字体异步完成，不以图表完成作为首屏条件，也不截断尾文。失败的图表保留原源码；解析失败保留完整原文；大于 4×1024×1024 JavaScript 字符的正文明确提示上限，不静默截断。

## 已运行验证

命令：

```sh
python3 -m unittest discover -s tests -p test_reader_contract.py -v
node --check Resources/MacReader/reader.js
```

结果：6 项测试全部通过。Node 实际执行打包 Marked，覆盖 GFM 表格、代码内美元不误排公式、数学转义、Mermaid 代码和尾文保留、有效图片映射、远程/双编码/遍历/反斜杠/伪造协议/凭据 URL 拒绝，以及 Mermaid 配置与交互攻击拒绝。未安装 Node 时，仅该动态用例跳过，Python 静态检查仍运行。

另使用独立浏览器标签和 localhost 临时测试壳，加载同一套真实脚本，仅将测试 CSP 的 app 脚本/字体来源替换成 self，以便运行 WebKit DOM 冒烟测试：

- Markdown 首次 render：表格 1、KaTeX 1、Mermaid 图片 1、完整图表源码 1、尾文 sentinel 保留。
- 混合恶意 script / 事件 / SVG foreignObject / iframe / javascript 链接 / 远程视频和图片：作者脚本执行计数 0、正文事件属性 0、禁止节点 0、远程图片 0。
- HTML 模式：LaTeX 正常排版，HTML 尾文保留；作者 data 图片、自定义 scheme 图片、作者 id、link ping / target 和带账号密码链接全部移除；安全 HTTPS 链接保留 no-referrer。

这些浏览器验证覆盖实际 DOM 与第三方离线库，不等同于原生 macOS scheme-handler 测试。主代理已确认生产 Reader 在真实 macOS 15 / Xcode 16.4 上完成 arm64、x86_64 编译。当前子代理环境没有 macOS SDK，新增原生集成测试尚需在该 macOS runner 运行；编译成功不等于 WebKit 集成测试通过。

## macOS 必做验收与限制

- 在 macOS 14 真机编译运行；确认自定义协议主页面、KaTeX 字体的 CORS 和 Mermaid 图片在正式 CSP 下加载。
- 传单篇文章根测试真实 PNG、中文空格文件名、丢失图片、假后缀文件、25 MiB 图片、symlink 叶文件 / 中间目录 / 根目录、FIFO，以及编码遍历；除合法图片外均应失败。
- 快速切换文章与正文，确认根更换后不会显示旧图；关闭视图后由 Store 释放 security scope。只改同一路径图片而不改正文时，调用方应触发视图重建或更新正文，否则不会自动监控文件变化。
- 点击安全 HTTPS 链接应只打开系统默认浏览器；WebKit 不加载远程站点；程序点击、http、file、javascript 和带 userinfo 链接均不打开。
- 本实现故意不做远程图片代理、音视频播放、PDF 预览、附件下载、跨文章文件访问、HTML 任意样式或交互、Mermaid 内公式与自定义主题、代码语法着色。此限制是默认离线最小权限边界，不是网络回退缺陷。
- 文件读取有上限但同步执行；非常大的合法图片可能短暂占用主线程。字节上限不等于解码像素上限；极端图片仍可能导致 WebKit 内容进程资源压力，进程退出时 Reader 会重新加载当前正文。
- 文章根被传入后是一项受信任能力；调用方不能把整个文库误传入。任意本地进程若已有修改受信任父目录 / app bundle 的能力，不属于网页作者隔离威胁模型。

## 独立原生 WebKit 集成测试（ReaderSmoke）

新增 `tests/ReaderSmoke.swift`，它**不属于应用发布目标**。仅依赖 Reader 的两个 Swift 源文件以及 AppKit / SwiftUI / WebKit（Foundation、Darwin 由系统 SDK 提供）。需要 macOS 14+ 且有 WindowServer 的登录会话；无在线服务、第三方测试包、生产数据、Keychain 或屏幕录制权限依赖。

测试手工创建 NSApplication、NSWindow 和 `NSHostingView(rootView: ReaderView(...))`；通过公开 NSView 子视图遍历找到实际 WKWebView，以 `callAsyncJavaScript` 每 200ms 检查正式 `lbmac-resource` 页面，不改 CSP、不替换资源协议、不用 localhost。

真实断言覆盖：GFM 表格、KaTeX 节点和已加载的 KaTeX FontFace、已解码的 Mermaid data-image、完整图表源码与尾文、`/assets/smoke-note/pixel.png` 映射到临时 article/assets 并成功解码为 2×2、本篇 assets 内指向根外真实 PNG 的 symlink 被拒绝。还检查作者脚本未执行、事件属性与 iframe/SVG/音视频节点被剥离、无远程图片和 HTTP(S) Resource Timing 条目。

内容通过后，将测试代理包装在**实际生产 WKNavigationDelegate**外，发起一次脚本 HTTPS 导航（`.other`，不是用户链接），等待原委托明确返回 `.cancel`，并确认原 custom-scheme 文档仍在。代理即使发现生产意外放行也会强制取消以避免测试发送网络请求，但此时测试判失败，不把强制取消冒充生产安全策略通过。不发送真实 `.linkActivated`，因此不打开默认浏览器。此测试不是操作系统级网络抓包；覆盖实际生产导航策略及页面公开资源记录。

以下命令在项目根运行，假设 `build/longBlog.app` 已构建。测试 app 必须有自己的 `Contents/Resources`，否则 Bundle.main 会找不到阅读壳：

```sh
APP="$PWD/build/ReaderSmoke.app"
mkdir -p "$APP/Contents/MacOS"
ditto build/longBlog.app/Contents/Resources "$APP/Contents/Resources"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ReaderSmoke</string>
<key>CFBundleIdentifier</key><string>org.longblog.ReaderSmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>ReaderSmoke</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/LongBlog/Reader/ReaderView.swift \
  Sources/LongBlog/Reader/ReaderResources.swift tests/ReaderSmoke.swift \
  -framework SwiftUI -framework AppKit -framework WebKit \
  -o "$APP/Contents/MacOS/ReaderSmoke"
# Optional ad-hoc signing: no signing identity / Keychain certificate required.
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/ReaderSmoke" --screenshot "$PWD/build/reader-smoke.png"
```

也可不传 `--screenshot`；截图使用公开 `WKWebView.takeSnapshot`，只截取测试自己的 WebView。截图请求失败会退出 1。正常输出是一行 `READER_SMOKE {…}` JSON，仅包含布尔断言与固定原因代码，不打印临时目录、URL、正文或系统错误详情。所有断言通过退出 0，失败退出 1，用法错误退出 2；主线程 28 秒断言期限加独立 30 秒硬 watchdog，包含 WebKit/截图卡住时的有界退出。正常完成自动删除本次临时 fixture；硬 watchdog 时可能留下自己的临时目录，不读取或清理其他文件。

当前子代理环境仅验证了内嵌检查 JavaScript 的 Node 语法；**未运行这个原生 harness**。请将 macOS runner 的实际 JSON、退出码、可选 PNG 作为集成测试结果，不把此说明当成已通过的 native 运行记录。

主构建集成可直接调用父代理准备的 `scripts/test_reader.sh`：harness 不硬编码 executable 或 bundle identifier，使用复制的 shipping Info.plist、`Contents/MacOS/longBlog` 和 `--screenshot build/smoke-reader.png` 同样兼容；只需确保 executable 与 Info.plist 一致。此独立 main 不导入生产 App.swift、Core 或 AI，不能加入 shipping 源文件列表。
