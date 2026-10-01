# 發布正式版

從原始碼到 App Store／Google Play 的步驟。需要在自己的電腦上做（這裡需要 Android Studio／Xcode）。

## 上架前一次性設定

### 1. 決定 App 的識別碼

目前是 `app.aura.aura`（Android `applicationId`、iOS Bundle ID）。**第一次上傳後就不能改**，要換成自己的網域（例如 `tw.example.aura`）請先改：

- Android：`app/android/app/build.gradle.kts` 的 `applicationId`
- iOS：Xcode → Runner → Signing & Capabilities → Bundle Identifier

### 2. Android 簽章金鑰

```bash
keytool -genkey -v -keystore ~/aura-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

在 `app/android/key.properties` 建立（這個檔案和 `.jks` 已經在 `.gitignore`，**不要 commit**）：

```properties
storePassword=你的密碼
keyPassword=你的密碼
keyAlias=upload
storeFile=/絕對路徑/aura-upload.jks
```

沒有這個檔案時，正式版會用 debug 金鑰簽章（可以測試，但不能上傳到 Google Play）。建議在 Play Console 開啟 Play App Signing，這把金鑰就只是「上傳金鑰」，遺失還能重設。**金鑰和密碼請另外備份。**

### 3. iOS 簽章

需要 Apple Developer Program 帳號。用 Xcode 打開 `app/ios/Runner.xcworkspace` → Runner → Signing & Capabilities → 選你的 Team，勾選 Automatically manage signing。

### 4. Google 雲端硬碟備份（選用）

要讓「雲端備份 → Google 雲端硬碟」能登入，需要你自己的 OAuth client id，步驟見 [`cloud-backup.md`](cloud-backup.md)。建置時帶入：

```bash
--dart-define=GOOGLE_SERVER_CLIENT_ID=xxx.apps.googleusercontent.com \
--dart-define=GOOGLE_IOS_CLIENT_ID=yyy.apps.googleusercontent.com
```

沒有帶入時，Google 雲端硬碟選項會停用，WebDAV 照常可以用。

### 5. 隱私權政策

把 `app/assets/legal/privacy-policy.md` 的「聯絡信箱」填好，放到一個公開網址，填進兩個商店。App 裡「設定 → 隱私權政策」顯示的是同一份檔案。上架文字和問卷答案見 [`store-listing.md`](store-listing.md)。

## 每次發布

1. 改版本號：`app/pubspec.yaml` 的 `version: 0.1.0+1`（`+` 後面的數字每次上傳都要加 1），以及 `settings_screen.dart` 關於畫面的版本文字。
2. 跑測試：

   ```bash
   (cd packages/aura_core && dart test) && (cd packages/aura_ai && dart test) && \
   (cd packages/aura_store && dart test) && (cd app && flutter analyze && flutter test)
   ```

3. 建置：

   ```bash
   cd app
   flutter build appbundle --release   # Android，上傳 build/app/outputs/bundle/release/app-release.aab
   flutter build ipa --release         # iOS，用 Xcode Organizer 或 Transporter 上傳
   ```

   需要 Google 雲端硬碟時，加上前面的 `--dart-define`。

## 第一次上架前請在實機上確認

這些功能需要真的手機才能測，這裡的開發環境沒辦法驗證：

- [ ] 指紋／臉部解鎖、App 鎖在多工畫面遮住內容（Android 截圖會被擋）
- [ ] 相機掃描發票 QR Code（左右兩個）
- [ ] 拍照／從相簿選照片
- [ ] 記帳時記錄位置（第一次會跳出權限詢問）
- [ ] 每日記帳提醒：Android 13 以上會詢問通知權限；設定 1–2 分鐘後的時間看會不會跳出；重開機後還在
- [ ] Google 雲端硬碟登入、備份、在另一支手機還原
- [ ] WebDAV 備份（例如 Nextcloud）
- [ ] 啟動畫面和 App 圖示（Android 12 以上、Android 13 主題圖示、iOS）
- [ ] 匯入／匯出 CWMoney CSV（從檔案 App 選檔、存檔）
- [ ] 正式版（`--release`）至少完整走一次，因為正式版會壓縮程式碼和資源
