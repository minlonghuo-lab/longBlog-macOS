# 安装与首次运行

## 系统要求

- macOS 14 Sonoma 或更新版本。
- 同一 DMG 内含 arm64 / x86_64 通用程序，可用于 Apple Silicon 和受支持的 Intel Mac。
- 网络功能需要你自己的 longBlog 服务、GitHub 内容仓库、legacy Memos 或 AI 接口配置。

## 安装

1. 从本仓库 Releases（预览版本）或一次成功的 GitHub Actions 运行中下载 DMG。
2. 如需核验：在下载目录运行 `shasum -a 256 longBlog-*-universal.dmg`，与同时下载的 `SHA256SUMS.txt` 比较。
3. 打开 DMG，把 `longBlog.app` 拖到 `Applications`。
4. 预览版只有 ad-hoc 结构签名，**没有 Developer ID 签名或 Apple 公证**。系统可能提示无法验证开发者。
5. 先尝试打开一次，然后前往「系统设置 → 隐私与安全性」，核对应用来源后使用「仍要打开」。不要关闭系统的 Gatekeeper 或全局降低安全设置。

首次访问 Keychain 或外部文件夹时，请根据系统提示授权。不要把 iOS 版的证书、描述文件、配对材料或 Token 提交到源码仓库。

## 首次配置

使用 `⌘,` 打开连接设置，按需配置：

- **站点 URL**：longBlog 公开数据镜像及构建标记的站点根地址。
- **GitHub 仓库**：填写站点内容仓库 `owner/repo`，不是本 macOS 客户端仓库；Token 需要目标仓库的 Contents 读写权限。
- **文章目录**：默认使用 macOS Application Support 下的独立目录；可在设置中选择文件夹。首次同步前备份已有内容。
- **留言 API 与 Owner Key**：对应 longBlog 终端留言协议，不是通用邮箱。
- **Memos 服务与 Token**：legacy `/api/v1/memo` 数字 ID 协议，不保证兼容所有新版 Memos。
- **AI**：在文章编辑器的 AI 辅助面板中配置 HTTPS Base URL、模型和 API Key。

秘密保存在本机 Keychain，普通偏好保存在 UserDefaults。macOS 版使用独立 Bundle ID 与 Keychain 命名空间，不会自动继承手机上的凭据或文章目录。

## 数据安全

- 本地保存、暂存发布和远端提交是不同操作；请阅读按钮和确认对话框。
- 批量发布对 `main` 创建一个提交并非强制更新，不会自动重放结果不明的提交。
- 配置修改会写入站点仓库的 `.env`，上线仍依赖站点自身的部署流水线。
- 首次验收请使用测试仓库与测试 Memos 实例；CI 没有使用你的私人服务凭据进行发布、回复或归档测试。
- AI 生成会把面板说明的文章内容发送到你配置的服务，只有手动应用后才回填编辑器，不自动发布。

此预览版不能以“编译通过”替代你在实际 Mac 上对目录权限、输入法、媒体及真实服务的验收。
