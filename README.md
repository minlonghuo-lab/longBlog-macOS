# longBlog macOS

[![Build macOS DMG](https://github.com/minlonghuo-lab/longBlog-macOS/actions/workflows/macos.yml/badge.svg)](https://github.com/minlonghuo-lab/longBlog-macOS/actions/workflows/macos.yml)

面向 longBlog 维护者的**原生 macOS 客户端**。不是把网页管理后台套壳，也不是放大的 iPhone 界面：采用 **SwiftUI + AppKit** 重建桌面交互，并以 **Objective-C** 保留 iOS 客户端经过迭代的业务逻辑。

> **0.1.0 预览版**：最低 macOS 14；Apple Silicon / Intel 通用 DMG。编译、原生 fixture 和窗口启动由 GitHub Actions 验证，但不表示所有真实服务、目录权限和交互均已在用户的 Mac 验收。安装包只有 ad-hoc 签名，没有 Developer ID 或 Apple 公证。

- [安装包与预览版](https://github.com/minlonghuo-lab/longBlog-macOS/releases)
- [Actions 构建及产物](https://github.com/minlonghuo-lab/longBlog-macOS/actions/workflows/macos.yml)
- [安装和首次配置](docs/INSTALL.md)
- iOS 来源：[minlonghuo-lab/longBlog-iOS](https://github.com/minlonghuo-lab/longBlog-iOS)，业务基线 `6245c80`（1.0.1 build 2）

## 界面与技术路线

参考用户提供的 [macOS 设计方案](docs/design/README.md)，选定方案一：暖棕底色、桃色强调、原生半透明材质、230pt 侧边栏、列表/详情分栏及卡片仪表盘。设计稿保存于 `docs/design/`；其中截图是**参考稿**，不是本程序实际运行截图，示例统计不会硬编码成在线状态。

![界面设计参考，非实际运行截图](docs/design/images/scheme1-glass-dashboard.png)

选择混合语言，而不是完全重写或 Catalyst：

| 层 | 技术 | 理由 |
| --- | --- | --- |
| 窗口、侧边栏、表单、菜单 | SwiftUI + AppKit | 原生 Mac 交互、文件选择、快捷键与可调整分栏 |
| 文章、GitHub、dotenv、Memos、留言 | Objective-C + Foundation | 复用原有协议与事务防护，避免重新发明同步逻辑 |
| 阅读与图表 | WKWebView + 随包离线资源 | 保留 Markdown/KaTeX/Mermaid；页面不获取服务凭据 |
| AI 写作辅助 | Swift concurrency + URLSession | 流式预览、取消、超时和大小上限；手动应用 |
| 打包 | Apple clang / swiftc / lipo / hdiutil | 不依赖第三方工程生成器，直接产出通用 `.app` 与 DMG |

原生材质在 macOS 14+ 可用；设计里的“Tahoe 玻璃风”是视觉方向，不承诺在旧系统提供只有新系统才有的 Liquid Glass API。

## 五个工作区

### 仪表盘

文章、公开说说、留言和友链汇总；读取提交、线上构建、镜像心跳、证书信息。缺少配置或请求失败时显示未配置/错误，不把示例数字当实时数据。线上发布仍依赖外部站点流水线。

### 留言

longBlog 终端留言会话、消息及回复、未读状态和归档相关读取。不是通用邮件客户端；macOS 应用内刷新不等于常驻后台或实时服务端推送。

### 文章

本地 Markdown 包、列表/详情/编辑/离线预览、文件附件、草稿和已发布筛选、从 GitHub 同步。

- 复用 `LBMdStore`：按篇目录、附件映射、同步基线和未决事务。
- 暂存发布/下架后审阅，一次提交多个变化；Git ref 更新为 `force:false`。
- 冲突、账号/仓库变更和结果不明时保留恢复信息，不强推、不自动重放发布。
- 撤销是针对确认时冻结的本地待提交选择，不是远端历史回滚；恢复前核验与备份。
- 实际内容快照决定是否修改，切换预览或移动光标不当成正文变化。

默认本地目录位于独立 Application Support 路径，也可选择外部文件夹。首次同步前请备份；客户端操作会真正修改所选目录与已配置的远端内容仓库。

### 说说

复用 **legacy Memos REST** 身份验证、时间线、编辑、可见性、置顶/归档与资源接口。私有缓存按账号隔离。支持范围以实现的 `/api/v1/user/me`、`/api/v1/memo`、数字 ID、`rowStatus` 和 `resourceList` 为准，不能据此宣称兼容任意最新版 Memos。

### 站点配置

从 GitHub 读取 `.env`，按分组编辑，标识修改项，并显式确认后提交到站点内容仓库 `main`。未修改行保持原有文本；写入配置与部署上线是两件事。

### AI 辅助

文章编辑器内生成/润色摘要、润色正文、从文末续写。配置自己的 HTTPS OpenAI-compatible 接口与模型；API Key 保存 Keychain。请求前明确告知发送内容，结果预览后手动应用，不自动发布。暂不提供与 iOS 文本选区完全相同的就地润色/光标续写体验。

具体已实现路径与移植差异见 [UI 移植记录](docs/UI-PORT.md)、[业务层移植记录](docs/CORE-PORT.md)、[阅读器边界](docs/READER-PORT.md)。

## 快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌘K` / `⌘P` | 全局命令面板与快速跳转（编辑器聚焦时 `⌘K` 为插入链接） |
| `⌘N` / `⌘⇧N` | 新建文章 / 写说说 |
| `⌘E` | 切换阅读 / 编辑 |
| `⌘⌥R` / `⌘⌥E` / `⌘⌥P` | 阅读 / 仅编辑 / 编辑 + 实时预览 |
| `⌘⇧F` / `⌘\` | 专注写作工作台 / 显示或隐藏侧边栏 |
| `⌘S` | 保存 / 审阅配置修改 |
| `⌘⇧P` | 审阅待提交文章 |
| `⌘F` | 搜索当前列表（编辑器内为文内查找） |
| `⌘R` | 刷新当前工作区 |
| `⌘1`–`⌘5` | 切换工作区 |
| `⌘,` | 连接设置 |

编辑器格式：`⌘B` 粗体、`⌘I` 斜体、`⌘⇧X` 删除线、`⌘⇧C` 行内代码、`⌘K` 链接、`⌘⇧I` 图片、`⌘⌥1–3` 标题、`⌘'` 引用、`⌘⇧8/7/9` 无序/有序/任务列表、`⌘⇧K` 代码块、`⌘⌥T` 表格、`⌘⌥M` 公式。截图可直接粘贴，文件可拖入编辑器作为附件。

## 构建与 DMG

### GitHub Actions（推荐）

`push main`、Pull Request 和手动 `workflow_dispatch` 均触发 `.github/workflows/macos.yml`：

1. `macos-15` runner，核对 Xcode/Swift 工具链。
2. Python/JavaScript 边界回归；无运行时 npm/SPM 依赖。
3. 清空对象产物，分别为 `arm64` 和 `x86_64` 完整编译，`lipo` 验证双架构。
4. 执行原生业务 fixture 与 AI 端点 fixture（不访问私人服务）。
5. 资源/许可完整性检查、ad-hoc 签名核验、`hdiutil` 生成并校验 DMG。
6. 启动真实原生窗口，生成仪表盘冒烟截图。
7. 上传 DMG + SHA256，以及供验收的 `.app.zip` 与截图。

带 `v*` 标签的构建成功后发布 **GitHub 预览 Release**；普通构建的产物保留 30 天，下载 Actions artifact 通常需要登录 GitHub。预览 Release 的 DMG 可公开下载。

### 本地 Mac

安装 Xcode（含 Command Line Tools）、Python 3、ripgrep，然后在仓库根目录运行：

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash scripts/build.sh
open build/longBlog.app
```

输出 `build/longBlog-0.2.0-universal.dmg` 与 `build/SHA256SUMS.txt`。可设置非秘密参数 `VERSION`、`GITHUB_RUN_NUMBER`；构建无需任何后端 Token、签名证书或 Apple ID。

## 安全与验收边界

- 独立 Bundle ID：`com.huowenlong.longblog.macos`；独立 Keychain 命名空间，不读取 iOS 沙盒或共享手机凭据。
- 当前为非 App Sandbox 桌面应用；选择目录不是隔离整个进程权限的安全沙盒。阅读器仍单独执行路径/导航限制。
- GitHub Token、Owner Key、Memos Token、AI Key 不存进普通配置、源码或构建日志。
- WKWebView 使用临时数据存储、CSP、内容清洗及受控资源 scheme；外部 HTTPS 链接只在用户点击时交给系统。
- 本仓库不包含真实服务凭据、后端、自动部署服务或 Apple SDK。
- CI 不是端到端私人服务验收：没有使用用户数据执行文章发布、留言回复、Memos 编辑/归档或 `.env` 提交。
- 尚需真实 Mac 验收：Gatekeeper/Keychain、授权文件夹重启恢复、中文输入法/撤销、窄窗口/深浅色/VoiceOver、长文图表与附件、真实网络冲突恢复。

## 来源与许可

见 [NOTICE.md](NOTICE.md)。保留上游权利与第三方阅读器/字体许可，不擅自给没有统一许可证的上游代码换许可证。
