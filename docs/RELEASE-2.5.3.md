# Codex Accounts 2.5.3 Change Notes

## 問題或需求描述

- 新版 ChatGPT Codex 已加入 GPT-5.6，但舊 helper 仍會用 SQLite trigger 將非 API profile 嘅對話模型強制改返 GPT-5.5。
- 共用 session 檔案與各 profile 獨立 `state_5.sqlite` 之間可能出現索引差異。
- 手動或自動同步會強制寫入使用中資料庫，背景亦每 5 秒清理一次側欄狀態，存在鎖衝突及誤刪風險。
- 介面寫「每分鐘同步」，實際排程係每 10 分鐘，而且上次成功時間重開 App 後會消失。

## 修復或實現思路

- 移除 GPT-5.5 強制 trigger，保留有效 OpenAI model；只修正明確被外部 provider 污染嘅 thread。
- 由 profile config、遠端 model cache 或 Codex bundled catalog 動態選擇可用 OpenAI model。
- 同步時跳過使用中 SQLite 及 `.codex-global-state.json`；開啟 profile 前由 helper 先關閉目標視窗、補齊索引，再啟動 Codex。
- 停止自動側欄 prune loop，改為使用者手動執行「整理側欄」。
- 自動化介面顯示真實 10 分鐘週期、同步開關狀態及持久化嘅上次成功時間。
- 重配 12 套外觀主題，以中性深色底配冷暖輔色，改善辨識度同長時間閱讀舒適度。
- 側欄捲動區避開透明標題列，防止內容撞到 macOS 視窗控制掣。
- 新增臨時 profile 回歸測試，確保 GPT-5.6 選擇不會被覆寫。

## 目的和影響

- 新版 Codex 可正常保留 GPT-5.6 Sol、Terra、Luna 或之後由 catalog 提供嘅模型。
- 對話切換時會優先保持資料庫完整，降低對話消失、重複、無法恢復或長時間黑畫面風險。
- 使用中 profile 不會被背景同步或側欄清理程序直接改寫。

## 安全與私隱

- 沒有加入、修改或提交任何 API key、登入 token、Cookie、`auth.json` 或真實對話內容。
- 測試只使用 `/tmp` 內建立嘅假 profile 與假 SQLite。
