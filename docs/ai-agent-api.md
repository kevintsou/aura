# Aura AI Agent API 規格

> 版本 1 · 2026-09-29
> 對象：想把**自己的 AI Agent** 接進 Aura 的人。

Aura 完全免費，不提供 AI 服務，也**不經過任何 Aura 伺服器**。手機直接連到使用者設定的端點，費用由使用者自己的帳號支付。

## 1. 一句話說明

**Aura 使用 OpenAI Chat Completions 協定，並且支援 tool calling。** 只要端點講這個協定，就能接進 Aura：OpenAI 本身、OpenRouter、Ollama、LM Studio、vLLM、LiteLLM，或是你自己寫的 Agent 服務。

```
┌──────────── 手機（Aura）────────────┐          ┌────── 你的端點 ──────┐
│ 使用者問題                            │ ──(1)──► │ POST /chat/completions│
│                                      │ ◄─(2)─── │ 回傳 tool_calls       │
│ 在本機 SQLite 上執行工具（算好數字）   │          │                       │
│                                      │ ──(3)──► │ 帶著 tool 結果再呼叫   │
│ 顯示回答                              │ ◄─(4)─── │ 回傳最終答案           │
└──────────────────────────────────────┘          └───────────────────────┘
```

**帳本資料不會整份上傳。** 你的 Agent 看得到的只有：使用者的問題，以及它主動要求、由手機算好的工具結果。

## 2. 設定（在 App 的「設定 → AI 連線」）

| 欄位 | 說明 |
|---|---|
| 服務 | OpenAI（預設）、OpenRouter、Ollama、LM Studio、**自訂 Agent API** |
| API 網址 | API 的根路徑，例如 `https://api.openai.com/v1`。Aura 會呼叫 `{網址}/chat/completions` 和 `{網址}/models`。**非本機的網址必須使用 https** |
| API 金鑰 | 放在 `Authorization: Bearer <key>` 標頭。只存在手機的 Keychain／Keystore，而且每個服務各存一把 |
| 模型 | 放在請求的 `model` 欄位。自訂 Agent 可以拿它來分流，例如 `family-finance-agent` |
| 讓 AI 查詢帳本 | 關閉時不送 `tools`。適合不支援 tool calling 的端點 |
| 分享發票品項明細 | 關閉時，工具結果不含商品明細，`search_invoice_items` 工具也不會提供 |
| 自訂 HTTP 標頭 | 每次請求都會帶上，例如 `X-Agent-Id: xxx` |

## 3. 請求

### 3.1 `POST {網址}/chat/completions`

```jsonc
{
  "model": "family-finance-agent",
  "messages": [
    { "role": "system", "content": "你是 Aura 記帳 App 裡的消費分析助理……今天是 2026-09-29……" },
    { "role": "user", "content": "這個月花最多錢的是哪些分類？" }
  ],
  "tools": [ /* 見第 5 節 */ ],
  "tool_choice": "auto"
}
```

- 為了相容各家實作，Aura **不送** `temperature`、`max_tokens`、`stream`。如果需要，由你的 Agent 自己決定。
- `messages` 包含同一段對話的完整歷史，包括之前的 tool 呼叫和結果。Agent 可以完全無狀態。
- system prompt 會說明今天的日期和回答原則。你的 Agent 可以不理它，換成自己的。

### 3.2 回應：要求執行工具

```jsonc
{
  "choices": [{
    "finish_reason": "tool_calls",
    "message": {
      "role": "assistant",
      "content": null,
      "tool_calls": [{
        "id": "call_1",
        "type": "function",
        "function": {
          "name": "aggregate_transactions",
          "arguments": "{\"group_by\":\"main_category\",\"date_from\":\"2026-09-01\",\"date_to\":\"2026-09-30\"}"
        }
      }]
    }
  }]
}
```

Aura 會在手機上執行每一個 tool call，然後把結果加進對話再呼叫一次：

```jsonc
{ "role": "tool", "tool_call_id": "call_1", "content": "{\"total\":4010,\"groups\":[…]}" }
```

參數錯誤時（例如分類名稱不存在），`content` 會是 `{"error":"…"}`。Agent 可以根據錯誤訊息修正參數後重試。

### 3.3 回應：最終答案

```jsonc
{
  "choices": [{
    "finish_reason": "stop",
    "message": { "role": "assistant", "content": "九月支出 NT$4,010，最多的是購物娛樂……" }
  }],
  "usage": { "prompt_tokens": 1234, "completion_tokens": 56 }
}
```

`usage` 是選填的；有提供的話，App 會顯示這次回答用了多少 token。

### 3.4 `GET {網址}/models`（選填）

回傳 `{"data":[{"id":"model-a"}, …]}`，App 的「取得模型清單」按鈕會用到。沒有實作也沒關係，使用者可以直接輸入模型名稱。

### 3.5 限制

- 一個問題最多 **8 輪**工具呼叫，超過就中止並提示使用者。
- 每個請求的逾時是 90 秒。
- 錯誤回應請用 HTTP 狀態碼，body 用 `{"error":{"message":"…"}}`，App 會把 message 顯示給使用者。

## 4. 隱私保證（Aura 這一側）

- **絕對不會送出**：手機條碼載具號碼、賣方統編、API 金鑰以外的任何憑證。
- **會遮蔽**：備註和地點裡 10 位數以上的數字（卡號、帳號），只保留末 4 碼，例如 `****3456`。
- 使用者可以在對話裡點開每一個工具呼叫，看到「AI 的查詢參數」和「送給 AI 的資料」的完整 JSON。

## 5. 工具

所有金額都是**本國幣（TWD）**，最多兩位小數，數字由手機計算。日期格式是 `YYYY-MM-DD`，而且包含起訖兩天。分類、帳戶、專案名稱必須跟 `get_ledger_overview` 列出的完全一樣（不分大小寫）。

### 5.1 `get_ledger_overview`

沒有參數。回傳帳本的結構：

```jsonc
{
  "today": "2026-09-29", "base_currency": "TWD", "transaction_count": 17158,
  "first_date": "2016-05-31", "last_date": "2026-09-29",
  "accounts": [{ "name": "現金", "type": "cash", "currency": "TWD", "balance": 2880, "balance_known": true }],
  "expense_categories": { "生活費": ["早餐", "午餐"] },
  "income_categories": { "工作收入": ["薪資收入"] },
  "projects": ["旅遊支出"], "needs_review_count": 104, "invoice_items_available": true
}
```

`balance` 是今天的餘額，以該帳戶的幣別表示。`balance_known` 為 `false` 表示使用者還沒設定實際餘額，這個數字只是紀錄的加總，可能不準，回答時要提醒使用者。

### 5.2 `aggregate_transactions`

加總收入或支出，**不含帳戶間轉帳**。

| 參數 | 說明 |
|---|---|
| `group_by`（必填） | `main_category`、`subcategory`、`account`、`project`、`seller`、`year`、`month`、`week`、`day` |
| `kind` | `expense`（預設）或 `income` |
| `date_from`、`date_to`、`category`、`account`、`project`、`keyword` | 篩選條件 |
| `top_n` | 非時間類的分組最多列幾組，預設 20、上限 100。時間類的分組全部列出，依時間排序 |

回傳：`total`、`count`、`group_count`，以及 `groups: [{key, total, count, share(%)}]`。

### 5.3 `search_transactions`

列出交易明細。

| 參數 | 說明 |
|---|---|
| `kind` | `expense`、`income`、`transfer`、`any`（預設） |
| `min_amount`、`max_amount` | 本國幣金額 |
| `sort` | `date_desc`（預設）、`date_asc`、`amount_desc` |
| `limit` | 預設 30、上限 100 |
| 其他 | 同 5.2 的篩選條件 |

每筆交易的欄位：`date`、`kind`、`amount_base`、`amount`＋`currency`（外幣帳戶才有）、`category`（`主分類/子分類`）、`account`、`to_account`、`project`、`note`、`place`、`seller`、`invoice_items`（允許分享時）、`needs_review`。

### 5.4 `search_invoice_items`（使用者允許分享發票品項時才提供）

| 參數 | 說明 |
|---|---|
| `keyword`（必填） | 商品名稱的關鍵字 |
| `date_from`、`date_to` | 篩選日期 |
| `limit` | 預設 50 |

回傳：`matched_items`、`total_amount`、`total_quantity`，以及 `items: [{date, seller, name, quantity, amount, category}]`。

## 6. 範例 Agent

[`examples/mock_agent.py`](../examples/mock_agent.py) 是一個沒有使用 LLM、只依規則回應的最小實作，只用 Python 標準函式庫。它示範了完整的來回流程：收到問題 → 要求 `aggregate_transactions` → 收到手機算好的結果 → 回答。

```bash
python3 examples/mock_agent.py 8766
# App：設定 → AI 連線 → 自訂 Agent API → http://localhost:8766/v1，模型填 mock-agent
# Android 模擬器請用 http://10.0.2.2:8766/v1
```

要做成真正的 Agent，把 `decide_tool_call` 和 `decide_answer` 換成你自己的 LLM 呼叫或商業邏輯即可。你也可以在 Agent 內部接上其他資料來源，例如股價或匯率，再和 Aura 的帳本工具一起使用。

## 7. 相容性備註

| 服務 | 狀態 |
|---|---|
| OpenAI（`https://api.openai.com/v1`） | 預設。需要 API 金鑰 |
| OpenRouter | 模型名稱要加供應商前綴，例如 `openai/gpt-6-sol` |
| Ollama | 要選支援 tool calling 的模型，例如 qwen3、llama3.1。手機連電腦時，網址要填電腦的區網 IP |
| LM Studio | 啟動 local server，模型名稱照 LM Studio 顯示的填 |
| 不支援 tools 的端點 | 關閉「讓 AI 查詢帳本」。這時 AI 看不到帳本，只能根據對話內容回答 |
