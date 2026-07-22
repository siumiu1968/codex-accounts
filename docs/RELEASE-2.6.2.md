# Codex Accounts V2.6.2

V2.6.2 修正官方統一 ChatGPT／Codex App 因外層 bundle 名稱唔同而無法打開 Profile 嘅兼容問題。

## 同時支援兩種安裝路徑

- 自動偵測 `/Applications/Codex.app` 同 `/Applications/ChatGPT.app`。
- 亦支援 `~/Applications/Codex.app` 同 `~/Applications/ChatGPT.app`。
- 兩個兼容 App 同時存在時會優先保留原有 `Codex.app` 路徑，避免改變現有使用方式。
- 非 ChatGPT Classic 嘅明確 `CODEX_APP` 仍然優先，方便非標準安裝或開發版本。

## 避免誤開 ChatGPT Classic

- 唔會只靠檔名判斷；會核對 bundle identifier 或內置 Codex executable。
- `com.openai.chat` 嘅 ChatGPT Classic 會被拒絕，避免當成可建立獨立 Codex Profile 嘅統一 App。
- 如果只安裝咗 ChatGPT Classic，錯誤訊息會清楚指出需要目前包含 Codex 嘅 ChatGPT App。

## 完整啟動與統計兼容

- 打開、關閉、等待啟動同「關閉全部」共用同一套 App path 偵測。
- 「今日使用」會識別兩種 bundle 外層路徑，但唔會將 ChatGPT Classic 使用時間計入 Codex。
- 新增 fake bundle regression，覆蓋 `Codex.app`、統一 `ChatGPT.app`、ChatGPT Classic、使用者 Applications 同自訂路徑。

## 點解升級後仍然叫 Codex.app？

App updater 可以喺原有 bundle 位置替換內部內容，而唔需要重新命名外層資料夾。因此 App 內部顯示名稱同 executable 已經係 ChatGPT，但舊安裝仍可保留 `Codex.app`；另一部 Mac 經重新下載或唔同遷移流程，就可能係 `ChatGPT.app`。單靠外層檔名唔可以判斷有冇成功升級。

## 安裝

系統需求：macOS 14 或以上。

下載 `Codex-Accounts-macOS.zip`，解壓後將 `Codex Accounts.app` 放入 `/Applications`。如 macOS 阻擋第一次開啟，可到「系統設定 → 私隱與保安」選擇「仍要開啟」。

> Codex Accounts 係非官方本機輔助工具，與 OpenAI 冇從屬關係。
