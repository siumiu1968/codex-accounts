# Codex Accounts V2.6.0

V2.6.0 集中重整 quota、登入狀態同背景查詢，令多帳戶長時間使用時嘅顯示更準確，亦減少後備查詢對系統造成嘅負荷。

## Quota 與登入狀態

- 憑證確定失效時，介面會清楚顯示「登入過期」或「需要登入」。
- 已登入但暫時攞唔到官方用量時，介面會顯示「暫時未能取得」，唔再只留低含糊嘅空白或破折號。
- Reload 期間唔再閃出假嘅 `0%` 或 `00/00`。
- 只有官方 OAuth 明確回覆 token 無效，先會將 profile 判定為登入過期。
- 一般網絡錯誤、timeout 或 5xx 伺服器錯誤會保留上一個可用 quota，避免短暫連線問題令用量突然消失。

## 效能與穩定性

- 後備 quota 查詢會以停用 MCP servers 同 plugins 嘅方式啟動 Codex app-server，減少背景程序、額外初始化同系統負荷。
- 暫時性查詢錯誤同永久登入失效會分開處理，避免網絡問題誤報成登出。

## 使用者需要注意

- 顯示「登入過期」嘅 profile 仍然需要使用者重新登入。
- App 唔會自動修復、複製或傳送 OpenAI 登入憑證。
- Quota 查詢只會使用對應 profile 嘅本機憑證請求官方 Codex / ChatGPT 服務。

## 安裝

系統需求：macOS 14 或以上。

下載 `Codex-Accounts-macOS.zip`，解壓後將 `Codex Accounts.app` 放入 `/Applications`。如 macOS 阻擋第一次開啟，可到「系統設定 → 私隱與保安」選擇「仍要開啟」。

> Codex Accounts 係非官方本機輔助工具，與 OpenAI 冇從屬關係。
