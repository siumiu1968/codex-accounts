# Promotion Kit

This file gives you ready-to-post copy for GitHub, forums, Reddit, X, V2EX, and Hacker News. Edit the repo URL before publishing.

## GitHub Release Checklist

- Add repo topics: `macos`, `codex`, `openai`, `swiftui`, `productivity`, `multi-account`.
- Upload `dist/Codex-Accounts-macOS.zip` to GitHub Releases.
- Add the generated v2 screenshots from `docs/assets/codex-accounts-v2-hero.png`,
  `docs/assets/codex-accounts-v2-profiles.png`, `docs/assets/codex-accounts-v2-sidebar.png`,
  and `docs/assets/codex-accounts-v2-toolbar.png`.
- Mention that the app is unofficial and does not copy auth tokens or cookies.
- Add install notes for Gatekeeper: right-click `Open` if macOS blocks the first launch.

## Short Tagline

Run multiple Codex desktop accounts on macOS without logging in and out.

## English Forum Post

Title:

```text
Codex Accounts: a small macOS helper for switching between multiple Codex/OpenAI accounts
```

Body:

```text
I built Codex Accounts, a small macOS helper app for people who use multiple Codex/OpenAI accounts.

It creates separate local Codex profiles, then opens the official Codex desktop app with a separate CODEX_HOME and user-data-dir for each profile. That means each profile can stay logged into a different account.

Main features:
- Create unlimited local profiles
- Open, close, rename, reveal, archive, and delete profiles
- Separate login state per profile
- Sync local memory and share local history before opening a profile
- Usage meters for 5H / 1W quota windows with reset times
- Optional local history sharing
- Optional local memory sync for AGENTS.md, memories/, and rules/
- Keep Awake toggle that follows the real caffeinate state
- Liquid Glass UI with multiple themes, hover glow, and Chinese / English UI

It does not copy cookies, auth tokens, cloud conversations, or ChatGPT server-side memory. It is only a local macOS helper around the official Codex app.

GitHub:
https://github.com/siumiu1968/codex-accounts
```

## 中文論壇文案

標題：

```text
Codex Accounts：macOS 上管理多個 Codex/OpenAI 帳戶嘅小工具
```

內文：

```text
我整咗一個 macOS helper app，主要解決成日切換 Codex/OpenAI 帳戶要登入登出嘅問題。

Codex Accounts 會為每個 profile 建立獨立嘅 CODEX_HOME 同 Electron user-data-dir，然後用官方 Codex desktop app 開新視窗。所以每個 profile 可以登入唔同帳戶。

功能：
- 新增多個 profile
- 打開、關閉、改名、顯示資料夾、封存、刪除 profile
- 每個 profile 保留獨立登入狀態
- 打開 profile 前先同步本機記憶同共享本機對話紀錄
- 顯示 5H / 1W quota、百分比同恢復時間
- 可選擇共享本機 Codex 對話紀錄
- 可選擇同步 AGENTS.md、memories/、rules/
- 防睡眠開關會跟返真實 caffeinate 狀態
- Liquid Glass UI、多主題、hover 發光、中文/英文介面

注意：佢唔會複製 cookies、auth token、OpenAI 雲端對話或 ChatGPT server-side memory。只係本機 profile 管理工具。

GitHub:
https://github.com/siumiu1968/codex-accounts
```

## X / Twitter Post

```text
Built Codex Accounts for macOS.

It lets you keep separate Codex desktop profiles for different OpenAI accounts, so you can switch accounts without constantly logging out.

Separate CODEX_HOME, separate app data, optional local history/memory sync.

GitHub: https://github.com/siumiu1968/codex-accounts
```

## Show HN Draft

```text
Show HN: Codex Accounts, a macOS helper for multiple Codex/OpenAI accounts

I use multiple OpenAI accounts with the Codex desktop app and got tired of logging in and out. This helper creates separate local profiles, each with its own CODEX_HOME and Electron user-data-dir, then launches the official Codex app against that profile.

It includes profile creation, open/close, rename, archive, local history sharing, local memory sync, quota meters, multi-theme Liquid Glass UI, and a Keep Awake toggle for long-running Codex sessions.

It does not copy cookies or auth tokens and it does not sync cloud conversations. It is only local profile management.

Repo: https://github.com/siumiu1968/codex-accounts
```

## Where To Promote

- GitHub topics and README screenshots first.
- X / Twitter with one screenshot and a short demo clip.
- Reddit communities related to macOS apps, OpenAI, AI coding tools, and productivity. Check each community's self-promotion rules before posting.
- Hacker News as a `Show HN` when the README, release ZIP, and screenshot are ready.
- V2EX nodes related to macOS, Apple, OpenAI, and productivity.
- Product Hunt only after you have a signed or notarized build and a short demo video.

## Demo Video Script

1. Open Codex Accounts.
2. Create a new profile with the `+` button.
3. Click `Log In`.
4. Show that the profile opens a separate Codex window.
5. Rename the profile.
6. Close the profile with the `x` button.
7. Toggle Keep Awake.
8. End on the GitHub release page.

Keep the video under 45 seconds.
