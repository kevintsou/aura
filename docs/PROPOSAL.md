# Aura 記帳 App — 專案提案 (Proposal)

> 狀態：草案 v0.2 · 2026-09-29（v0.2：加入真實 CSV 樣本的分析結果、AI 消費分析 Agent、訂閱制）
> 目標：開發一款手機記帳 App，**功能上涵蓋 CWMoney**，並且**能讀寫 CWMoney 的備份檔與匯出檔**，讓 CWMoney 使用者可以無痛搬家，必要時也能搬回去。另外提供一個 **AI 消費分析 Agent**，作為**訂閱制**的付費功能。

---

## 1. 背景與動機

CWMoney（理財筆記）是台灣最老牌的記帳 App 之一，最早由 Lib Inc. 開發，後來轉由 CMoney／Money錢管家經營，目前有兩條產品線：

| 版本 | 形態 | 備註 |
|---|---|---|
| **CWMoney 經典版**（Android `com.lib.cwmoneyex`、iOS id555612465） | 一次付費、傳統記帳本 | 沒有預算、共享帳本、隱藏帳戶等進階功能 |
| **CWMoney 新版 3.x**（Android `com.lib.cwmoney`、iOS id1029760973） | 免費＋VIP 訂閱（個人約 NT$90／月，家庭約 NT$120／月） | 有進階報表、隱藏帳戶、共享帳本、去廣告 |

官方說明**新版的資料無法轉回經典版**。另外，CSV 匯出只能拿來看，不能用來還原；完整的備份／還原要靠 SQLite 資料庫檔或 CWCloud 雲端。使用者如果想換 App 或長期保存資料，就會被綁住。這正是 Aura 的切入點：

1. **資料主權**：本地優先，完整讀寫 CWMoney 的資料檔，不綁定雲端帳號。
2. **無痛轉移**：匯入 CWMoney 備份以後，分類、帳戶、專案、歷史紀錄都跟原本一模一樣。
3. **可逆**：能匯出成 CWMoney 可以還原的備份檔，降低使用者試用的心理門檻。
4. **AI 分析**：CWMoney 只有圖表；Aura 讓使用者直接用自然語言問自己的帳，例如「這三個月外食比去年多多少？」，並主動提供洞察。

---

## 2. 研究發現：CWMoney 的檔案格式

| 格式 | 用途 | 已知資訊 | 可信度 |
|---|---|---|---|
| **`.sdb`** | Android 舊版的本機備份 | 就是 **SQLite 3** 資料庫，檔名像 `cwmoney_db_20120502.sdb`，用 SQLite Browser 可以直接打開 | 高（多個來源都這樣說） |
| **`.iDB` / `.idb`** | iOS 備份；Android 改版後也改用這個 | 一樣是 SQLite，可以透過 Dropbox 在 Android 和 iOS 之間還原 | 高 |
| **「CSV」匯出** | 匯出報表 | ✅ **已用真實樣本完整驗證**（經典版，10 年、17,158 筆）。有兩代格式：舊版是 Big5 的 Excel HTML 表格，新版是 **Big5-HKSCS 的 CSV**，而且引號沒有跳脫，一般的 CSV parser 會讀錯。兩代都是 15 欄：日期、類別、主分類、子分類、帳戶、專案、金額、匯率、小計、建檔時間、GPS、地址、發票號碼、轉帳（0/1/2）、備註。轉帳拆成「收入＋支出」兩列，約 2% 只有單邊。沒有期初餘額、預算、週期、照片，所以不能當完整備份。詳見 [`cwmoney-format.md`](cwmoney-format.md) | 高 |
| **CWCloud** | 官方雲端備份／同步 | 私有 API，沒有公開文件 | — |

**已知的資料表線索**（來自社群轉檔教學，還沒實際驗證）：

- 主要的記帳紀錄放在 **`rec_table`**（有些文章寫成 `Rec_table`）。
- 欄位用 `i_` 當前綴，已知有 `i_item`、`i_create`、`i_photo`、`i_invoice`、`i_gps`、`i_rev1`、`i_rev2`。其中 `rev` 看起來是保留欄位。
- 其他資料表（帳戶、分類、專案、週期、預算）的名稱和欄位**網路上找不到公開資料**。

> ⚠️ **關鍵風險**：完整的 schema 沒有公開。要做到「完全相容」，需要拿**真實的備份檔樣本**（最好經典版＋新版、Android＋iOS 都有，而且涵蓋轉帳、外幣、信用卡、週期、專案、照片、發票等情境）來逆向分析。這是第 0 階段要處理的事（見第 8 節）。

---

## 3. 功能範圍（對照 CWMoney）

優先級：**P0** = MVP 一定要有，**P1** = 第一個正式版，**P2** = 之後再做。

### 3.1 記帳核心
| 功能 | CWMoney | Aura 優先級 |
|---|---|---|
| 收入／支出／轉帳 | ✅ | P0 |
| 兩層分類（分類 → 子分類），可以自訂 | ✅ | P0 |
| 多帳戶：現金、銀行、信用卡、電子支付、證券 | ✅ | P0（證券的持股損益放 P2） |
| 多幣別、自訂匯率 | ✅ | P0 存資料／P1 做完整的換算報表 |
| 專案（例如旅遊）橫跨不同分類的統計 | ✅ | P0 |
| 備註、商家 | ✅ | P0 |
| 照片記帳 | ✅ | P1 |
| GPS 位置 | ✅ | P2 |
| 週期性收支（薪水、帳單），可以設定頻率 | ✅ | P1 |
| 隱藏帳戶 | VIP | P1 |

### 3.2 預算與報表
| 功能 | CWMoney | Aura 優先級 |
|---|---|---|
| 每月總預算、分類預算與進度 | ✅ | P1 |
| 圓餅圖、長條圖、趨勢圖 | ✅ | P0 基本版／P1 進階版 |
| 週報、月報、年報 | ✅ | P1 |
| 帳戶餘額與資產總覽 | ✅ | P0 |

### 3.3 發票（台灣特有）
| 功能 | CWMoney | Aura 優先級 |
|---|---|---|
| 掃描紙本發票 QR Code 記帳 | ✅ | P1 |
| 綁定手機條碼載具，自動同步發票 | ✅ | P2（要向財政部電子發票平台申請 API） |
| 發票對獎 | ✅ | P2 |

### 3.4 資料與相容性（Aura 的核心差異）
| 功能 | Aura 優先級 |
|---|---|
| **匯入** CWMoney `.sdb`／`.idb` 備份 | **P0** |
| **匯出** CWMoney 可以還原的 `.idb` 備份 | **P1**（要先確認 schema 的版本差異） |
| 匯入／匯出 CWMoney 格式的 CSV（格式已經驗證，**M1 優先做**） | P0 |
| Aura 自己的完整備份（加密 zip：SQLite＋照片） | P0 |
| 自選雲端備份（iCloud Drive、Google Drive、Dropbox） | P1 |
| 多裝置同步、共享帳本 | P2 |
| 密碼／生物辨識鎖 | P1 |
| 桌面小工具、快速記帳 | P2 |

### 3.5 AI 消費分析 Agent（訂閱功能 · Aura Pro）
| 功能 | 說明 | 優先級 |
|---|---|---|
| **自然語言問答** | 「上個月外食花多少？」、「今年加油比去年多嗎？」、「哪張信用卡刷最多？」。Agent 查使用者的帳以後回答，附上數字和圖表 | P1 |
| **月報洞察** | 每月自動產生摘要：花費變化最大的分類、異常支出、跟預算的差距 | P1 |
| **固定支出偵測** | 從歷史紀錄找出週期性的扣款（例如串流訂閱、房貸、管理費），一鍵轉成週期收支 | P1 |
| **發票品項自動分類** | 發票明細 → 分類／子分類。先用使用者自己的歷史建立規則（本機、免費），規則對不到才交給 LLM | P1 |
| **異常與重複扣款警示** | 同一個商家短時間內有同金額的消費、金額遠高於平常等 | P2 |
| **預算建議與模擬** | 依照過去 N 個月的資料建議預算；「如果每月少外食 3 次會怎樣」 | P2 |
| **資產與現金流分析** | 股票、定存、外幣帳戶的現金流與配息整理 | P2 |

**明確不做**：接官方的 CWCloud 私有 API（有法律和穩定性風險）、繳費中心、CMoney 的投資內容服務。

---

## 4. 技術架構

### 4.1 技術選型（建議）

| 層 | 選擇 | 理由 |
|---|---|---|
| App 框架 | **Flutter (Dart)** | 一套程式碼同時做 iOS 和 Android；UI 一致；畫圖表的生態成熟（`fl_chart`） |
| 本機資料庫 | **SQLite**，用 `drift` 存取 | CWMoney 本身就是 SQLite，匯入時可以直接 `ATTACH` 備份檔用 SQL 轉換；drift 有型別安全和 migration |
| 金額 | 用**整數的最小單位**（minor units）或 Decimal 字串存 | 避免浮點數誤差；匯入 CWMoney 的 REAL 欄位時要明確做捨入 |
| 狀態管理 | Riverpod | 好測試、社群主流 |
| 同步（P2） | 以 CRDT／變更日誌為基礎，後端再評估（Supabase 或自建） | 本地優先，同步是加值功能 |
| **AI Gateway 後端** | TypeScript（Node）或 Python（FastAPI），部署在 Cloud Run 或 Fly.io；Postgres 只存帳號、訂閱權限和用量 | 一個很薄的服務，**不存任何帳務資料** |
| **LLM 供應商** | **預設 OpenAI GPT 系列**，透過 provider adapter 抽象化，也可以換成其他供應商或自架的開源模型 | 可以依成本和品質切換，不被單一供應商綁住 |
| **訂閱與付款** | App Store／Google Play 的應用程式內購買（IAP），用 RevenueCat 管理 | 數位服務依商店規定必須走 IAP；RevenueCat 負責收據驗證和跨平台的訂閱狀態 |

> 替代方案：React Native (Expo) 加 `expo-sqlite`。如果團隊比較熟 TypeScript 可以選這個，4.2 節的相容層設計不受影響。

### 4.2 分層設計

```
┌──────────────── UI（Flutter）────────────────┐
│ 記帳 · 報表 · 預算 · 帳戶 · 設定               │
├──────────────── Domain ──────────────────────┤
│ Transaction · Account · Category · Project    │
│ Recurring · Budget · Invoice · Currency       │
├──────────────── Repository ──────────────────┤
│              Aura SQLite（正規化）             │
├──────────── Interop（相容層）─────────────────┤
│ CwmSqliteImporter  CwmSqliteExporter           │
│ CwmCsvImporter     CwmCsvExporter              │
│ SchemaDetector（辨識經典版／新版、各個版本）      │
└───────────────────────────────────────────────┘
```

```
┌──────── 手機（本地優先）──────────┐        ┌────────── Aura AI Gateway ──────────┐
│ AI 對話 UI                        │  HTTPS │ 驗證 → 訂閱權限 → 配額與限流          │
│ Local Tool Runner ◄───────────────┼────────┤ Agent 執行迴圈（工具呼叫）            │
│   · query_transactions(filter)    │  SSE   │ Provider Adapter ──► OpenAI（預設）  │
│   · aggregate(group_by, period)   │        │                  └─► 其他／自架模型   │
│   · detect_recurring()            │        │ 用量計費 · 只記錄不含個資的 log         │
│ 個資遮蔽（載具號碼、帳號）          │        └─────────────────────────────────────┘
└───────────────────────────────────┘                ▲ RevenueCat webhook（訂閱狀態）
```

**設計原則：內部 schema 和 CWMoney 格式分開。** Aura 用自己乾淨、正規化的資料模型；所有 CWMoney 的格式細節都集中在 `interop` 這一層。好處是：

- 不會被 CWMoney 的歷史包袱（`i_rev1`、`i_rev2` 這類保留欄位、編碼問題）綁住。
- CWMoney 如果改版，只要加一個 adapter，不用改核心。

### 4.3 無損 round-trip 策略

要做到「匯入 → 匯出 → CWMoney 還原」的結果**跟原檔一致**：

1. 每筆匯入的資料都保留 `source_id`（CWMoney 原本的主鍵）。
2. Aura 模型沒用到的欄位，整列原封不動存到 `legacy_payload`（JSON）。
3. 匯出時先還原 `legacy_payload`，再用 Aura 的資料覆蓋有對應的欄位。
4. 用 **golden file 測試**：樣本檔 → 匯入 → 匯出 → 逐表、逐欄和原檔做 diff，差異必須是 0，或者在允許清單裡。

### 4.4 AI Agent 設計：工具在手機上執行

Aura 是本地優先的 App，帳務資料**不上傳到我們的伺服器**。AI Agent 的做法是「**後端負責思考，手機負責查資料**」：

1. 使用者提問。App 把問題加上**資料摘要**（有哪些分類和帳戶、資料的日期範圍，不含明細）送到 Gateway。
2. Gateway 檢查訂閱和配額後，交給 LLM。LLM 決定要呼叫哪個工具，例如 `aggregate(kind=expense, category="生活費/午餐", period="2026-06..2026-08", group_by=month)`。
3. Gateway 把工具呼叫**轉回手機**，由手機在本機的 SQLite 上執行。
4. 手機只回傳**彙總結果**或必要的少量明細，而且會先**遮蔽個資**（載具號碼、統編、帳號一律遮蔽；帳戶名稱可以用別名代替）。
5. LLM 產生回答，用 SSE 串流回手機，附帶結構化的圖表資料，由 App 自己畫圖。

**好處：** 伺服器上沒有帳務資料，資安和個資法的風險最小；使用者可以在設定裡看到每次送出了什麼。
**代價：** 每個問題要來回好幾次，所以工具要設計得夠粗（一次彙總好），把來回次數壓在 2–3 次以內。

**成本控制：**
- 分類、固定支出偵測這類工作**先在本機用規則和統計處理**，LLM 只負責理解問題和寫出說明。
- 依任務選模型：簡單的分類用小模型，問答和洞察用主力模型。
- 每個訂閱方案有每月配額；Gateway 做計量和限流，用 prompt caching 降低重複成本。

**供應商與隱私：**
- 預設用 OpenAI API（API 的資料依官方條款預設不拿去訓練），另外申請 zero data retention。
- Provider Adapter 讓我們可以切換到其他供應商或自架的開源模型，例如企業版或重視隱私的使用者。
- 第一次使用前要**明確同意**，並說明會送出哪些資料。

---

## 5. 核心資料模型（初稿）

```text
Account     id, name, type(cash|bank|credit|epay|securities|other),
            currency, initial_balance, hidden, sort, source_id, legacy_payload
Category    id, parent_id?, kind(expense|income), name, icon, sort, source_id
Project     id, name, archived, source_id
Txn         id, kind(expense|income|transfer), date, time,
            amount(decimal, 可以是負數), currency, fx_rate_display?,
            base_amount(decimal, 本國幣；以 CWMoney 的「小計」為準),
            account_id, to_account_id?(transfer), to_amount?(跨幣別),
            fee_of?(手續費所屬的轉帳), category_id?,
            project_id?, place?, note?, invoice_id?,
            photo_path?, lat?, lng?, created_at?, updated_at,
            needs_review(例如單邊轉帳), source_id, legacy_payload
Recurring   id, template(Txn 欄位), rule(RRULE), next_run, end
Budget      id, period(month), category_id?(null=總預算), amount_minor
Invoice     id, number, date, seller_tax_id, seller_name, seller_address,
            carrier(敏感，要遮蔽), txn_id?
InvoiceItem invoice_id, name, qty(decimal), amount(decimal, 可以是負數)
FxRate      currency, rate_to_base, updated_at
-- 後端（只有這些，沒有帳務資料）
User        id, auth_provider, created_at
Entitlement user_id, plan(free|pro), expires_at, source(revenuecat)
AiUsage     user_id, month, requests, input_tokens, output_tokens, cost
```

CWMoney 的欄位怎麼對應到這個模型，詳見 [`cwmoney-format.md` §4](cwmoney-format.md)。

> 金額從 v0.1 的「整數最小單位」改成 **decimal**。原因是真實資料裡有外幣小數，而且「小計」不等於「金額 × 匯率」，必須兩個值都照原樣保存。

---

## 6. 商業模式：訂閱制

| 方案 | 內容 | 價格（暫定） |
|---|---|---|
| **免費** | 所有記帳功能、報表、預算、**CWMoney 匯入／匯出**、本機備份 | 免費 |
| **Aura Pro** | AI 消費分析 Agent（有每月配額）、月報洞察、發票自動分類、雲端硬碟自動備份；之後加入多裝置同步和共享帳本 | 建議 NT$99–149／月，或 NT$990–1,290／年，**等 AI 成本試算後再決定**（參考：CWMoney VIP 個人方案約 NT$90／月） |

**原則：**
- **資料匯出永遠免費。** 這是「資料主權」的承諾，也是吸引 CWMoney 使用者搬家的主要理由。
- 付款一律走 App Store／Google Play 的 IAP，由 RevenueCat 管理。Gateway 用 RevenueCat webhook 和 API 確認訂閱權限。
- 提供首次 7 天免費試用。配額用完以後可以降級到比較便宜的模型，或加購額度，避免使用者突然完全不能用。
- **單位經濟**：每個 Pro 使用者每月的 LLM 成本要控制在訂閱費的 20–30% 以內。M5 會用真實資料的查詢模式做成本試算。

---

## 7. 品質與測試

- **相容性測試集**：`test/fixtures/cwmoney/` 放去除個資的樣本備份（經典版／新版 × Android／iOS × 幾個不同版本），CI 每次都跑匯入和 round-trip。
- **邊界情況**：中文編碼（社群回報過 CSV 亂碼要用 UTF-8／Big5 判斷）、時區、跨幣別轉帳、已刪除的分類、上萬筆資料的匯入效能。
- **單元測試**：金額捨入、匯率換算、週期規則展開、預算計算。
- **隱私**：樣本檔要先去識別化（`scripts/anonymize_cwm.py`）才能放進 repo；真實樣本只在本機測試，**不 commit**。
- **CSV 匯入的驗收標準**：用真實樣本（17,158 筆）測試。解析成功率 100%；轉帳配對率 ≥ 97%，剩下的標記為 `needs_review`；依帳戶加總的「小計」要和 CWMoney 完全一致。
- **AI 評測集**：準備一組問題和標準答案（例如「2025 年外食總額」），每次換模型或改 prompt 都要跑，比較正確率和成本。

---

## 8. 里程碑

| 階段 | 內容 | 產出 | 預估 |
|---|---|---|---|
| **M0 格式研究** | ✅ CSV 已完成；🔲 `.sdb`／`.idb` 還在等樣本 | `docs/cwmoney-format.md`、`inspect` CLI 工具 | 1–2 週 |
| **M1 骨架＋匯入** | Flutter 專案、Aura schema、**CWMoney CSV 匯入（兩代格式）**、帳戶與紀錄列表；拿到樣本後再加 `.sdb`／`.idb` 匯入 | 可以安裝的內測版，能匯入並瀏覽 CWMoney 的資料 | 3 週 |
| **M2 記帳 MVP** | 記一筆、編輯、刪除；轉帳、專案、多幣別；基本報表；Aura 自己的備份 | Alpha | 4 週 |
| **M3 V1** | 週期收支、預算、進階報表、照片、App 鎖、隱藏帳戶、雲端硬碟備份、**匯出 CWMoney `.idb`** | Beta → 上架 | 5 週 |
| **M5 AI＋訂閱** | AI Gateway、本機工具執行、自然語言問答、月報洞察、固定支出偵測、發票自動分類；RevenueCat 訂閱；成本試算與 AI 評測集 | Aura Pro 上線 | 5 週（可以和 M3 部分並行） |
| **M4 V2** | 發票載具同步與對獎、GPS、多裝置同步、共享帳本、桌面小工具、AI 預算模擬 | 2.x | 之後再排 |

---

## 9. 風險與對策

| 風險 | 影響 | 對策 |
|---|---|---|
| schema 沒有公開、版本很多 | 無法「完全」相容 | M0 盡量多收集樣本；SchemaDetector 做版本分流；用 `legacy_payload` 保底 |
| CWMoney 改版造成格式變動 | 匯入失敗 | adapter 架構＋清楚的錯誤訊息＋讓使用者回報樣本的管道 |
| 匯出的檔案 CWMoney 無法還原 | 使用者資料風險 | 匯出前後做自我驗證；在實機上測還原；介面上標示為 Beta |
| 法律與商標 | 下架風險 | 只做檔案格式互通，不使用 CWMoney 的名稱、Logo、UI 素材，不碰私有雲端 API；上架文案用「支援匯入 CWMoney 備份檔」這類描述性用語 |
| 電子發票 API 要申請 | P2 功能卡住 | 提早向財政部電子發票整合服務平台申請 AppID |
| AI 的回答有錯（算錯金額） | 使用者失去信任 | **數字一律由本機工具計算**，LLM 只負責理解問題和寫說明；回答附上可以點進去看的明細；建立 AI 評測集 |
| 財務資料送到第三方 LLM | 個資和信任風險 | 工具在手機上執行、只送彙總、遮蔽個資；明確同意；zero data retention；可以切換供應商 |
| LLM 成本超過訂閱收入 | 虧錢 | 配額、依任務選模型、本機優先處理、prompt caching、上線前做成本試算 |
| 商店的 IAP 規定和抽成（15–30%） | 毛利降低 | 定價時把抽成算進去；年繳方案提高留存 |

---

## 10. 需要你決定或提供的事

1. **樣本檔**（最重要）：CSV 匯出已經分析完成（見 [`cwmoney-format.md`](cwmoney-format.md)）。還需要一份或多份 CWMoney 備份檔（`.idb`／`.sdb`），最好跟 CSV 是同一個時間點的。內容最好涵蓋轉帳、外幣、信用卡、專案、週期、預算、照片和發票紀錄。如果有隱私上的顧慮，可以另外開一個測試帳本來產生。
2. **目標版本**：你的樣本是**經典版**（`cwmoney_ex2`）。新版 3.x 也要支援嗎？
3. **平台**：iOS 和 Android 都要嗎？技術選型用 Flutter 可以嗎？
4. **同步和共享帳本**：要列進 V1 嗎？這會決定要不要一開始就做後端。
5. ~~商業模式~~ → 已確定**訂閱制**（見第 6 節）。定價區間可以嗎？
6. **「openGPT model」是指哪一種？**
   - (a) **OpenAI 的 GPT API**（雲端、依用量計費）。本提案目前**先照這個設計**。
   - (b) **OpenAI 的開源權重模型**（gpt-oss），由我們自己架設（成本固定、資料完全不出我們的機房，但要管 GPU）。
   - Provider Adapter 兩種都支援，差別在 M5 的部署和成本模型。
7. **AI 可以看到多少資料？** 只送彙總（建議），還是可以送品項明細（分類準確度比較高，但隱私風險比較大）？
8. **App 名稱**：就用 **Aura** 嗎？

---

## 參考資料

- [CWMoney 經典版 — Google Play](https://play.google.com/store/apps/details?id=com.lib.cwmoneyex&hl=en_US)
- [CWMoney 新版 — Google Play](https://play.google.com/store/apps/details?id=com.lib.cwmoney&hl=en_US)
- [CWMoney 新版 — App Store](https://apps.apple.com/tw/app/cwmoney-%E5%AD%98%E9%8C%A2%E8%A8%98%E5%B8%B3-%E7%99%BC%E7%A5%A8%E8%A8%98%E5%B8%B3-%E7%90%86%E8%B2%A1%E5%88%86%E6%9E%90-%E7%AE%A1%E7%90%86%E9%A0%90%E7%AE%97/id1029760973)
- [CWMoney 經典版 — App Store](https://apps.apple.com/tw/app/cwmoney%E7%B6%93%E5%85%B8%E7%89%88-%E7%90%86%E8%B2%A1%E7%AD%86%E8%A8%98-%E7%99%BC%E7%A5%A8%E6%8E%83%E6%8F%8F-%E9%9B%B2%E7%AB%AF%E5%82%99%E4%BB%BD-%E5%AD%98%E9%8C%A2%E8%A8%98%E5%B8%B3/id555612465)
- [CWMoney 資料轉移 AndroMoney 方式（sdb、rec_table）](https://shyamyu.blogspot.com/2012/05/cwmoney-andromoney_3672.html)
- [CWMoney 匯入 AndroMoney — PTT Android](https://www.ptt.cc/bbs/Android/M.1466309603.A.E9D.html)
- [CWMoney 備份 Android 無法還原 iOS — PTT iOS](https://www.ptt.cc/bbs/iOS/M.1436424030.A.029.html)
- [CWMoney 資料轉移 AndroMoney 解決亂碼問題](https://guli86400.pixnet.net/blog/posts/12105598552)
- [用 Python 將 CWMoney 的 sdb 整合進 idb](http://chl.ddns.net/?p=387)
- [最經典的記帳軟體 CWMoney 2.0 — 電腦玩物](https://www.playpcesor.com/2015/05/cwmoney-20.html)
- [記帳 App 推薦：CWMoney 使用教學 — 蘋果仁](https://applealmond.com/posts/158997)
- [CWMoney 記帳 3.0 VIP 全新功能 — Money錢雜誌](https://money.cmoney.tw/article/11810)
- [CWMoney 常見問題](https://money.cmoney.tw/cwmoney-landing-page/faq?id=23)
