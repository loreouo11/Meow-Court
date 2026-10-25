/* 新版已經搬到主網址。這個舊的 next/ 範圍會自己取消通知訂閱並移除，避免同一部手機收到兩次通知。 */
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) {
  e.waitUntil(self.registration.pushManager.getSubscription()
    .then(function (s) { return s && s.unsubscribe(); })
    .catch(function () {})
    .then(function () { return self.registration.unregister(); }));
});
