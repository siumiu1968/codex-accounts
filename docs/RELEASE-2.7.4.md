# Codex Accounts 2.7.4

- App 版本：2.7.4（build 74）
- 內置 OpenCodex：`@bitkyc08/opencodex@2.29.0`
- OpenCodex 只限獨立 `opencodex-lab` Profile；普通 Profile 保持直連或原有自訂路由。
- Lab 可選擇加入普通 Profile 使用嘅共享本機對話；只連結對話索引、sessions 同 shell snapshots，登入、SQLite、設定、本機記憶、App Data 同代理路由保持獨立。
- 固定 loopback port `10100`，被佔用時直接停止，不會改用其他 port。
- Dashboard 每次取得新嘅短期 loopback session，唔需要輸入 OpenCodex 自動產生嘅管理員金鑰，亦唔會將金鑰放入網址。
- 使用 OpenCodex 內置繁體中文介面，不再打包舊版香港繁體 overlay。
- 離線 runtime seed 驗證固定四項關鍵檔案：`package.json`、`bin/ocx.mjs`、`bun.exe`、`gui/dist/index.html`。
- 累積包含 2.7.3 低空間自動清理子 task：只處理已完成或長時間停止更新嘅 agent 子 task，保留主 task、用戶 task、每組最新子 task、使用中資料、登入、Token 同設定。
- 保留 2.7.2 冷熱分層儲存、ORICO 批量冷藏／還原、更新後回退保護，同最多 8 MB 子程序輸出限制。
