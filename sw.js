/* 賴貓法庭：接收推播通知（舊版備份 legacy/ 有自己的 sw.js） */
/* 離線畫面：先把「休庭中」頁面和七七存起來；沒有網絡時打開網站就顯示這頁 */
var OFFLINE = "meow-offline-v1";
var OFFLINE_FILES = ["offline.html", "qiqi.svg"];

self.addEventListener("install", function (e) {
  self.skipWaiting();
  e.waitUntil(caches.open(OFFLINE).then(function (c) { return c.addAll(OFFLINE_FILES); }).catch(function () {}));
});
self.addEventListener("activate", function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) { return k.indexOf("meow-offline-") === 0 && k !== OFFLINE; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});

/* 只處理自己網站的 GET：照常上網拿最新的，拿不到才用存起來的。Supabase 等其他網址完全不經這裡。 */
self.addEventListener("fetch", function (e) {
  var req = e.request;
  if (req.method !== "GET") return;
  var url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  var nav = req.mode === "navigate";
  var name = url.pathname.split("/").pop();
  if (!nav && OFFLINE_FILES.indexOf(name) < 0) return;
  e.respondWith(fetch(req).catch(function () {
    return caches.open(OFFLINE).then(function (c) {
      return nav ? c.match("offline.html") : c.match(name);
    }).then(function (r) { return r || Response.error(); });
  }));
});

self.addEventListener("push", function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { title: "賴貓法庭", body: e.data ? e.data.text() : "" }; }
  var opts = {
    body: d.body || "",
    icon: "icon-192.png",
    badge: "icon-192.png",
    data: { url: d.url || self.registration.scope }
  };
  if (d.tag) opts.tag = d.tag;
  e.waitUntil(self.registration.showNotification(d.title || "賴貓法庭", opts));
});

self.addEventListener("notificationclick", function (e) {
  e.notification.close();
  var url = (e.notification.data && e.notification.data.url) || self.registration.scope;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (list) {
    for (var i = 0; i < list.length; i++) {
      var c = list[i];
      if (c.url.indexOf(self.registration.scope) === 0 && "focus" in c) {
        return c.focus().then(function (w) { return w && "navigate" in w ? w.navigate(url) : w; });
      }
    }
    return self.clients.openWindow(url);
  }));
});
