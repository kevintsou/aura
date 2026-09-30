# AI 評測集

用來比較不同模型、不同 system prompt 或工具改動後，AI 助理答對了多少、用了多少 token。

## 怎麼跑

```bash
cd packages/aura_ai

# OpenAI（金鑰從環境變數讀，不會寫進任何檔案）
OPENAI_API_KEY=sk-... dart run bin/eval.dart --model gpt-6-sol

# 本機模型、自訂 Agent
dart run bin/eval.dart --base-url http://localhost:11434/v1 --model qwen3 --key-env NONE

# 只跑幾題、存下完整報告
dart run bin/eval.dart --only month-total,fuel-year --json report.json

# 只看題目和標準答案，不呼叫 AI
dart run bin/eval.dart --list
```

其他選項：`--header "K: V"`（自訂標頭，可以重複）、`--no-stream`（不用串流）。全部答對時結束代碼是 0，否則是 1，可以放進 CI。

## 怎麼評

- **帳本**：`evalLedger()` 產生的虛構帳本，2025 年 1 月到 2026 年 9 月，約 2,500 筆：三餐、飲料、捷運、加油、停車、房租、水電、日用品、服飾、電影、訂閱、看診、薪水，另外有幾筆特別的（年終獎金、家電、牙醫）。用固定的亂數種子，每次產生的內容都一樣。**完全不含真實資料。**
- **問的方式**：每一題都開新對話，用 App 裡同一套工具和 system prompt，「今天」固定是 2026-09-30。
- **標準答案**：直接從帳本算出來，不經過 AI 和工具，所以工具算錯也會被抓到。
- **判定**：回答裡要出現每一個預期的數字（`4,010`、`NT$4010`、`4010 元`、`1.5 萬` 都算，預設可以差 1 元，平均值可以差 5 元）和關鍵字（例如分類名稱、「多」或「少」）。
- **報告**：每題的對錯、缺少什麼、AI 的回答、工具呼叫次數、token 用量、花費時間；最後是答對率和 token 總數。

## 題目

| id | 問題 | 考的是 |
|---|---|---|
| `month-total` | 2026 年 9 月總共花了多少錢？ | 基本加總 |
| `month-income` | 2026 年 9 月的收入是多少？ | 收入和支出分開 |
| `top-category` | 2026 年 8 月花最多錢的主分類是哪一個？花了多少？ | 排行 |
| `fuel-year` | 2025 年加油總共花了多少？ | 子分類、整年 |
| `fuel-yoy` | 2026 年 1 到 9 月的加油費，比 2025 年同期多還是少？差多少？ | 兩段期間比較 |
| `eating-out-quarter` | 2026 年第三季早餐、午餐、晚餐加起來花了多少？ | 跨分類加總 |
| `monthly-average` | 2026 年 1 到 9 月，平均每個月支出多少？ | 計算平均 |
| `shop-count` | 我在「星光咖啡」總共消費了幾次？ | 關鍵字、筆數 |
| `card-most` | 2026 年藍鯨信用卡和橘貓信用卡，哪一張刷得比較多？ | 依帳戶 |
| `biggest-expense` | 2026 年 8 月金額最大的一筆支出是什麼？多少錢？ | 找單筆紀錄 |
| `bonus` | 2026 年有領到獎金嗎？是哪個月、多少錢？ | 收入明細 |
| `month-change` | 2026 年 9 月的總支出，和 8 月比多還是少？差多少？ | 月對月 |

`packages/aura_ai/test/eval_test.dart` 確認每一題都能用 App 的工具查出答案，並測試評分本身。要加題目，在 `lib/src/eval.dart` 的 `defaultEvalCases()` 加一個 `EvalCase`，標準答案一律從帳本計算。
