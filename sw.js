/* 賴貓法庭：接收推播通知 */
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) { e.waitUntil(self.clients.claim()); });

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
      if (c.url.indexOf(self.registration.scope) === 0 && c.url.indexOf("/next/") < 0 && "focus" in c) {
        return c.focus().then(function (w) { return w && "navigate" in w ? w.navigate(url) : w; });
      }
    }
    return self.clients.openWindow(url);
  }));
});
