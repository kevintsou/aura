# 雲端備份

Aura 沒有自己的伺服器。雲端備份是把加密過的 `.aura` 備份檔（格式見 [`backup-format.md`](backup-format.md)）放到使用者自己的雲端：Google 雲端硬碟，或任何 WebDAV 服務。

## 運作方式

- **一定加密**：設定雲端備份時要設一組至少 8 個字的備份密碼，每份雲端備份都用它加密（PBKDF2-HMAC-SHA256 + AES-256-GCM）。雲端服務只看得到檔名和大小。
- 密碼存在手機的安全儲存區（Keychain／Android Keystore），自動備份時不用再輸入。換手機時要輸入同一個密碼才能還原。
- **什麼時候備份**：打開 App 或切回 App 時，如果距離上次成功已經超過設定的間隔（每天／每週），就在背景上傳一份。沒有常駐的背景工作，所以很久沒打開 App 就不會備份。失敗會記下原因，顯示在「備份與還原」，一小時後再自動重試。
- **檔名**：`aura-YYYYMMDD-HHMMSS.aura`。只保留最近 N 份（5／10／20／30），**只刪除符合這個檔名的檔案**，資料夾裡的其他檔案不會動。
- **換手機**：新手機設定好同一個雲端和密碼後，如果雲端上最新的備份比手機上的資料多，會先問要不要還原，避免空的新手機把舊手機的備份擠掉。帳本是空的時候不會上傳。
- 停用雲端備份會刪掉手機上存的密碼，雲端上的備份留著。

## WebDAV

填 WebDAV 網址、帳號、密碼和資料夾名稱（預設 `Aura`，不存在會自動建立）就能用，不需要任何註冊。常見的網址：

| 服務 | WebDAV 網址 |
|---|---|
| Nextcloud／ownCloud | `https://你的網域/remote.php/dav/files/帳號` |
| Synology NAS | `https://NAS 位址:5006`（要先在套件中心安裝 WebDAV Server） |
| QNAP NAS | `https://NAS 位址/webdav` |
| Koofr | `https://app.koofr.net/dav/Koofr` |
| InfiniCloud（TeraCLOUD） | `https://（伺服器）.teracloud.jp/dav/` |

- 網路上的伺服器一定要用 https；http 只允許區網位址（`192.168.x.x`、`10.x.x.x`、`*.local` 等），給家裡的 NAS 用。
- 建議使用服務提供的「應用程式密碼」，不要用主要密碼。
- 網頁版要伺服器允許跨網域請求（CORS）才能用，手機版沒有這個限制。

## Google 雲端硬碟

備份放在使用者雲端硬碟裡的「Aura 記帳備份」資料夾，使用者自己看得到、也能手動下載。App 只要求 `drive.file` 權限：**只能看到 App 自己建立的檔案**，看不到雲端硬碟裡的其他東西。這個權限不屬於 Google 的「敏感」範圍，上架時不需要額外的安全審查。

Google 登入需要發行 App 的人（也就是你）在 Google Cloud 註冊 OAuth 用戶端。沒有設定的版本，「Google 雲端硬碟」選項會是灰色的。

### 設定步驟

1. 到 [Google Cloud Console](https://console.cloud.google.com/) 建立專案，啟用 **Google Drive API**。
2. 設定 **OAuth 同意畫面**：使用者類型選「外部」，範圍加入 `https://www.googleapis.com/auth/drive.file`。
3. 建立 OAuth 用戶端 ID：
   - **網頁應用程式**：Android 用它當 `serverClientId`。
   - **Android**：套件名稱 `app.aura.aura`，填入簽署金鑰的 SHA-1。`keytool -list -v -keystore <keystore>` 可以查到；上架 Google Play 的話，要用 Play 應用程式簽署金鑰的 SHA-1。
   - **iOS**：Bundle ID 填 App 的 Bundle ID。
4. iOS：把 iOS 用戶端的「反轉用戶端 ID」（`com.googleusercontent.apps.xxxx`）加到 `app/ios/Runner/Info.plist` 的 `CFBundleURLTypes`：

   ```xml
   <key>CFBundleURLTypes</key>
   <array>
     <dict>
       <key>CFBundleURLSchemes</key>
       <array><string>com.googleusercontent.apps.xxxx</string></array>
     </dict>
   </array>
   ```

5. 建置時用 `--dart-define` 傳入用戶端 ID：

   ```bash
   flutter build apk --dart-define=GOOGLE_SERVER_CLIENT_ID=xxxx.apps.googleusercontent.com
   flutter build ipa --dart-define=GOOGLE_IOS_CLIENT_ID=yyyy.apps.googleusercontent.com
   ```

   用戶端 ID 不是秘密（它本來就會出現在 App 裡），但不同發行者要用自己的，所以不寫死在程式碼裡。

## iCloud

自動備份到 iCloud Drive 需要 Apple 開發者帳號的 iCloud 權限和原生程式碼，目前還沒做。iPhone 使用者可以在「建立備份檔」時選擇 iCloud Drive 手動存放。

## 程式碼

- `app/lib/cloud/cloud_target.dart`：雲端資料夾的介面（測試連線、列出、上傳、下載、刪除）。
- `app/lib/cloud/webdav.dart`、`google_drive.dart`：兩種實作，測試用模擬的伺服器（`app/test/cloud_targets_test.dart`）。
- `app/lib/cloud/cloud_backup.dart`：排程、加密、保留份數、還原（`app/test/cloud_backup_test.dart`）。
