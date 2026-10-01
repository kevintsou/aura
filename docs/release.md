# 發布正式版

從原始碼到手機的步驟。需要在自己的電腦上做（需要 Android Studio／Xcode）。同一份程式可以建置 Android、iPhone 和網頁版。

只給自己用、不上架的話，看[只給自己用](#只給自己用不上架)就好，不用付任何費用。要上架 App Store／Google Play 再看後面的段落。

## 只給自己用（不上架）

### Android

**第一次準備（只做一次）**

1. 在電腦上安裝 [Flutter](https://docs.flutter.dev/get-started/install) 和 Android Studio，跑 `flutter doctor` 確認 Android 那一項打勾。
2. 產生自己的簽章金鑰：

   ```bash
   keytool -genkey -v -keystore ~/aura-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```

3. 建立 `app/android/key.properties`（已經在 `.gitignore`，**不要 commit**）：

   ```properties
   storePassword=你的密碼
   keyPassword=你的密碼
   keyAlias=upload
   storeFile=/絕對路徑/aura-upload.jks
   ```

4. **把 `.jks` 檔和密碼備份到別的地方**（密碼管理器、雲端硬碟）。

> 為什麼一定要自己的金鑰：Android 只允許用**同一把金鑰**簽章的新版覆蓋安裝。沒有 `key.properties` 時會用電腦上的 debug 金鑰，換電腦或重灌後金鑰就不同了，到時只能先解除安裝舊版，**解除安裝會刪掉手機上的帳本**。

**安裝和更新**

```bash
cd app
flutter build apk --release
```

把 `build/app/outputs/flutter-apk/app-release.apk` 裝到手機，二選一：

- 用 USB 連接手機（手機要開啟「開發人員選項 → USB 偵錯」），執行 `flutter install --release`。
- 把 APK 傳到手機（雲端硬碟、傳訊息給自己），在手機上點開安裝。第一次會要你允許這個 App（例如檔案管理員）「安裝不明應用程式」；Play 安全防護如果跳出警告，選「仍要安裝」。

更新時照同樣方法裝新版就會覆蓋，資料都在。注意：

- **更新前先做一次備份**（設定 → 備份），保險。
- `app/pubspec.yaml` 的 `version` 裡 `+` 後面的數字不能比手機上的小，否則裝不上去；每次加 1 最簡單。
- 一直用同一種建置方式。不要改用 `--split-per-abi`：它會改變版本號碼，之後換回來就會裝不上去。
- 要用 Google 雲端硬碟備份時，OAuth 用戶端要填這把金鑰的 SHA-1（`keytool -list -v -keystore ~/aura-upload.jks -alias upload`），步驟見 [`cloud-backup.md`](cloud-backup.md)。同意畫面維持「測試」狀態、把自己加成測試使用者就能用，但可能每隔幾天就要重新登入；嫌麻煩可以改用 WebDAV 或手動存備份檔。

### iPhone

不付費也可以用一般的 Apple ID 裝到自己的手機，但**每 7 天要接電腦重新安裝一次**（重新安裝不會清掉資料），而且同一支手機最多 3 個這樣裝的 App。付 Apple Developer Program（每年 US$99）的話效期是一年。

1. Mac 上安裝 Flutter 和 Xcode，Xcode → Settings → Accounts 登入 Apple ID。
2. 用 Xcode 打開 `app/ios/Runner.xcworkspace` → Runner → Signing & Capabilities → Team 選「(Personal Team)」。如果顯示 Bundle Identifier 已經被用走，改成別的（例如 `app.aura.aura.你的名字`），**之後不要再改**。
3. iPhone 接上 Mac，在 iPhone 打開「設定 → 隱私權與安全性 → 開發者模式」。
4. `cd app && flutter run --release`。第一次要在 iPhone 的「設定 → 一般 → VPN 與裝置管理」信任你的 Apple ID。
5. 7 天後 App 打不開時，接上電腦再跑一次第 4 步。

## 上架前一次性設定（上架才需要）

### 1. 決定 App 的識別碼

目前是 `app.aura.aura`（Android `applicationId`、iOS Bundle ID）。**第一次上傳後就不能改**，要換成自己的網域（例如 `tw.example.aura`）請先改：

- Android：`app/android/app/build.gradle.kts` 的 `applicationId`
- iOS：Xcode → Runner → Signing & Capabilities → Bundle Identifier

### 2. Android 簽章金鑰

已經照上面「只給自己用」做過就可以跳過。

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
