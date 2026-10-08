# 賴貓法庭 Meow Court

情侶罰款基金網站：開罰單、自首、申訴、賴貓卡，罰款存入結婚和旅行基金。
網站放在 GitHub Pages，資料存在自己的 Google 試算表，全程免費。

## 檔案

- `index.html`：網站本體
- `apps-script/Code.gs`：貼到 Google 試算表 Apps Script 的後台程式

## 設定 Google 試算表後台

1. 開一個新的 Google 試算表，改名為「賴貓法庭」。
2. 選單「擴充功能」→「Apps Script」，刪除原有內容，貼上 `apps-script/Code.gs` 的全部內容。
3. 把第 7 行的 `PASSCODE` 改成你們兩人才知道的密碼，然後儲存。
   這個密碼只放在 Apps Script，不要寫進 GitHub。
4. 上方函式選單選 `setup`，按「執行」。第一次會要求授權：選帳戶 →「進階」→「前往（不安全）」→「允許」。
5. 「部署」→「新增部署作業」→ 類型「網頁應用程式」→ 執行身分「我」→ 存取權「所有人」→「部署」。
6. 複製「網頁應用程式網址」（`https://script.google.com/macros/s/…/exec`）。

## 接上網站

把 `index.html` 裡的 `var API_URL = "";` 改成上一步的網址，提交到 `main`。
網站網址：<https://loreouo11.github.io/Meow-Court/>

## 之後修改 Code.gs

改完要「部署」→「管理部署作業」→ 鉛筆圖示 →「版本」選「新版本」→「部署」，網址不會變。
