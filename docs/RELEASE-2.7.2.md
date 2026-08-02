# Codex Accounts V2.7.2

V2.7.2 集中修復儲存空間、連線依賴及長時間記憶體增長問題。

## 主要更新

- 加入 ORICO 冷熱分層儲存、批量冷藏／還原、七日以上篩選及全選。
- 冷藏前檢查 task 活躍狀態、檔案鎖及交易鎖，避免搬動進行中資料。
- 正式帳號可使用各自原有登入直接連接 OpenAI；`opencodex-lab` 維持獨立測試用途。
- 每個子程序輸出最多保留 8 MB，防止 command output、quota refresh 或大型工具輸出無上限累積。
- 保留 GitHub Releases API 與普通網頁雙路更新檢查、HTTP 狀態驗證及下載逾時。

## 安全界線

- 不包含任何帳號 Token、OAuth credential、task、對話內容或本機診斷記錄。
- 冷藏索引及回復資料仍由使用者本機管理，不會上傳 GitHub。

## 版本

- App：2.7.2
- Build：72
