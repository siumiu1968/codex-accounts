# Codex Accounts

**语言：** [繁體中文 / 简体中文 / English](README.md) | 简体中文

![Codex Accounts v2 overview](docs/assets/codex-accounts-v2-hero.png)

> 截图使用的是演示 profile 名称和假的本地路径，不包含真实账号名称或真实用户路径。

## 简介

Codex Accounts 是一个 macOS 小工具，用来管理多个 Codex / OpenAI 账号。它会为每个 profile 打开一个独立的 Codex desktop 窗口，并分开 `CODEX_HOME` 和 Electron `user-data-dir`，所以不同 profile 可以保持不同登录状态，不需要反复登出登录。

## v2 功能

- 新增、打开、关闭、改名、显示资料夹、归档和删除多个 profile。
- 每个 profile 使用独立登录状态，不同 OpenAI / GPT 账号互不混用。
- 打开 profile 前会先同步本地记忆，再共享本地对话记录，然后才打开账号窗口。
- 显示 5H / 1W 用量、百分比和恢复时间，并支持快速 reload 动画。
- 每分钟刷新登录状态和 quota，并保留最近可用数据。
- 可选本地 Codex 对话记录共享。
- 可选同步 `AGENTS.md`、`memories/`、`rules/`。
- 防睡眠开关使用 `caffeinate`，并会跟随真实系统进程状态。
- Liquid Glass 界面、多主题、hover 发光、profile 卡片动画。
- 菜单栏快速新增、同步、关闭所有 Codex 窗口、切换防睡眠。

## 图片

![Profile list with quota meters](docs/assets/codex-accounts-v2-profiles.png)

![Automation and Keep Awake controls](docs/assets/codex-accounts-v2-sidebar.png)

![Toolbar controls](docs/assets/codex-accounts-v2-toolbar.png)

## 安装

1. 到 [Releases](https://github.com/siumiu1968/codex-accounts/releases) 下载 `Codex-Accounts-macOS.zip`。
2. 解压后把 `Codex Accounts.app` 移到 `/Applications`。
3. 从 Finder 打开 app。

如果 macOS 阻挡第一次打开，进入 `System Settings` → `Privacy & Security`，找到 `Codex Accounts`，选择 `Open Anyway`。

## 从源码构建

```zsh
git clone https://github.com/siumiu1968/codex-accounts.git
cd codex-accounts
scripts/build_codex_accounts_app.zsh
open "/Applications/Codex Accounts.app"
```

创建 release ZIP：

```zsh
scripts/package_release.zsh
```

输出位置：

```text
dist/Codex-Accounts-macOS.zip
```

## 隐私

- 不会复制 OpenAI auth token、cookie 或 account session 到其他 profile。
- 不会同步 OpenAI 云端对话，也不会同步 ChatGPT server-side memory。
- 不会把账号凭证发送到第三方。
- 用量查询只会使用该 profile 的本地 token 请求官方 Codex / ChatGPT 用量接口。
- 这是非官方辅助工具，与 OpenAI 没有关联。

## License

MIT. See [LICENSE](LICENSE).
