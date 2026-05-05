# Codex Accounts

**语言 / Language:** 简体中文 | [English](#english)

![Codex Accounts overview](docs/assets/codex-accounts-overview.png)

Codex Accounts 是一个 macOS 小工具，用来为不同 OpenAI / GPT 账号打开独立的 Codex 桌面登录窗口，同时集中管理本地 Codex profiles。

适合经常切换多个 Codex / OpenAI 账号的人使用，避免反复登出、登录，亦可以更清楚地管理每个账号窗口。

## 功能

- 创建任意数量的本地 Codex profile。
- 每个 profile 用独立的 Codex 桌面窗口打开。
- 每个 profile 使用独立的 `CODEX_HOME` 和 Electron `--user-data-dir`，登录状态互不混用。
- 每分钟自动刷新本地登录状态。
- 在一个窗口里改名、关闭、显示资料夹、归档、删除 profile。
- 可选：在多个 profile 之间共享本地 Codex 对话记录。
- 可选：同步本地记忆文件，包括 `AGENTS.md`、`memories/`、`rules/`。
- 菜单栏快速打开不同账号窗口。
- 防睡眠开关，适合长时间运行 Codex 任务。
- 支持中文和英文界面。

## 它不会做什么

- 不会复制 OpenAI auth token、cookie 或账号 session。
- 不会同步 OpenAI 云端对话记录，也不会同步 ChatGPT 服务端 memory。
- 如果 Codex 本身没有提供可靠的本地数据，用量和重置时间可能会显示为未知。
- 这是非官方辅助工具，与 OpenAI 没有关联。

## 系统要求

- macOS 13 或更新版本。
- 官方 Codex 桌面应用已安装在 `/Applications/Codex.app`。
- 只有从源码构建时才需要 Xcode Command Line Tools。

## 安装

### 下载 Release

1. 打开 [Releases](https://github.com/siumiu1968/codex-accounts/releases)。
2. 下载 `Codex-Accounts-macOS.zip`。
3. 解压后把 `Codex Accounts.app` 移到 `/Applications`。
4. 从 Finder 打开。

如果 macOS 显示 `Apple 无法验证 “Codex Accounts” 有没有包含可能危害你的 Mac 或泄漏隐私的恶意软件`：

1. 打开 `System Settings`。
2. 进入 `Privacy & Security`。
3. 找到 `Codex Accounts` 被拦截的提示。
4. 点击 `Open Anyway`。
5. 再次打开 app。

### 从源码构建

```zsh
git clone https://github.com/siumiu1968/codex-accounts.git
cd codex-accounts
scripts/build_codex_accounts_app.zsh
open "/Applications/Codex Accounts.app"
```

创建发布 ZIP：

```zsh
scripts/package_release.zsh
```

ZIP 会生成在：

```text
dist/Codex-Accounts-macOS.zip
```

## 使用方法

1. 启动 `Codex Accounts`。
2. 点击 `+` 创建新 profile。
3. 点击该 profile 的 `登录` / `Log In`。
4. 在打开的 Codex 窗口里登录你想使用的 OpenAI / GPT 账号。
5. 之后点击 `打开` / `Open` 重新打开该 profile。
6. 点击某一行的 `x`，只关闭该 profile 对应的 Codex 窗口。
7. 使用 `...` 菜单改名、显示资料夹、共享本地历史或归档 profile。

## 本地文件位置

默认 profile 位置：

```text
Account 1: ~/.codex
Account 2: ~/.codex-account2
更多账号: ~/.codex-accounts/<profile-name>
```

独立 Electron app data：

```text
Account 1: ~/Library/Application Support/Codex
Account 2: ~/Library/Application Support/Codex Account 2
更多账号: ~/Library/Application Support/Codex Accounts/<profile-name>
```

删除 profile 时会先归档，不会立刻永久删除：

```text
~/.codex-accounts-archive
```

## 共享本地对话记录

`Share History` 会把 Account 1 的本地 Codex 历史文件链接到另一个 profile。登录文件仍然保持分离。

请先理解这个取舍再使用：它可以让多个 profile 看到同一份本地历史，但这些 profile 会共享同一组本地历史文件。

## 记忆同步

记忆同步会复制这些本地项目：

```text
AGENTS.md
memories/
rules/
```

它会刻意跳过登录文件、cookie、SQLite 日志、sessions、cache 和临时文件。

## 常见问题

如果打开了错误账号，请先在 Codex Accounts 里点击该 profile 的 `x` 关闭窗口，再从正确的 profile 行重新打开。尽量不要直接从普通 Codex app 图标打开 profile 窗口，因为普通 Codex app 会使用默认 profile。

如果 profile 显示 `要登录` / `Login needed`，打开它并重新登录。改密码或本地 auth 过期后可能会出现这种情况。

如果用量一直显示未知，这是目前预期行为。这个 app 只显示可靠的本地状态。

## 隐私

所有 profile 都是你 Mac 上的本地文件夹。这个 app 不会上传你的文件，也不会把账号凭证发送到其他地方。它只是用不同的本地 profile 目录启动官方 Codex app。

## License

MIT. See [LICENSE](LICENSE).

---

<a id="english"></a>

## English

**Language:** [简体中文](#codex-accounts) | English

Codex Accounts is a small macOS helper app for opening separate Codex desktop login windows for different OpenAI or GPT accounts, while keeping local Codex profile management in one place.

It is useful when you switch between multiple accounts often and do not want to log out, log in, and lose your current workflow each time.

### Features

- Create as many local Codex profiles as you need.
- Open each profile in a separate Codex desktop window.
- Keep login state separate per profile by using a separate `CODEX_HOME` and Electron `--user-data-dir`.
- Show local sign-in state, with automatic refresh every minute.
- Rename, close, reveal, archive, and delete profiles from one window.
- Optional local history sharing between profiles.
- Optional local memory sync for `AGENTS.md`, `memories/`, and `rules/`.
- Menu bar controls for quick account opening.
- Keep Awake toggle to stop macOS sleeping during long runs.
- Cantonese Chinese and English UI.

### What It Does Not Do

- It does not copy OpenAI auth tokens, cookies, or account sessions between profiles.
- It does not sync OpenAI cloud chat history or ChatGPT server-side memory.
- Quota and reset time may show as unknown unless Codex exposes reliable local data for that account.
- This is an unofficial helper app and is not affiliated with OpenAI.

### Requirements

- macOS 13 or later.
- The official Codex desktop app installed at `/Applications/Codex.app`.
- Xcode Command Line Tools only if you want to build from source.

### Install

#### Download Release

1. Open [Releases](https://github.com/siumiu1968/codex-accounts/releases).
2. Download `Codex-Accounts-macOS.zip`.
3. Unzip it and move `Codex Accounts.app` to `/Applications`.
4. Open it from Finder.

If macOS says Apple cannot verify whether `Codex Accounts` contains malware:

1. Open `System Settings`.
2. Go to `Privacy & Security`.
3. Find the blocked `Codex Accounts` message.
4. Click `Open Anyway`.
5. Open the app again.

#### Build From Source

```zsh
git clone https://github.com/siumiu1968/codex-accounts.git
cd codex-accounts
scripts/build_codex_accounts_app.zsh
open "/Applications/Codex Accounts.app"
```

To create a release ZIP:

```zsh
scripts/package_release.zsh
```

The ZIP will be written to:

```text
dist/Codex-Accounts-macOS.zip
```

### How To Use

1. Launch `Codex Accounts`.
2. Click the `+` button to create a new profile.
3. Click `登入` / `Log In` for that profile.
4. Sign in with the OpenAI or GPT account you want to use in that profile.
5. Click `打開` / `Open` later to reopen that profile.
6. Click the `x` button on a row to close only that profile's Codex window.
7. Use the `...` menu on a profile to rename it, reveal its folder, share local history, or archive it.

### Local Files

Default profile locations:

```text
Account 1: ~/.codex
Account 2: ~/.codex-account2
More accounts: ~/.codex-accounts/<profile-name>
```

Separate Electron app data:

```text
Account 1: ~/Library/Application Support/Codex
Account 2: ~/Library/Application Support/Codex Account 2
More accounts: ~/Library/Application Support/Codex Accounts/<profile-name>
```

Deleted profiles are archived instead of permanently removed:

```text
~/.codex-accounts-archive
```

### Sharing Local History

The `Share History` feature links local Codex history files from Account 1 into another profile. Auth files remain separate.

Use this only if you understand the tradeoff: it helps profiles see the same local history, but it means those profiles share the same local history files on disk.

### Memory Sync

Memory sync copies these local items between profiles:

```text
AGENTS.md
memories/
rules/
```

It intentionally skips login files, cookies, SQLite logs, sessions, caches, and temporary files.

### Troubleshooting

If the wrong account opens, close that profile from Codex Accounts with the `x` button, then open it again from the correct row. Avoid launching profile windows directly from the normal Codex app icon, because that uses the default profile.

If a profile shows `要登入` / `Login needed`, open it and sign in again. This can happen after password changes or expired local auth.

If quota stays unknown, that is expected for now. The app only reports reliable local state.

### Privacy

All profiles are local folders on your Mac. The app does not upload your files and does not send account credentials anywhere. It launches the official Codex app with different local profile directories.

### License

MIT. See [LICENSE](LICENSE).
