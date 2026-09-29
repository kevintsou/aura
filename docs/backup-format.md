# Aura 備份檔格式（`.aura`）

> 版本 1 · 程式碼在 `packages/aura_core/lib/src/backup.dart`

## 為什麼不直接複製資料庫檔

備份檔是**跟資料庫結構無關的 JSON**：

- 任何版本的 App 都能還原：資料庫升級不會讓舊備份失效。
- 網頁版也能用，因為網頁版沒有 SQLite。
- 還原時直接走 `LedgerStore.replaceAll`，跟匯入 CWMoney 用的是同一條路徑。

## 結構

整個檔案是 gzip 壓縮過的 JSON。

**未加密：**

```jsonc
{
  "format": "aura-backup",
  "version": 1,
  "info": {                        // 預覽用，不需要密碼就能讀
    "createdAt": "2026-09-29T21:30:00.000",
    "accounts": 24,
    "transactions": 14894,
    "firstDate": "2016-05-31",
    "lastDate": "2026-06-18"
  },
  "data": {
    "accounts":     [{"id", "name", "type", "currency", "archived"?, "anchor"?: {"amount", "date"}}],
    "categories":   [{"id", "kind", "name", "parentId"?}],            // 依顯示順序
    "projects":     [{"id", "name"}],
    "transactions": [{"id", "kind", "date", "amount", "baseAmount", "accountId"?, "toAccountId"?,
                      "toAmount"?, "fxRate"?, "categoryId"?, "projectId"?, "note"?, "place"?,
                      "createdAt"?, "feeOf"?, "needsReview"?, "legacyRows"?,
                      "invoice"?: {"number", "sellerTaxId"?, "sellerName"?, "sellerAddress"?,
                                   "carrier"?, "items": [[name, quantity, amount]]}}],
    "meta": {"import.fileName": "…"}   // 不含 backup.* 這類只屬於這支手機的設定
  }
}
```

- 金額一律是**十進位字串**，不會有浮點誤差。
- 日期是 `YYYY-MM-DD`。

**加密（設了密碼時）：** 把 `data` 換成：

```jsonc
"encryption": {
  "kdf":    {"name": "pbkdf2-hmac-sha256", "iterations": 300000, "salt": "base64(16 bytes)"},
  "cipher": {"name": "aes-256-gcm", "nonce": "base64(12 bytes)"}
},
"payload": "base64(AES-GCM(gzip(JSON(data))) + 16-byte tag)"
```

- 先壓縮再加密：加密過的資料無法再壓縮。實測 14,894 筆紀錄約 1.1 MB。
- 迭代次數存在檔案裡，之後可以調高，舊檔案一樣能開。
- `info` 不加密，所以不輸入密碼也能預覽建立時間和筆數。裡面沒有金額、名稱或備註。

## 還原時的檢查

- `format` 必須是 `aura-backup`。`version` 比 App 支援的新時，會請使用者更新 App。
- 密碼錯誤時，GCM 驗證會失敗，顯示「密碼錯誤」。
- 只檢查**參照完整性**：各類 ID 不重複、父分類存在、紀錄指到的帳戶、分類和專案都存在。不套用現在的命名規則，讓舊備份一定能還原。
- 檢查不通過時整份拒絕，不會只還原一半。
- 還原前會先把目前的資料存成手機上的快照。

## 手機上的自動快照

- 存在 App 私有目錄的 `snapshots/<epoch-ms>-<reason>.aura`，格式和備份檔相同，但不加密。
- 時機：每天第一次開啟 App（在背景執行）、匯入 CWMoney 前、還原前。
- 最多保留 7 份。寫入時先寫暫存檔再改名，App 當掉也不會留下寫到一半的檔案。
- 快照只能救回操作失誤。手機遺失時救不回來，那要靠存在別處的備份檔。
