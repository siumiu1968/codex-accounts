# Codex Accounts

**Language:** English | [简体中文](README.zh-CN.md)

![Codex Accounts overview](docs/assets/codex-accounts-overview.png)

Codex Accounts is a small macOS helper app for opening separate Codex desktop login windows for different OpenAI or GPT accounts, while keeping local Codex profile management in one place.

It is useful when you switch between multiple accounts often and do not want to log out, log in, and lose your current workflow each time.

## Features

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

## What It Does Not Do

- It does not copy OpenAI auth tokens, cookies, or account sessions between profiles.
- It does not sync OpenAI cloud chat history or ChatGPT server-side memory.
- Quota and reset time may show as unknown unless Codex exposes reliable local data for that account.
- This is an unofficial helper app and is not affiliated with OpenAI.

## Requirements

- macOS 13 or later.
- The official Codex desktop app installed at `/Applications/Codex.app`.
- Xcode Command Line Tools only if you want to build from source.

## Install

### Download Release

1. Open the GitHub Releases page.
2. Download `Codex-Accounts-macOS.zip`.
3. Unzip it and move `Codex Accounts.app` to `/Applications`.
4. Open it from Finder. If macOS Gatekeeper warns, right-click the app and choose `Open`.

### Build From Source

Clone this repository, then run:

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

Upload that ZIP to GitHub Releases so other people can download and run it directly.

## How To Use

1. Launch `Codex Accounts`.
2. Click the `+` button to create a new profile.
3. Click `登入` / `Log In` for that profile.
4. Sign in with the OpenAI or GPT account you want to use in that profile.
5. Click `打開` / `Open` later to reopen that profile.
6. Click the `x` button on a row to close only that profile's Codex window.
7. Use the `...` menu on a profile to rename it, reveal its folder, share local history, or archive it.

## Local Files

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

## Sharing Local History

The `Share History` feature links local Codex history files from Account 1 into another profile. Auth files remain separate.

Use this only if you understand the tradeoff: it helps profiles see the same local history, but it means those profiles share the same local history files on disk.

## Memory Sync

Memory sync copies these local items between profiles:

```text
AGENTS.md
memories/
rules/
```

It intentionally skips login files, cookies, SQLite logs, sessions, caches, and temporary files.

## Troubleshooting

If the wrong account opens, close that profile from Codex Accounts with the `x` button, then open it again from the correct row. Avoid launching profile windows directly from the normal Codex app icon, because that uses the default profile.

If a profile shows `要登入` / `Login needed`, open it and sign in again. This can happen after password changes or expired local auth.

If quota stays unknown, that is expected for now. The app only reports reliable local state.

## Privacy

All profiles are local folders on your Mac. The app does not upload your files and does not send account credentials anywhere. It launches the official Codex app with different local profile directories.

## License

MIT. See [LICENSE](LICENSE).
