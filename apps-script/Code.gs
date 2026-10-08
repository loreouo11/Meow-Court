/**
 * 賴貓法庭 Meow Court 後台（Google Apps Script）
 * 1. 把下面的 PASSCODE 改成你們兩個人才知道的密碼。
 * 2. 在編輯器上方選擇函式「setup」，按「執行」一次，會自動建立四個工作表。
 * 3. 部署 → 新增部署作業 → 類型選「網頁應用程式」→ 執行身分「我」→ 存取權「所有人」。
 */
const PASSCODE = '請改成你們的密碼';
const TZ = 'Asia/Hong_Kong';

const SHEETS = {
  Settings: ['key', 'value'],
  Rules: ['id', 'title', 'amount', 'status', 'by', 'createdAt'],
  Tickets: ['id', 'from', 'to', 'ruleId', 'title', 'amount', 'note', 'fund', 'status', 'final', 'self', 'card', 'appeal', 'ts', 'updatedAt'],
  Cards: ['id', 'kind', 'title', 'desc', 'color', 'owner', 'from', 'reason', 'ts', 'used', 'usedTs', 'icon']
};
const DEFAULTS = {
  nameA: '我', nameB: 'BB', start: '',
  weddingName: '結婚基金', weddingTarget: '50000',
  travelName: '旅行基金', travelTarget: '8000'
};
const COLORS = ['pink', 'mint', 'sky', 'lilac'];
const ICONS = ['star', 'heart', 'hug', 'food', 'coffee', 'movie', 'plane', 'moon', 'gift', 'flower', 'game', 'music'];

/* ---------- 一次性設定 ---------- */
function setup() {
  const ss = SpreadsheetApp.getActive();
  Object.keys(SHEETS).forEach(function (name) {
    let sh = ss.getSheetByName(name) || ss.insertSheet(name);
    if (sh.getLastRow() === 0) {
      sh.appendRow(SHEETS[name]);
      sh.setFrozenRows(1);
      sh.getRange(1, 1, 1, SHEETS[name].length).setFontWeight('bold');
    }
    sh.getRange(1, 1, sh.getMaxRows(), SHEETS[name].length).setNumberFormat('@');
  });
  const st = ss.getSheetByName('Settings');
  const have = readAll('Settings').map(function (r) { return r.key; });
  Object.keys(DEFAULTS).forEach(function (k) {
    if (have.indexOf(k) < 0) st.appendRow([k, DEFAULTS[k]]);
  });
  const blank = ss.getSheetByName('Sheet1') || ss.getSheetByName('工作表1');
  if (blank && blank.getLastRow() === 0 && ss.getSheets().length > 1) ss.deleteSheet(blank);
}

/* ---------- 網頁入口 ---------- */
function doGet() {
  return ContentService.createTextOutput('賴貓法庭後台運作中');
}

function doPost(e) {
  let body;
  try { body = JSON.parse(e.postData.contents); } catch (err) { return out({ ok: false, error: '資料格式錯誤' }); }
  if (!body || body.pass !== PASSCODE) return out({ ok: false, error: '密碼不正確', code: 'auth' });
  const action = body.action || 'get';
  const who = body.who;
  if (action !== 'get' && who !== 'a' && who !== 'b') return out({ ok: false, error: '請先選擇你是誰' });

  const lock = LockService.getScriptLock();
  try {
    lock.waitLock(10000);
    ensureColumns();
    if (action !== 'get') {
      const err = act(action, who, body.data || {});
      if (err) return out({ ok: false, error: err, state: getState() });
    }
    return out({ ok: true, state: getState() });
  } catch (err) {
    return out({ ok: false, error: '系統忙碌，請稍後再試' });
  } finally {
    try { lock.releaseLock(); } catch (e2) {}
  }
}

function out(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

/* ---------- 動作 ---------- */
function act(action, who, d) {
  const op = who === 'a' ? 'b' : 'a';
  const now = stamp();
  let t, r, c;
  switch (action) {
    case 'createTicket': {
      r = getById('Rules', d.ruleId);
      if (!r || r.status !== 'active') return '找不到這條規則';
      const amount = money(d.amount);
      if (amount === null) return '金額不正確';
      const self = d.mode === 'self';
      const paid = self || !d.confirm;
      insert('Tickets', {
        id: uid(), from: who, to: self ? who : op, ruleId: r.id, title: r.title,
        amount: amount, note: text(d.note, 200), fund: d.fund === 'travel' ? 'travel' : 'wedding',
        status: paid ? 'paid' : 'pending', final: paid ? amount : '', self: self, card: false,
        appeal: '', ts: now, updatedAt: now
      });
      return '';
    }
    case 'payTicket':
      t = getById('Tickets', d.id);
      if (!t || t.status !== 'pending' || t.to !== who) return '這張罰單不能這樣處理';
      update('Tickets', t.id, { status: 'paid', final: t.amount, updatedAt: now });
      return '';
    case 'catTicket':
      t = getById('Tickets', d.id);
      if (!t || t.status !== 'pending' || t.to !== who) return '這張罰單不能這樣處理';
      c = readAll('Cards').filter(function (x) { return x.owner === who && x.kind === 'cat' && !bool(x.used); })[0];
      if (!c) return '你沒有賴貓卡';
      update('Cards', c.id, { used: true, usedTs: now });
      update('Tickets', t.id, { status: 'waived', final: 0, card: true, updatedAt: now });
      return '';
    case 'appealTicket':
      t = getById('Tickets', d.id);
      if (!t || t.status !== 'pending' || t.to !== who) return '這張罰單不能申訴';
      if (!text(d.reason, 200)) return '請填寫申訴理由';
      update('Tickets', t.id, { status: 'appeal', appeal: text(d.reason, 200), updatedAt: now });
      return '';
    case 'judgeAppeal':
      t = getById('Tickets', d.id);
      if (!t || t.status !== 'appeal' || t.from !== who) return '只有開罰單的人可以裁決';
      update('Tickets', t.id, d.accept ? { status: 'waived', final: 0, updatedAt: now }
                                       : { status: 'paid', final: Number(t.amount) * 2, updatedAt: now });
      return '';
    case 'proposeRule': {
      const title = text(d.title, 40);
      const amount = money(d.amount);
      if (!title) return '請填寫規則內容';
      if (amount === null) return '金額不正確';
      insert('Rules', { id: uid(), title: title, amount: amount, status: 'pending', by: who, createdAt: now });
      return '';
    }
    case 'agreeRule':
      r = getById('Rules', d.id);
      if (!r || r.status !== 'pending' || r.by === who) return '這條規則要由對方同意';
      update('Rules', r.id, { status: 'active' });
      return '';
    case 'removeRule':
      r = getById('Rules', d.id);
      if (!r || r.status !== 'pending') return '只能移除未生效的提議';
      remove('Rules', r.id);
      return '';
    case 'giveCard': {
      const cat = d.kind === 'cat';
      const reason = text(d.reason, 60);
      if (!reason) return '請填寫送卡原因';
      if (!cat && !text(d.title, 12)) return '請填寫卡片名稱';
      insert('Cards', {
        id: uid(), kind: cat ? 'cat' : 'custom',
        title: cat ? '賴貓卡' : text(d.title, 12),
        desc: cat ? '免除一張罰單' : (text(d.desc, 40) || '兌換內容由你們決定'),
        color: cat ? 'gold' : (COLORS.indexOf(d.color) >= 0 ? d.color : 'pink'),
        owner: op, from: who, reason: reason, ts: now, used: false, usedTs: '',
        icon: cat ? '' : (ICONS.indexOf(d.icon) >= 0 ? d.icon : 'star')
      });
      return '';
    }
    case 'useCard':
      c = getById('Cards', d.id);
      if (!c || c.owner !== who || bool(c.used) || c.kind !== 'custom') return '這張卡不能使用';
      update('Cards', c.id, { used: true, usedTs: now });
      return '';
    case 'saveSettings': {
      const keys = ['nameA', 'nameB', 'start', 'weddingTarget', 'travelTarget'];
      const sh = sheet('Settings');
      const rows = sh.getDataRange().getValues();
      keys.forEach(function (k) {
        if (d[k] === undefined) return;
        let v = k.indexOf('Target') > 0 ? money(d[k]) : text(d[k], 20);
        if (v === null || v === '') return;
        for (let i = 1; i < rows.length; i++) {
          if (rows[i][0] === k) { sh.getRange(i + 1, 2).setValue(String(v)); return; }
        }
        sh.appendRow([k, String(v)]);
      });
      return '';
    }
  }
  return '未知的動作';
}

/* ---------- 讀取 ---------- */
function getState() {
  const settings = {};
  readAll('Settings').forEach(function (r) { settings[r.key] = r.value; });
  return {
    settings: settings,
    rules: readAll('Rules').map(function (r) { r.amount = Number(r.amount) || 0; return r; }),
    tickets: readAll('Tickets').map(function (t) {
      t.amount = Number(t.amount) || 0;
      t.final = t.final === '' ? null : Number(t.final) || 0;
      t.self = bool(t.self); t.card = bool(t.card);
      return t;
    }),
    cards: readAll('Cards').map(function (c) { c.used = bool(c.used); return c; })
  };
}

/* ---------- 工作表工具 ---------- */
// 舊版工作表缺少的欄位會自動補上
function ensureColumns() {
  Object.keys(SHEETS).forEach(function (name) {
    const sh = SpreadsheetApp.getActive().getSheetByName(name);
    if (!sh) return;
    const want = SHEETS[name];
    const have = sh.getLastColumn();
    if (have >= want.length) return;
    const head = have ? sh.getRange(1, 1, 1, have).getValues()[0] : [];
    want.forEach(function (k, i) {
      if (head.indexOf(k) < 0) sh.getRange(1, i + 1).setValue(k).setFontWeight('bold');
    });
  });
}
function sheet(name) {
  const sh = SpreadsheetApp.getActive().getSheetByName(name);
  if (!sh) throw new Error('請先執行 setup');
  return sh;
}
function readAll(name) {
  const values = sheet(name).getDataRange().getValues();
  const head = values.shift() || [];
  return values.filter(function (row) { return row[0] !== ''; }).map(function (row) {
    const o = {};
    head.forEach(function (k, i) {
      const v = row[i];
      o[k] = v instanceof Date ? Utilities.formatDate(v, TZ, "yyyy-MM-dd'T'HH:mm:ss") : String(v);
    });
    return o;
  });
}
function rowOf(name, id) {
  const sh = sheet(name);
  const n = sh.getLastRow() - 1;
  if (n < 1) return -1;
  const ids = sh.getRange(2, 1, n, 1).getValues();
  for (let i = 0; i < ids.length; i++) if (String(ids[i][0]) === String(id)) return i + 2;
  return -1;
}
function getById(name, id) {
  return readAll(name).filter(function (r) { return r.id === String(id); })[0] || null;
}
function insert(name, obj) {
  const sh = sheet(name);
  const row = SHEETS[name].map(function (k) { return obj[k] === undefined ? '' : String(obj[k]); });
  const r = sh.getLastRow() + 1;
  sh.getRange(r, 1, 1, row.length).setNumberFormat('@').setValues([row]);
}
function update(name, id, patch) {
  const r = rowOf(name, id);
  if (r < 0) return;
  const sh = sheet(name);
  const head = SHEETS[name];
  const cur = sh.getRange(r, 1, 1, head.length).getValues()[0];
  head.forEach(function (k, i) { if (k in patch) cur[i] = String(patch[k]); });
  sh.getRange(r, 1, 1, head.length).setNumberFormat('@').setValues([cur.map(String)]);
}
function remove(name, id) {
  const r = rowOf(name, id);
  if (r > 0) sheet(name).deleteRow(r);
}

/* ---------- 小工具 ---------- */
function stamp() { return Utilities.formatDate(new Date(), TZ, "yyyy-MM-dd'T'HH:mm:ss"); }
function uid() { return Utilities.getUuid().slice(0, 8); }
function bool(v) { return v === true || String(v).toUpperCase() === 'TRUE'; }
function text(v, max) { return String(v == null ? '' : v).trim().slice(0, max); }
function money(v) { const n = Number(v); return isFinite(n) && n >= 0 && n <= 100000 ? Math.round(n * 100) / 100 : null; }
