# Codex Accounts V2.7.0

V2.7.0 將 OpenCodex 2.7.33 正式整合到 Codex Accounts，令受管理嘅 Codex Profile 可以選用同一套已登入第三方模型，同時保留各自 OpenAI 登入同本機對話設定。

## 受管理 Profile 共用 OpenCodex 模型

- 打開 Profile 前會先啟動只監聽本機 loopback 嘅 OpenCodex 代理，再驗證模型目錄；已驗證目錄會即時沿用，毋須每次重新等候供應商同步。
- 第一次同步、供應商／模型設定有變或驗證超過 24 小時時會重新整理模型；網絡同步設有 20 秒上限。舊目錄只有喺設定指紋同目錄 SHA-256 都完全吻合時先可沿用，否則安全停止而唔會無限轉圈。
- 透過高優先級 Codex CLI 路由，避免工作目錄內嘅舊設定蓋過 Profile 模型清單。
- OpenAI 請求繼續使用每個 Profile 自己嘅登入；唔會複製或合併 auth token。
- 私人／共享本機對話模式維持不變，唔會因模型共用而改動對話紀錄。
- 已有自訂模型路由嘅 Profile 會原樣保留，其餘受管理 Profile 會自動接入 OpenCodex。
- 停止 OpenCodex 時只會移除 Codex Accounts 自己加入嘅路由設定，使用者自訂設定會保留。

## 內置離線 Runtime

- 安裝包內置 OpenCodex 2.7.33 arm64 runtime，更新後毋須再由 npm 下載。
- 解壓前會核對版本、架構、archive SHA-256 同關鍵檔案雜湊。
- 安裝程序會拒絕 absolute path、`..`、symlink／hardlink escape，並使用同一 managed root 暫存後原子替換。
- 包含第三方套件清單及原始 license／notice 檔案。
- 安裝包只包含程式 runtime，唔包含任何使用者 token、OAuth credential、API key 或對話資料。

## 香港繁體介面

- OpenCodex Dashboard 內置香港繁體中文介面。
- UI overlay 同 runtime 關鍵檔案均以固定 SHA-256 驗證，檔案不一致時會拒絕啟動。

## 安裝

系統需求：Apple Silicon Mac、macOS 14 或以上。

下載 `Codex-Accounts-macOS.zip`，解壓後將 `Codex Accounts.app` 放入 `/Applications`。如 macOS 阻擋第一次開啟，可到「系統設定 → 私隱與保安」選擇「仍要開啟」。

> Codex Accounts 係非官方本機輔助工具，與 OpenAI 或 OpenCodex 冇從屬關係。
