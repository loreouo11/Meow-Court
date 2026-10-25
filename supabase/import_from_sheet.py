#!/usr/bin/env python3
"""
把舊版 Google 試算表（Settings / Rules / Tickets / Cards）轉成可以在
Supabase SQL Editor 執行的 SQL，搬進一個新的情侶空間。

用法：
  python3 import_from_sheet.py 試算表.xlsx --email-a 第一位的Email --email-b 第二位的Email > import.sql
  （選用）--skip id1,id2：不搬這些舊罰單（填試算表 Tickets 的 id，例如測試時開的）

  --email-a / --email-b 是兩個人在新版登入用的 Email（必須已經登入過一次）。
  第一位 = 試算表 Settings 裡的 nameA，第二位 = nameB。

舊版還沒有申請書，你們用 $0 的罰單／規則來代替（例如「想要貼貼」罰 $0）。
匯入時會自動轉換：
  - $0 而且像申請的規則（想要…、貼貼、攬攬、抱抱、啵啵、親親、宵夜…）→ 標成已刪除，不會出現在法規
  - 用這些規則開的 $0 罰單 → 變成申請書（自首＝自己申請；開給對方＝開單的人申請），
    已入帳的算「已實現」，還在等的算「等對方審批」；已刪除／已否決的不搬
  - 其他 $0 規則和罰單（例如「冷落對方」）照舊當罰單

產生的 SQL 含有你們的私人紀錄，不要提交到 GitHub。
這份 SQL 可以重複執行：會先刪掉上次匯入的同一個空間再重新匯入。
"""
import argparse
import hashlib
import sys
import uuid

import openpyxl

NS = uuid.UUID("6f1c2b8e-5a0d-4c47-9b1e-1f0c3a7d2e55")  # 固定命名空間，讓同一份資料每次產生相同的 ID


def q(v):
    """SQL 字串常值；None 或空字串 → NULL。"""
    if v is None or str(v).strip() == "":
        return "null"
    return "'" + str(v).replace("'", "''") + "'"


def qt(v):
    """沒有時區的時間（香港時間）→ timestamptz。"""
    return "null" if v in (None, "") else q(str(v).strip() + "+08:00")


def qs(v):
    """非 NULL 文字欄位。"""
    return q("" if v is None else v) if v not in (None, "") else "''"


def num(v, default="0"):
    if v in (None, ""):
        return default
    float(v)  # 檢查是數字
    return str(v)


def b(v):
    return "true" if str(v).strip().lower() == "true" else "false"


def uid(kind, old):
    return str(uuid.uuid5(NS, f"{kind}:{old}"))


REQ_WORDS = ("想要", "想吃", "貼貼", "攬攬", "抱抱", "啵啵", "親親", "錫錫", "宵夜", "陪我")


def request_like(title, amount):
    try:
        zero = float(amount or 0) == 0
    except ValueError:
        zero = False
    return zero and any(w in str(title or "") for w in REQ_WORDS)


def req_icon(title):
    t = str(title)
    if any(w in t for w in ("啵啵", "親親", "錫錫")):
        return "kiss"
    if any(w in t for w in ("貼貼", "攬攬", "抱抱")):
        return "hug"
    if any(w in t for w in ("宵夜", "吃", "食")):
        return "food"
    if "散步" in t:
        return "walk"
    return "heart"


def rows(ws):
    data = [r for r in ws.iter_rows(values_only=True) if any(c not in (None, "") for c in r)]
    head = [str(h) for h in data[0]]
    return [dict(zip(head, r)) for r in data[1:]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xlsx")
    ap.add_argument("--email-a", required=True)
    ap.add_argument("--email-b", required=True)
    ap.add_argument("--skip", default="", help="不搬的舊罰單 id，用逗號分隔")
    a = ap.parse_args()

    wb = openpyxl.load_workbook(a.xlsx, data_only=True)
    st = {r["key"]: r["value"] for r in rows(wb["Settings"])}
    rules, tickets, cards = rows(wb["Rules"]), rows(wb["Tickets"]), rows(wb["Cards"])

    cid = str(uuid.uuid5(NS, "couple:" + hashlib.sha1(a.email_a.lower().encode()).hexdigest()))
    out = []
    w = out.append
    w("-- 由 import_from_sheet.py 產生。含私人資料，請勿提交到 GitHub。")
    w("begin;")
    w(f"""do $$ begin
  if (select count(*) from auth.users where lower(email) in (lower({q(a.email_a)}), lower({q(a.email_b)}))) <> 2 then
    raise exception '找不到這兩個 Email 的帳號，請兩個人都先在新版登入一次';
  end if;
end $$;""")
    # 兩個人原本所在的（測試）情侶空間先離開；空間沒人了就整個刪除
    who = f"(select id from auth.users where lower(email) in (lower({q(a.email_a)}), lower({q(a.email_b)})))"
    w(f"create temp table _old_couples on commit drop as select couple_id from public.members where user_id in {who};")
    w(f"delete from public.members where user_id in {who};")
    w("""delete from public.couples c where c.id in (select couple_id from _old_couples)
  and not exists (select 1 from public.members m where m.couple_id = c.id);""")
    w("update public.couples c set invite_code = public._new_code() where c.id in (select couple_id from _old_couples) and c.invite_code is null;")

    w(f"""insert into public.couples (id, invite_code, name_a, name_b, discord_a, discord_b, start_date,
  wedding_name, wedding_target, travel_name, travel_target) values (
  {q(cid)}, null, {qs(st.get('nameA'))}, {qs(st.get('nameB'))}, {qs(st.get('discordA'))}, {qs(st.get('discordB'))},
  {q(str(st.get('start') or '')[:10])}::date, {qs(st.get('weddingName') or '結婚基金')}, {num(st.get('weddingTarget'), '50000')},
  {qs(st.get('travelName') or '旅行基金')}, {num(st.get('travelTarget'), '8000')});""")
    w(f"""insert into public.members (couple_id, user_id, slot)
  select {q(cid)}, id, 'a' from auth.users where lower(email) = lower({q(a.email_a)});""")
    w(f"""insert into public.members (couple_id, user_id, slot)
  select {q(cid)}, id, 'b' from auth.users where lower(email) = lower({q(a.email_b)});""")

    rule_ids, req_rules = set(), set()
    for r in rules:
        rule_ids.add(str(r["id"]))
        if request_like(r["title"], r["amount"]):
            req_rules.add(str(r["id"]))
            r = dict(r, status="deleted", change=None, newTitle=None, newAmount=None, changeBy=None)
        w(f"""insert into public.rules (id, couple_id, title, amount, status, by_slot, created_at, change, new_title, new_amount, change_by) values (
  {q(uid('rule', r['id']))}, {q(cid)}, {qs(r['title'])}, {num(r['amount'])}, {q(r['status'] or 'active')}, {q(r['by'])}, {qt(r['createdAt'])},
  {qs(r.get('change'))}, {qs(r.get('newTitle'))}, {num(r.get('newAmount'), 'null')}, {qs(r.get('changeBy'))});""")

    n_req = 0
    skip = {x.strip() for x in a.skip.split(",") if x.strip()}
    tickets = [t for t in tickets if str(t["id"]) not in skip]
    for t in tickets:
        rid = str(t["ruleId"]) if t.get("ruleId") not in (None, "") else None
        if (rid in req_rules or request_like(t["title"], t["amount"])) and float(t["amount"] or 0) == 0:
            if t["status"] not in ("paid", "waived", "pending", "appeal"):
                continue  # 已刪除／已否決的不搬
            asker = t["to"] if b(t.get("self")) == "true" else t["from"]
            to = "b" if asker == "a" else "a"
            title = str(t["title"]).replace("不敢說", "").strip() or str(t["title"])
            done = t["status"] in ("paid", "waived")
            w(f"""insert into public.requests (id, couple_id, from_slot, to_slot, title, icon, note, status, created_at, done_at) values (
  {q(uid('request', t['id']))}, {q(cid)}, {q(asker)}, {q(to)}, {qs(title[:20])}, {q(req_icon(title))}, {qs(t.get('note'))},
  {q('done' if done else 'pending')}, {qt(t['ts'])}, {qt(t.get('updatedAt') or t['ts']) if done else 'null'});""")
            n_req += 1
            continue
        if rid and rid not in rule_ids:
            rid = None
        w(f"""insert into public.tickets (id, couple_id, from_slot, to_slot, rule_id, title, amount, note, fund, status, final,
  is_self, used_card, appeal, void_by, created_at, updated_at) values (
  {q(uid('ticket', t['id']))}, {q(cid)}, {q(t['from'])}, {q(t['to'])}, {q(uid('rule', rid)) if rid else 'null'}, {qs(t['title'])},
  {num(t['amount'])}, {qs(t.get('note'))}, {q(t.get('fund') or 'wedding')}, {q(t['status'])}, {num(t.get('final'), 'null')},
  {b(t.get('self'))}, {b(t.get('card'))}, {qs(t.get('appeal'))}, {qs(t.get('voidBy'))}, {qt(t['ts'])}, {qt(t.get('updatedAt') or t['ts'])});""")

    for c in cards:
        w(f"""insert into public.cards (id, couple_id, kind, title, descr, color, icon, owner_slot, from_slot, reason, used, used_at, created_at) values (
  {q(uid('card', c['id']))}, {q(cid)}, {q(c['kind'])}, {qs(c['title'])}, {qs(c.get('desc'))}, {q(c.get('color') or 'pink')}, {qs(c.get('icon'))},
  {q(c['owner'])}, {q(c['from'])}, {qs(c.get('reason'))}, {b(c.get('used'))}, {qt(c.get('usedTs'))}, {qt(c['ts'])});""")

    w(f"""select '匯入完成' as 結果,
  (select count(*) from public.rules where couple_id = {q(cid)}) as 規則,
  (select count(*) from public.tickets where couple_id = {q(cid)}) as 罰單,
  (select count(*) from public.cards where couple_id = {q(cid)}) as 卡片,
  (select count(*) from public.requests where couple_id = {q(cid)}) as 申請書,
  (select coalesce(sum(final), 0) from public.tickets where couple_id = {q(cid)} and status = 'paid' and fund = 'wedding') as 結婚基金,
  (select coalesce(sum(final), 0) from public.tickets where couple_id = {q(cid)} and status = 'paid' and fund = 'travel') as 旅行基金;""")
    w("commit;")
    sys.stdout.write("\n".join(out) + "\n")
    print(f"規則 {len(rules)}（其中 {len(req_rules)} 條像申請，已標成刪除）、罰單 {len(tickets)}（其中 {n_req} 張轉成申請書）、卡片 {len(cards)}", file=sys.stderr)


if __name__ == "__main__":
    main()
