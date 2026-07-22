# Codex Accounts 2.6.1 Promotion Kit

This file gives you ready-to-post copy for GitHub, forums, Reddit, X, V2EX, and Hacker News. Edit the repo URL before publishing.

## GitHub Release Checklist

- Add repo topics: `macos`, `codex`, `openai`, `swiftui`, `productivity`, `multi-account`.
- Upload `dist/Codex-Accounts-macOS.zip` to GitHub Releases.
- Add only these existing anonymized UI screenshots (their V2.5.5 filenames are retained):
  `docs/assets/codex-accounts-v2.5.5-overview-zh-HK.jpg` and
  `docs/assets/codex-accounts-v2.5.5-themes-zh-HK.jpg`.
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
I built Codex Accounts 2.6.1, a small macOS helper app for people who use multiple Codex/OpenAI accounts.

It creates separate local Codex profiles, then opens the official Codex desktop app with a separate CODEX_HOME and user-data-dir for each profile. That means each profile can stay logged into a different account.

Main features:
- Create unlimited local profiles
- Open, close, rename, reveal, archive, and delete profiles
- Reliable profile launch with process verification and actionable errors
- Separate login state per profile
- Automatic or on-demand local memory, rules, and plugin-setting sync without blocking profile launch
- Usage meters for 5H / 1W quota windows with reset times
- Clear Sign-in expired, Sign-in required, and Usage temporarily unavailable states
- Reliable refresh: no fabricated 0% / 00/00 values, with last-known quota kept during network or server failures
- Lower-load fallback usage checks with MCP servers and plugins disabled
- A Today Usage counter that excludes time while the Mac is asleep or powered off
- Per-profile private or shared local-chat mode
- Three-level Keep Awake control: Off, keep awake while the display is open, or keep running with the lid closed
- Liquid Glass UI with 8 distinct themes, hover glow, and Chinese / English UI

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
我整咗 Codex Accounts 2.6.1，主要解決成日切換 Codex/OpenAI 帳戶要登入登出嘅問題。

Codex Accounts 會為每個 profile 建立獨立嘅 CODEX_HOME 同 Electron user-data-dir，然後用官方 Codex desktop app 開新視窗。所以每個 profile 可以登入唔同帳戶。

功能：
- 新增多個 profile
- 打開、關閉、改名、顯示資料夾、封存、刪除 profile
- 打開 Profile 會驗證 Codex 真正啟動，失敗時顯示原因
- 每個 profile 保留獨立登入狀態
- 自動或手動同步本機記憶、rules 同外掛設定，唔會阻塞 Profile 啟動
- 顯示 5H / 1W quota、百分比同恢復時間
- quota 會清楚分辨「登入過期」、「需要登入」同「暫時未能取得」
- Reload 唔再顯示假嘅 0% / 00/00；網絡或伺服器暫時失敗時會保留上一個可用 quota
- 後備用量查詢停用 MCP 同 plugins，減少背景負荷
- 「今日使用」只計實際使用時間，Mac 睡眠或關機期間唔會計入去
- 每個 Profile 可獨立選擇私人或共享本機對話
- 三段防睡眠滑桿：關閉、開屏防睡眠、合蓋繼續運行
- Liquid Glass UI、8 款分別更明顯嘅主題、hover 發光、中文/英文介面

注意：佢唔會複製 cookies、auth token、OpenAI 雲端對話或 ChatGPT server-side memory。只係本機 profile 管理工具。

GitHub:
https://github.com/siumiu1968/codex-accounts
```

## X / Twitter Post

```text
Built Codex Accounts 2.6.1 for macOS.

It lets you keep separate Codex desktop profiles for different OpenAI accounts, so you can switch accounts without constantly logging out.

Separate CODEX_HOME, separate app data, reliable verified launches, per-profile private local chats, explicit quota/auth states, accurate Today Usage, a three-level Keep Awake control, and 8 themes.

GitHub: https://github.com/siumiu1968/codex-accounts
```

## Show HN Draft

```text
Show HN: Codex Accounts, a macOS helper for multiple Codex/OpenAI accounts

I use multiple OpenAI accounts with the Codex desktop app and got tired of logging in and out. This helper creates separate local profiles, each with its own CODEX_HOME and Electron user-data-dir, then launches the official Codex app against that profile.

It includes profile creation, verified open/close, rename, archive, per-profile private or shared local chats, local memory sync, quota meters with explicit expired/unavailable states, a Today Usage counter that excludes sleep and power-off time, 8 Liquid Glass themes, and a three-level Keep Awake control. Quota refresh keeps the last usable value through temporary network or server failures and avoids showing fabricated zero values.

It does not copy cookies or auth tokens and it does not sync cloud conversations. It is only local profile management.

Repo: https://github.com/siumiu1968/codex-accounts
```

## Where To Promote

- GitHub topics and README screenshots first.
- X / Twitter with one screenshot and a short demo clip.
- Reddit communities related to macOS apps, OpenAI, AI coding tools, and productivity. Check each community's self-promotion rules before posting.
- Hacker News as a `Show HN` when the README, release ZIP, and screenshot are ready.
- V2EX nodes related to macOS, Apple, OpenAI, and productivity.
- Product Hunt only after you have a verified downloadable build and a short demo video.

## Demo Video Script

1. Open Codex Accounts.
2. Show the anonymized profile list, quota meters, and Today Usage counter.
3. Create a demo profile with the `+` button, then show the separate Codex window.
4. Close the demo profile with the `x` button.
5. Open System Tools and show all three slider levels: Off, Screen, and Lid. Return it to Off.
6. Open Appearance and switch through the 8 themes, pausing briefly on two contrasting choices.
7. End on the GitHub release page with the existing anonymized overview and themes screenshots visible.

Keep the video under 45 seconds.
