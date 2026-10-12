// 賴貓法庭：發送網頁推播（Web Push）
// 後台（Apps Script，之後是 Supabase 新版）把要發的通知和訂閱交給這裡，這裡負責加密和送出。
// 需要的 Secrets（Supabase → Edge Functions → Secrets）：
//   VAPID_PUBLIC_KEY、VAPID_PRIVATE_KEY、PUSH_SECRET
// 這個 function 不用登入（Verify JWT 關閉），改用 PUSH_SECRET 驗證來源。
import webpush from "npm:web-push@3.6.7";

const PUB = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const PRIV = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const SECRET = Deno.env.get("PUSH_SECRET") ?? "";
const SUBJECT = "https://loreouo11.github.io/Meow-Court/";

if (PUB && PRIV) webpush.setVapidDetails(SUBJECT, PUB, PRIV);

type Sub = { endpoint: string; keys: { p256dh: string; auth: string } };
type Msg = { subs: Sub[]; title: string; body?: string; url?: string; tag?: string };

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });
}

function same(a: string, b: string) {
  if (!a || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);
  if (!PUB || !PRIV || !SECRET) return json({ ok: false, error: "missing secrets" }, 500);

  let body: { secret?: string; messages?: Msg[] };
  try { body = await req.json(); } catch { return json({ ok: false, error: "bad json" }, 400); }
  if (!same(String(body.secret ?? ""), SECRET)) return json({ ok: false, error: "unauthorized" }, 401);

  const messages = Array.isArray(body.messages) ? body.messages.slice(0, 20) : [];
  const gone: string[] = [];
  const errors: string[] = [];
  let sent = 0;

  const jobs: Promise<void>[] = [];
  for (const m of messages) {
    const payload = JSON.stringify({
      title: String(m.title ?? "賴貓法庭").slice(0, 120),
      body: String(m.body ?? "").slice(0, 400),
      url: String(m.url ?? SUBJECT),
      tag: m.tag ? String(m.tag).slice(0, 60) : undefined,
    });
    for (const s of (m.subs ?? []).slice(0, 10)) {
      if (!s?.endpoint?.startsWith("https://") || !s.keys?.p256dh || !s.keys?.auth) continue;
      jobs.push(
        webpush.sendNotification(s, payload, { TTL: 86400, urgency: "high" })
          .then(() => { sent++; })
          .catch((e: { statusCode?: number; body?: string; message?: string }) => {
            if (e.statusCode === 404 || e.statusCode === 410) gone.push(s.endpoint);
            else errors.push(`${e.statusCode ?? "?"} ${String(e.body ?? e.message ?? e).slice(0, 200)}`);
          }),
      );
    }
  }
  await Promise.all(jobs);
  return json({ ok: true, sent, gone, errors });
});
