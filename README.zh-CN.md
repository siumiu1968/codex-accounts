# Codex Accounts

**语言：** [繁體中文 / 简体中文 / English](README.md) | 简体中文

Codex Accounts 是一个非官方 macOS 工具，用来管理多个 Codex / OpenAI profile。每个 profile 都有独立的 `CODEX_HOME` 和应用数据目录，因此可以保持不同的登录状态，不必反复退出和重新登录。

![为 V2.5.5 制作的匿名 Codex Accounts 界面截图](docs/assets/codex-accounts-v2.5.5-overview-zh-HK.jpg)

![为 V2.5.5 制作的匿名 Codex Accounts 主题截图](docs/assets/codex-accounts-v2.5.5-themes-zh-HK.jpg)

> 两张图片都只使用虚构 profile 名称、`/tmp/demo-profiles/...` 演示路径和模拟用量，不包含真实账号、姓名、电脑用户名、token 或对话内容。

## 2.7.1 更新

- 修复部分网络环境下无法检查更新的问题。
- GitHub Releases API 被限流、拦截或暂时失效时，会自动改用普通 GitHub Releases 网页取得最新版本。
- 下载更新文件时会验证 HTTP 状态并设置超时，避免把错误页面当成 ZIP。
- 受影响的旧版需要手动安装 V2.7.1 一次；之后即可使用新的备用检查路径。

## 2.7.0 更新

- 安装包内置 arm64 OpenCodex 2.7.33 runtime 与香港繁体 Dashboard，更新后无需通过 npm 下载。
- 打开受管理 Profile 前会先启动本地 loopback 代理并验证共享模型目录；已验证目录会立即沿用，仅在提供商／模型设置改变或验证超过 24 小时时重新同步。
- 网络同步设有 20 秒上限，超时只有设置指纹与目录 SHA-256 完全一致才会沿用旧目录，避免打开 Profile 时无限转圈。
- 自定义模型路由／provider 会原样保留，不会被默认 OpenAI 设置覆盖。
- 已登录的第三方模型可以在未设置自定义模型路由的不同 Profile 中选择；OpenAI 仍使用每个 Profile 自己的登录身份。
- 不会改变现有的共享／私人本地对话设置，安装包也不包含任何用户 token、OAuth credential 或对话数据。

## 2.6.2 更新

- 自动检测 `/Applications/Codex.app`、`/Applications/ChatGPT.app` 及用户 `~/Applications` 下的统一 ChatGPT／Codex 应用。
- 通过 bundle identity 或内置 Codex executable 判断兼容性，不会误用 `com.openai.chat` 的 ChatGPT Classic。
- 打开、关闭、启动验证和“今日使用”统计会使用同一份检测结果。
- 旧安装升级后可能继续保留 `Codex.app` 外层名称；这不代表内部应用没有更新。

## 2.6.1 更新

- 修复部分 Mac 点击“打开”后长时间转圈或没有反应：Profile 启动改用独立高优先级队列。
- 默认跳过启动前的重型数据修复，并确认对应 Codex 进程真正启动；失败时会显示具体原因。
- 新增每个 Profile 独立的“私人本地对话”模式；私人 Profile 会跳过本地对话、记忆和批量导入共享。
- 私人模式只隔离本地记录；使用 OpenAI 模型时，内容仍会发送到 OpenAI 处理。

## 2.6.0 更新

- 重新整理 quota 与登录状态：凭证明确失效时显示“登录过期”或“需要登录”，已登录但暂时无法取得官方用量时显示“暂时无法取得”。
- Reload 期间不再闪出虚假的 `0%` 或 `00/00`。
- 只有官方 OAuth 明确返回无效 token 时才会判定登录过期；网络故障或 5xx 会保留上一份可用 quota。
- 备用 quota 查询会停用 MCP 与 plugins，减少后台进程和系统负载。
- 登录过期仍需要用户重新登录；应用不会自动修复、复制或传送登录凭证。

## 2.5.5 更新

- 修复“今日使用”在睡眠、断电或异常关机后可能超过 24 小时的问题；睡眠和关机时间不会计入。
- 登录状态以当前检查结果为准，避免旧缓存或临时网络错误把已登录 profile 错误显示为“未登录”。
- 防睡眠改为三档彩色滑杆：关闭、开屏防睡眠、合盖继续运行。合盖模式需要 macOS 管理员确认，应用不会保存管理员密码。
- 提供 8 个辨识度更高的主题：石墨、极光、日落、霓虹、深海、樱花、森林和午夜。
- 修复主题名称被省略、主题卡片重叠及小窗口排版问题。
- 改善 GPT-5.6 模型选择和本地对话同步，减少 profile 切换后模型设置或侧栏记录异常。

## 主要功能

- 创建、打开、关闭、改名、显示目录、归档和删除多个 profile。
- 每个 profile 保持独立的 Codex / OpenAI 登录状态。
- 内置 OpenCodex；受管理 Profile 可共用本地第三方模型提供商，同时保留逐 Profile OpenAI 身份。
- 每个 profile 可选择私人本地对话或共享模式；私人 profile 不参与本地对话、记忆和批量导入共享。
- 显示官方接口当前提供的 quota、剩余百分比和恢复时间，并支持手动刷新。
- 统计当天实际运行时间，睡眠和关机时间不计入。
- 导出或导入 `.codexshare` 对话包，方便在可信设备或团队成员之间交接本地上下文。
- 三档防睡眠控制，以及键盘清洁模式。
- 8 个 Liquid Glass 风格主题，支持香港粤语、繁体中文、简体中文、英语和日语界面。
- 菜单栏可快速新增 profile、同步、关闭受管理的 Codex 窗口和切换防睡眠模式。
- 应用内检查并安装新的 GitHub Release。

## 安装

系统要求：macOS 14 或更高版本。

1. 到 [Releases](https://github.com/siumiu1968/codex-accounts/releases) 下载 `Codex-Accounts-macOS.zip`。
2. 解压后把 `Codex Accounts.app` 移到 `/Applications`。
3. 从 Finder 打开应用。

如果 macOS 阻止首次打开，请进入 `System Settings` → `Privacy & Security`，找到 `Codex Accounts` 并选择 `Open Anyway`。

## 从源码构建

```zsh
git clone https://github.com/siumiu1968/codex-accounts.git
cd codex-accounts
scripts/build_codex_accounts_app.zsh
open "/Applications/Codex Accounts.app"
```

创建 Release ZIP：

```zsh
scripts/package_release.zsh
```

输出文件：`dist/Codex-Accounts-macOS.zip`

## 隐私

- 不会把某个 profile 的 OpenAI auth token、cookie 或登录 session 复制到其他 profile。
- 不会同步 OpenAI 云端对话或 ChatGPT server-side memory。
- 不会把账号凭证发送给第三方。
- 本地对话、记忆和设置只会在用户选择的本机 profile 之间处理。
- 用量查询只使用对应 profile 的本地凭证请求官方 Codex / ChatGPT 接口。
- 合盖防睡眠只在 macOS 管理员确认后更改系统睡眠设置，应用不会保存密码。
- 本项目是非官方辅助工具，与 OpenAI 没有从属关系。

## License

MIT，详见 [LICENSE](LICENSE)。
