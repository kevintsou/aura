# Aura 記帳

相容 CWMoney 的免費手機記帳 App（Flutter）。專案說明見 `README.md`，規劃見 `docs/PROPOSAL.md`。

## Git 流程

- **直接 commit 並 push 到 `main`**（`git push origin main`），不要另外開分支，也不要開 PR，除非使用者另外要求。
- 每完成一個功能就 commit 並 push，不要累積到最後。
- push 前先跑過相關套件的測試和 analyze（見下方）。

## 開發

```bash
export PATH=/opt/sdk/flutter/bin:$PATH   # 雲端環境的 Flutter 位置

(cd packages/aura_core && dart analyze && dart test)
(cd packages/aura_ai && dart analyze && dart test)
(cd packages/aura_store && dart analyze && dart test)
(cd app && flutter analyze && flutter test)
```

- `packages/aura_core`：資料模型、報表、CWMoney 匯入／匯出（純 Dart）
- `packages/aura_ai`：AI 連線與帳本工具（純 Dart）
- `packages/aura_store`：SQLite 儲存；schema 只能在 `schema.dart` 的 `migrations` 最後面加新步驟，不能改已發布的步驟
- `app/`：Flutter App
- 帳本行為改動要同時更新 `packages/aura_core/test/ledger_store_contract.dart`（記憶體版和 SQLite 版共用）

## 規則

- **不開源**：版權所有，不要加 LICENSE 檔或開源授權字樣。
- **真實的 CWMoney 匯出檔只能在本機驗證**：不能 commit，也不能在文件、測試、commit 訊息裡引用裡面的內容（載具號碼、發票號碼、專案名稱、備註等）。診斷程式只輸出統計數字。文件和測試資料一律用虛構資料（`packages/aura_core/test/fixtures/`）。
- AI 是使用者自備金鑰（BYOK），預設模型 `gpt-6-sol`；載具號碼、統編不送給 AI，紀錄的 GPS 位置也不送。
- 和使用者溝通用繁體中文。
