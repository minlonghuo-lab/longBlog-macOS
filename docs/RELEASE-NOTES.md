# longBlog macOS 0.1.0 — 预览版

首个独立 macOS 移植版本，以 longBlog-iOS `6245c808b4d612d656e86b87f69125fa7331d1c2` 为业务基线。

- SwiftUI / AppKit 原生窗口、五入口侧边栏与暖棕玻璃风，依据随仓库保存的设计草稿。
- Objective-C 复用文章目录、暂存/批量提交、冲突/未决事务保护、dotenv、GitHub、legacy Memos、终端留言协议。
- 离线 WebKit Markdown、数学与图表渲染，受控本地资源与外链处理。
- AI 流式生成、取消、预览与手动应用。
- Apple Silicon / Intel 通用 DMG；干净编译、原生边界 fixture、包完整性检查与窗口启动冒烟测试由 GitHub Actions 执行。

## 重要说明

这是需要实际 Mac 验收的**预览版本**，不是宣称已完成所有 iOS 功能和全部交互验收的正式版。具体移植差异见仓库 `docs/UI-PORT.md`、`docs/CORE-PORT.md`、`docs/READER-PORT.md`。

程序仅作 ad-hoc 签名，**没有 Developer ID 签名及 Apple 公证**；首次打开可能需要系统设置授权。不要全局关闭 Gatekeeper。安装方法见 `docs/INSTALL.md`。

客户端不包含站点后端、Memos 服务、持续消息推送或部署服务。Token 和 API Key 需要使用者自行配置；请先连接测试仓库，备份已有文章。CI 未使用真实私人服务执行回复、发布、删除或站点配置提交。设计目录中的截图是参考稿，不是实际运行截图；实际 CI 窗口截图在 Actions 的 smoke artifact 中。
