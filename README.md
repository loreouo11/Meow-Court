# 賴貓法庭 Meow Court

情侶法庭網站：開罰單、自首、申訴、遞申請書、送賴貓卡，罰款存入結婚和旅行基金。
網站放在 GitHub Pages：<https://loreouo11.github.io/Meow-Court/>，資料存在 Supabase（免費版）。

## 檔案

- `index.html`：網站本體（單一檔案）
- `qiqi.svg`：七七（法官貓）插圖
- `sw.js`、`manifest.webmanifest`：加到主畫面、接收手機通知
- `supabase/schema.sql`：完整的資料庫設定（新專案整份貼到 SQL Editor 執行一次）
- `supabase/00X_*.sql`：之後的更新，舊專案按順序執行
- `supabase/functions/push`：發送手機通知的 Edge Function
- `supabase/import_from_sheet.py`：把舊版 Google 試算表的資料搬進 Supabase
- `next/`：測試版的舊網址，現在會自動跳回主網址
- `legacy/`、`apps-script/`：舊版（Google 試算表後台）的備份，換版前的最後狀態是 commit `bdf0a67`

## 登入

共用一個密碼，再選「你是哪一位」。背後是兩個 Supabase 帳號 `a@meowcourt.app`、`b@meowcourt.app`（假 Email，密碼相同），
對應 `members.slot` 的 a / b。Supabase → Authentication 要關閉「Confirm email」。

## 手機通知

1. Supabase → Edge Functions 部署 `supabase/functions/push`，關閉「Verify JWT」，
   Secrets 新增 `VAPID_PUBLIC_KEY`、`VAPID_PRIVATE_KEY`、`PUSH_SECRET`（公開金鑰要和 `index.html` 的 `VAPID_PUBLIC` 一樣）。
2. SQL Editor 執行 `supabase/006_push.sql`，再填一次設定：
   ```sql
   insert into public.push_config (url, secret)
   values ('https://phctyqitfywvstsdicyh.supabase.co/functions/v1/push', '這裡填 PUSH_SECRET')
   on conflict (id) do update set url = excluded.url, secret = excluded.secret;
   ```
3. iPhone：Safari 打開網站 →「分享」→「加入主畫面」，從主畫面打開 → 設定 →「手機通知」→「發送測試通知」。

## 舊版（Google 試算表後台）

舊版備份在 <https://loreouo11.github.io/Meow-Court/legacy/>，仍然連著原本的 Apps Script，只在需要回頭查資料時用。

### 設定 Google 試算表後台

1. 開一個新的 Google 試算表，改名為「賴貓法庭」。
2. 選單「擴充功能」→「Apps Script」，刪除原有內容，貼上 `apps-script/Code.gs` 的全部內容。
3. 把第 7 行的 `PASSCODE` 改成你們兩人才知道的密碼，然後儲存。
   這個密碼只放在 Apps Script，不要寫進 GitHub。
4. 上方函式選單選 `setup`，按「執行」。第一次會要求授權：選帳戶 →「進階」→「前往（不安全）」→「允許」。
5. 「部署」→「新增部署作業」→ 類型「網頁應用程式」→ 執行身分「我」→ 存取權「所有人」→「部署」。
6. 複製「網頁應用程式網址」（`https://script.google.com/macros/s/…/exec`）。

### 接上網站

把 `legacy/index.html` 裡的 `var API_URL = "";` 改成上一步的網址，提交到 `main`。
舊版網址：<https://loreouo11.github.io/Meow-Court/legacy/>

### 之後修改 Code.gs

改完要「部署」→「管理部署作業」→ 鉛筆圖示 →「版本」選「新版本」→「部署」，網址不會變。

### 手機推播通知

1. Supabase → Edge Functions 部署 `supabase/functions/push`，並關閉「Verify JWT」。
2. Edge Functions → Secrets 新增 `VAPID_PUBLIC_KEY`、`VAPID_PRIVATE_KEY`、`PUSH_SECRET`。
   公開金鑰要和 `legacy/index.html` 的 `VAPID_PUBLIC` 一樣；私密金鑰不要放進 GitHub。
3. Apps Script 指令碼屬性新增 `PUSH_URL`（function 網址）和 `PUSH_SECRET`（同上）。
4. 每部手機從主畫面打開網站 → 設定 →「開啟通知」。
