# Codex Accounts V2.7.1

V2.7.1 修復部分網絡環境下「檢查更新」冇反應或讀取失敗嘅問題。

## 更新檢查更可靠

- 先透過 GitHub Releases API 檢查最新版，並驗證 HTTP 狀態同回傳資料。
- API 被限流、攔截或暫時失效時，自動改用 GitHub Releases 網頁取得最新版本標籤。
- 下載更新檔時加入逾時及 HTTP 狀態檢查，避免錯誤頁面被當成 ZIP 安裝。
- 兩個來源都失敗時會顯示較具體嘅錯誤，方便分辨網絡、API 或下載問題。

## 安裝

系統需求：Apple Silicon Mac、macOS 14 或以上。

下載 `Codex-Accounts-macOS.zip`，解壓後將 `Codex Accounts.app` 放入 `/Applications`。如果舊版無法檢查更新，今次需要手動安裝一次；升級至 V2.7.1 後，往後更新會自動使用後備檢查路徑。

> Codex Accounts 係非官方本機輔助工具，與 OpenAI 或 OpenCodex 冇從屬關係。
