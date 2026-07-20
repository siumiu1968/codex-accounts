# Codex Accounts

**语言：** [繁體中文 / 简体中文 / English](README.md) | 简体中文

Codex Accounts 是一个非官方 macOS 工具，用来管理多个 Codex / OpenAI profile。每个 profile 都有独立的 `CODEX_HOME` 和应用数据目录，因此可以保持不同的登录状态，不必反复退出和重新登录。

![为 V2.5.5 制作的匿名 Codex Accounts 界面截图](docs/assets/codex-accounts-v2.5.5-overview-zh-HK.jpg)

![为 V2.5.5 制作的匿名 Codex Accounts 主题截图](docs/assets/codex-accounts-v2.5.5-themes-zh-HK.jpg)

> 两张图片都只使用虚构 profile 名称、`/tmp/demo-profiles/...` 演示路径和模拟用量，不包含真实账号、姓名、电脑用户名、token 或对话内容。

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
- 打开 profile 前同步本地记忆、规则、插件设置和可选的本地对话记录。
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
