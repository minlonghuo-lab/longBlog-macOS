# 0.1.0 预览版验证记录

## 可复核证据

首个完整通过的真实 macOS 工作流：

- [Actions run 43635383213](https://github.com/minlonghuo-lab/longBlog-macOS/actions/runs/43635383213)
- 该次源码：`1939cb0819d1c9969e3ba99c2305ad1c615263ce`
- 环境：GitHub `macos-15`、Xcode 16.4；arm64 原生 runner。
- app 分别以 `arm64-apple-macos14.0`、`x86_64-apple-macos14.0` 从干净对象目录编译，合并并核验 Universal Mach-O。
- 首个全绿 DMG 已下载到本地，并通过其 `SHA256SUMS.txt` 校验。

后续提交扩展五工作区截图与文档；最终版本以成功的标签工作流、Release 附件校验值为准，而不是重复使用早期候选包。

## 已执行

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| Python / Node 源码、资源及安全边界测试 | 12 项通过 | 包含真实打包 Marked 与可执行的路径策略样例；静态源码契约不是 UI 端到端测试 |
| 原生 Objective-C `CoreFixtures` | 103 个断言通过 | dotenv、frontmatter、DTO、临时文章保存/重命名/日期、路径及文件权限；不连接私人服务 |
| 原生 Swift AI fixtures | 12 个端点 + 7 个 SSE 边界用例通过 | 实际解析实现，含中文、EOF、截断、大小上限；不向真实模型发送请求 |
| 原生 WebKit 集成 | 全部断言通过 | 实际 custom scheme、离线库、KaTeX 字体、Mermaid、表格、尾文、本地 PNG、symlink 拒绝、作者脚本/事件/远程资源拒绝、程序网络导航取消 |
| 原生主窗口启动 | 通过并有真实截图 | 通过 LaunchServices 打开已打包 app；不是 HTML 模拟图，也不是设计稿截图 |
| 结构签名 | `codesign --verify --deep --strict` 通过 | ad-hoc 签名，只证明结构完整，不证明 Developer ID 身份或 Apple 公证 |
| 安装镜像 | `hdiutil verify` 通过 | APFS/DMG 校验成功；不能替代目标 Mac 上的 Gatekeeper 与安装体验 |
| 产物下载 | 本地 SHA256 核验通过 | 最终发布包须使用该次 Release 附带的校验值 |

原生阅读器测试创建自己独有的临时目录：合法 PNG 位于文章 `assets/`，另一个图片通过符号链接指向文章目录外。只有前者能显示；测试同时验证页面不执行作者脚本、程序导航不触发网络/浏览器。fixture 不导入用户笔记、不访问 Keychain、不注入服务 Token。

截图是未配置私有服务的真实运行状态，因此某些计数显示 `—`，页面显示配置/权限提示；没有为了贴近设计稿填充伪造的文章或会话。

## 在真实编译/启动中发现并修复

1. `lipo` 的 `-verify_arch` 是变长参数，输入文件必须置于其前；已按真实 Apple 工具修正，而不是只让静态字符串测试通过。
2. 手工生成 bundle 在 CI 首次启动时没有呈现 SwiftUI 主窗口。枚举证实 `NSApp.windows` 为空；现在应用代理显式保证 AppKit + NSHostingView 主窗口的创建、持有与 Dock 重开，不以延长等待或忽略失败掩盖问题。
3. 原生 WebKit 首轮验收中公式/图表通过、本地图片未通过。调整可信父目录的固定方式与文章叶目录的原子 `openat(O_NOFOLLOW)` 校验，兼容 macOS 系统路径别名；根目录及附件后代仍拒绝符号链接。修复后合法 PNG 加载、越界 symlink 拒绝同时通过。
4. 未修改保存不重写日期；保存/重命名后重新解析文章资源目录；设置页明确使用 Application Support 而非 iOS Documents；`.env` 未改字段不重新序列化。

## 尚未证明／仍需用户 Mac 验收

- 未运行 Intel 真机：x86_64 已编译链接和架构检查，但运行时测试是在 arm64 CI 上执行。
- 未运行 macOS 14 真机；最低部署目标为 14.0，实际 CI 系统为 macOS 15。
- 未使用私人后端进行文章发布/下架/撤销、Memos 编辑/归档、留言回复或 `.env` 提交。按钮已接入原协议和确认流程，但真实权限、网络并发和结果未知恢复还需测试仓库验证。
- 未验证升级后的 Keychain ACL、外部目录重启恢复、中文输入法、长文性能、VoiceOver、媒体全格式、真实鼠标/快捷键端到端交互。
- 当前非 App Sandbox，Keychain 独立命名空间；缓存 POSIX 权限不是加密。没有 Developer ID、Apple 公证或自动更新。
- 并非 iOS 全功能等价：永久删除 UI、友链组新增/移除、自动轮询/后台通知集成、磁盘 Memos 草稿恢复、拖放、多窗口独立编辑和 AI 选区操作等差异见 `UI-PORT.md`。

这是有真实编译、原生边界与窗口证据的预览版本，不将“CI 通过”写成“所有生产场景已验收”。
