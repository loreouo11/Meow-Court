-- =====================================================================
-- 賴貓法庭 Meow Court — Supabase 資料庫設定（第 1 版）
-- 用法：Supabase 後台 → SQL Editor → New query → 整份貼上 → Run。
--
-- 安全設計：
--   * 每個人用自己的帳號登入，一個帳號只能屬於一個情侶空間。
--   * 所有表格都開啟 RLS：只讀得到自己情侶空間的資料。
--   * 網頁不能直接改表格，所有修改都經過下面的函式（act 等），
--     由資料庫檢查規則（例如不能自己幫自己免罰）。
-- =====================================================================

create extension if not exists pg_net with schema extensions;

-- ---------- 表格 ----------
create table if not exists public.couples (
  id             uuid primary key default gen_random_uuid(),
  invite_code    text unique,
  name_a         text not null default '',
  name_b         text not null default '',
  discord_a      text not null default '',
  discord_b      text not null default '',
  start_date     date,
  wedding_name   text not null default '結婚基金',
  wedding_target numeric(12,2) not null default 50000,
  travel_name    text not null default '旅行基金',
  travel_target  numeric(12,2) not null default 8000,
  created_at     timestamptz not null default now()
);

create table if not exists public.members (
  couple_id  uuid not null references public.couples(id) on delete cascade,
  user_id    uuid not null unique references auth.users(id) on delete cascade,
  slot       text not null check (slot in ('a','b')),
  joined_at  timestamptz not null default now(),
  primary key (couple_id, slot)
);

create table if not exists public.rules (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  title       text not null,
  amount      numeric(12,2) not null,
  status      text not null default 'pending' check (status in ('pending','active','deleted')),
  by_slot     text not null check (by_slot in ('a','b')),
  created_at  timestamptz not null default now(),
  change      text not null default '' check (change in ('','edit','delete')),
  new_title   text not null default '',
  new_amount  numeric(12,2),
  change_by   text not null default ''
);
create index if not exists rules_couple on public.rules(couple_id);

create table if not exists public.tickets (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  from_slot   text not null check (from_slot in ('a','b')),
  to_slot     text not null check (to_slot in ('a','b')),
  rule_id     uuid references public.rules(id) on delete set null,
  title       text not null,
  amount      numeric(12,2) not null,
  note        text not null default '',
  fund        text not null default 'wedding' check (fund in ('wedding','travel')),
  status      text not null check (status in ('pending','paid','waived','appeal','voided')),
  final       numeric(12,2),
  is_self     boolean not null default false,
  used_card   boolean not null default false,
  appeal      text not null default '',
  void_by     text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists tickets_couple on public.tickets(couple_id);

create table if not exists public.cards (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  kind        text not null check (kind in ('cat','custom')),
  title       text not null,
  descr       text not null default '',
  color       text not null default 'pink',
  icon        text not null default '',
  owner_slot  text not null check (owner_slot in ('a','b')),
  from_slot   text not null check (from_slot in ('a','b')),
  reason      text not null default '',
  used        boolean not null default false,
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists cards_couple on public.cards(couple_id);

-- 通知紀錄（網頁讀不到，只給資料庫自己發 Discord 用）
create table if not exists public.notifications (
  id          bigint generated always as identity primary key,
  couple_id   uuid not null references public.couples(id) on delete cascade,
  to_slot     text not null,
  kind        text not null,
  title       text not null,
  body        text not null,
  color       int not null,
  created_at  timestamptz not null default now()
);

-- Discord Webhook（網頁讀不到）。slot / kind 可以填 '*' 代表全部
create table if not exists public.discord_hooks (
  couple_id  uuid not null references public.couples(id) on delete cascade,
  slot       text not null check (slot in ('a','b','*')),
  kind       text not null check (kind in ('cards','tickets','rules','*')),
  url        text not null,
  primary key (couple_id, slot, kind)
);

alter table public.couples       enable row level security;
alter table public.members       enable row level security;
alter table public.rules         enable row level security;
alter table public.tickets       enable row level security;
alter table public.cards         enable row level security;
alter table public.notifications enable row level security;
alter table public.discord_hooks enable row level security;

-- ---------- 小工具 ----------
create or replace function public.my_couple_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select couple_id from public.members where user_id = auth.uid()
$$;

create or replace function public._txt(v jsonb, maxlen int) returns text
language sql immutable set search_path = '' as $$
  select left(btrim(coalesce(v #>> '{}', '')), maxlen)
$$;

create or replace function public._bool(v jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select case when v is null then false
              when jsonb_typeof(v) = 'boolean' then (v #>> '{}')::boolean
              else lower(coalesce(v #>> '{}', '')) in ('true', '1') end
$$;

create or replace function public._money(v jsonb) returns numeric
language plpgsql immutable set search_path = '' as $$
declare n numeric;
begin
  begin n := (v #>> '{}')::numeric; exception when others then return null; end;
  if n is null or n < 0 or n > 100000 then return null; end if;
  return round(n, 2);
end $$;

create or replace function public._uuid(v jsonb) returns uuid
language plpgsql immutable set search_path = '' as $$
begin
  return (v #>> '{}')::uuid;
exception when others then return null;
end $$;

create or replace function public._amt(n numeric) returns text
language sql immutable set search_path = '' as $$ select trim_scale(n)::text $$;

create or replace function public._ts(t timestamptz) returns text
language sql immutable set search_path = '' as $$
  select to_char(t at time zone 'Asia/Hong_Kong', 'YYYY-MM-DD"T"HH24:MI:SS')
$$;

create or replace function public._name(c public.couples, s text) returns text
language sql immutable set search_path = '' as $$
  select coalesce(nullif(case s when 'a' then c.name_a else c.name_b end, ''),
                  case s when 'a' then '我' else 'BB' end)
$$;

-- 6 碼邀請碼（去掉 0/O/1/I 這類容易看錯的字）
create or replace function public._new_code() returns text
language plpgsql volatile set search_path = '' as $$
declare
  abc constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea; code text;
begin
  loop
    b := uuid_send(gen_random_uuid());
    code := '';
    for i in 0..5 loop code := code || substr(abc, 1 + (get_byte(b, i) % 32), 1); end loop;
    exit when not exists (select 1 from public.couples where invite_code = code);
  end loop;
  return code;
end $$;

create or replace function public._ping(cid uuid, to_slot text, title text, body text, color int, kind text) returns void
language sql volatile set search_path = '' as $$
  insert into public.notifications (couple_id, to_slot, title, body, color, kind)
  values (cid, to_slot, title, body, color, kind)
$$;

-- ---------- 讀取全部資料 ----------
create or replace function public.get_state() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare me public.members; c public.couples; paired boolean;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('joined', false, 'paired', false); end if;
  select * into c from public.couples where id = me.couple_id;
  paired := exists (select 1 from public.members where couple_id = c.id and slot <> me.slot);
  return jsonb_build_object(
    'joined', true,
    'paired', paired,
    'me', me.slot,
    'inviteCode', case when paired then null else c.invite_code end,
    'settings', jsonb_build_object(
      'nameA', c.name_a, 'nameB', c.name_b, 'discordA', c.discord_a, 'discordB', c.discord_b,
      'start', coalesce(to_char(c.start_date, 'YYYY-MM-DD'), ''),
      'weddingName', c.wedding_name, 'weddingTarget', c.wedding_target,
      'travelName', c.travel_name, 'travelTarget', c.travel_target),
    'rules', coalesce((select jsonb_agg(jsonb_build_object(
        'id', r.id, 'title', r.title, 'amount', r.amount, 'status', r.status, 'by', r.by_slot,
        'createdAt', public._ts(r.created_at), 'change', r.change, 'newTitle', r.new_title,
        'newAmount', r.new_amount, 'changeBy', r.change_by) order by r.created_at)
      from public.rules r where r.couple_id = c.id and r.status <> 'deleted'), '[]'::jsonb),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'from', t.from_slot, 'to', t.to_slot, 'ruleId', coalesce(t.rule_id::text, ''),
        'title', t.title, 'amount', t.amount, 'note', t.note, 'fund', t.fund, 'status', t.status,
        'final', t.final, 'self', t.is_self, 'card', t.used_card, 'appeal', t.appeal,
        'ts', public._ts(t.created_at), 'updatedAt', public._ts(t.updated_at), 'voidBy', t.void_by) order by t.created_at)
      from public.tickets t where t.couple_id = c.id and t.status <> 'voided'), '[]'::jsonb),
    'cards', coalesce((select jsonb_agg(jsonb_build_object(
        'id', k.id, 'kind', k.kind, 'title', k.title, 'desc', k.descr, 'color', k.color, 'icon', k.icon,
        'owner', k.owner_slot, 'from', k.from_slot, 'reason', k.reason, 'ts', public._ts(k.created_at),
        'used', k.used, 'usedTs', coalesce(public._ts(k.used_at), '')) order by k.created_at)
      from public.cards k where k.couple_id = c.id), '[]'::jsonb)
  );
end $$;

-- ---------- 建立 / 加入情侶空間 ----------
create or replace function public.create_couple() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare cid uuid;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then raise exception '你已經在一個情侶空間裡了'; end if;
  insert into public.couples (invite_code) values (public._new_code()) returning id into cid;
  insert into public.members (couple_id, user_id, slot) values (cid, auth.uid(), 'a');
  return public.get_state();
end $$;

create or replace function public.join_couple(code text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare c public.couples;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then raise exception '你已經在一個情侶空間裡了'; end if;
  select * into c from public.couples where invite_code = upper(btrim(coalesce(code, ''))) for update;
  if not found then raise exception '邀請碼不正確'; end if;
  if exists (select 1 from public.members where couple_id = c.id and slot = 'b') then raise exception '這個情侶空間已經滿了'; end if;
  insert into public.members (couple_id, user_id, slot) values (c.id, auth.uid(), 'b');
  update public.couples set invite_code = null where id = c.id;
  return public.get_state();
end $$;

-- ---------- 所有修改動作（對應舊版 Apps Script 的 act） ----------
create or replace function public.act(action text, d jsonb default '{}'::jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  me public.members; c public.couples; who text; op text;
  t public.tickets; r public.rules; k public.cards;
  v_title text; v_amount numeric; v_temp boolean; v_self boolean; v_paid boolean;
  v_reason text; v_cat boolean; v_desc text; v_date date;
begin
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  who := me.slot; op := case when who = 'a' then 'b' else 'a' end;
  d := coalesce(d, '{}'::jsonb);

  begin
    perform pg_advisory_xact_lock(hashtext(me.couple_id::text));
    select * into c from public.couples where id = me.couple_id;
    if action <> 'saveSettings' and not exists (select 1 from public.members where couple_id = c.id and slot = op) then
      raise exception '要等另一半加入才能使用';
    end if;

    case action
    when 'createTicket' then
      v_temp := public._bool(d->'temp');
      if v_temp then
        v_title := public._txt(d->'title', 40);
        if v_title = '' then raise exception '請填寫罰單原因'; end if;
      else
        select * into r from public.rules where id = public._uuid(d->'ruleId') and couple_id = c.id;
        if not found or r.status <> 'active' then raise exception '找不到這條規則'; end if;
        v_title := r.title;
      end if;
      v_amount := public._money(d->'amount');
      if v_amount is null then raise exception '金額不正確'; end if;
      v_self := coalesce(d->>'mode', '') = 'self';
      v_paid := v_self or (not public._bool(d->'confirm') and not v_temp);  -- 臨時罰單一定要對方確認（自首除外）
      insert into public.tickets (couple_id, from_slot, to_slot, rule_id, title, amount, note, fund, status, final, is_self)
      values (c.id, who, case when v_self then who else op end, case when v_temp then null else r.id end,
              v_title, v_amount, public._txt(d->'note', 200),
              case when d->>'fund' = 'travel' then 'travel' else 'wedding' end,
              case when v_paid then 'paid' else 'pending' end, case when v_paid then v_amount end, v_self);
      if v_self then
        perform public._ping(c.id, op, '🙋 ' || public._name(c, who) || ' 自首了', v_title || ' · $' || public._amt(v_amount) || '，已存入基金。', x'8FD6B4'::int, 'tickets');
      elsif v_paid then
        perform public._ping(c.id, op, '🧾 ' || public._name(c, who) || ' 開了一張罰單給你',
          v_title || ' · $' || public._amt(v_amount) || '，已直接入帳。' || case when public._txt(d->'note', 200) <> '' then E'\n「' || public._txt(d->'note', 200) || '」' else '' end, x'FF6064'::int, 'tickets');
      else
        perform public._ping(c.id, op, case when v_temp then '⚡ 你收到一張臨時罰單' else '🧾 你收到一張罰單' end,
          v_title || ' · $' || public._amt(v_amount) || E'\n來自 ' || public._name(c, who)
          || case when public._txt(d->'note', 200) <> '' then E'\n「' || public._txt(d->'note', 200) || '」' else '' end
          || E'\n請到網站認罰' || case when v_temp then '或申訴。' else '、使用賴貓卡或申訴。' end, x'FF6064'::int, 'tickets');
      end if;

    when 'payTicket' then
      select * into t from public.tickets where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or t.status <> 'pending' or t.to_slot <> who then raise exception '這張罰單不能這樣處理'; end if;
      update public.tickets set status = 'paid', final = t.amount, updated_at = now() where id = t.id;

    when 'catTicket' then
      select * into t from public.tickets where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or t.status <> 'pending' or t.to_slot <> who then raise exception '這張罰單不能這樣處理'; end if;
      if t.rule_id is null then raise exception '臨時罰單不能使用賴貓卡'; end if;
      select * into k from public.cards where couple_id = c.id and owner_slot = who and kind = 'cat' and not used order by created_at limit 1;
      if not found then raise exception '你沒有賴貓卡'; end if;
      update public.cards set used = true, used_at = now() where id = k.id;
      update public.tickets set status = 'waived', final = 0, used_card = true, updated_at = now() where id = t.id;

    when 'appealTicket' then
      select * into t from public.tickets where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or t.status <> 'pending' or t.to_slot <> who then raise exception '這張罰單不能申訴'; end if;
      v_reason := public._txt(d->'reason', 200);
      if v_reason = '' then raise exception '請填寫申訴理由'; end if;
      update public.tickets set status = 'appeal', appeal = v_reason, updated_at = now() where id = t.id;
      perform public._ping(c.id, t.from_slot, '⚖️ ' || public._name(c, who) || ' 提出申訴',
        t.title || ' · $' || public._amt(t.amount) || E'\n理由：' || v_reason || E'\n請到網站裁決。', x'B491ED'::int, 'tickets');

    when 'judgeAppeal' then
      select * into t from public.tickets where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or t.status <> 'appeal' or t.from_slot <> who then raise exception '只有開罰單的人可以裁決'; end if;
      if public._bool(d->'accept') then
        update public.tickets set status = 'waived', final = 0, updated_at = now() where id = t.id;
        perform public._ping(c.id, t.to_slot, '🎉 申訴成功', t.title || '，這張罰單免罰。', x'8FD6B4'::int, 'tickets');
      else
        update public.tickets set status = 'paid', final = t.amount * 2, updated_at = now() where id = t.id;
        perform public._ping(c.id, t.to_slot, '💥 申訴被駁回', t.title || '，罰雙倍 $' || public._amt(t.amount * 2) || '。', x'FF6064'::int, 'tickets');
      end if;

    when 'requestVoid' then
      select * into t from public.tickets where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or t.status <> 'paid' or (t.from_slot <> who and t.to_slot <> who) then raise exception '這張罰單不能刪除'; end if;
      if t.void_by <> '' then raise exception '已經有刪除申請'; end if;
      update public.tickets set void_by = who, updated_at = now() where id = t.id;
      perform public._ping(c.id, op, '🗑️ ' || public._name(c, who) || ' 申請刪除一張罰單',
        t.title || ' · $' || public._amt(t.final) || E'\n請到網站同意或不同意。', x'FE9581'::int, 'tickets');

    when 'answerVoid' then
      select * into t from public.tickets where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or t.status <> 'paid' or t.void_by = '' then raise exception '沒有刪除申請'; end if;
      if public._bool(d->'accept') then
        if t.void_by = who then raise exception '要由對方同意'; end if;
        update public.tickets set status = 'voided', updated_at = now() where id = t.id;
      else
        update public.tickets set void_by = '', updated_at = now() where id = t.id;
      end if;

    when 'proposeRule' then
      v_title := public._txt(d->'title', 40); v_amount := public._money(d->'amount');
      if v_title = '' then raise exception '請填寫規則內容'; end if;
      if v_amount is null then raise exception '金額不正確'; end if;
      insert into public.rules (couple_id, title, amount, status, by_slot) values (c.id, v_title, v_amount, 'pending', who);
      perform public._ping(c.id, op, '📜 ' || public._name(c, who) || ' 提議新規則',
        v_title || ' · $' || public._amt(v_amount) || E'\n請到網站同意或不同意。', x'FFC56B'::int, 'rules');

    when 'editPending' then
      select * into r from public.rules where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or r.status <> 'pending' or r.by_slot <> who then raise exception '只能修改自己還沒生效的提議'; end if;
      v_title := public._txt(d->'title', 40); v_amount := public._money(d->'amount');
      if v_title = '' then raise exception '請填寫規則內容'; end if;
      if v_amount is null then raise exception '金額不正確'; end if;
      update public.rules set title = v_title, amount = v_amount where id = r.id;

    when 'requestRuleChange' then
      select * into r from public.rules where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or r.status <> 'active' then raise exception '找不到這條規則'; end if;
      if r.change <> '' then raise exception '這條規則已經有變更在等待同意'; end if;
      if d->>'kind' = 'delete' then
        update public.rules set change = 'delete', new_title = '', new_amount = null, change_by = who where id = r.id;
        perform public._ping(c.id, op, '📜 ' || public._name(c, who) || ' 想刪除一條規則', r.title || E'\n請到網站同意或不同意。', x'FFC56B'::int, 'rules');
      else
        v_title := public._txt(d->'title', 40); v_amount := public._money(d->'amount');
        if v_title = '' then raise exception '請填寫規則內容'; end if;
        if v_amount is null then raise exception '金額不正確'; end if;
        if v_title = r.title and v_amount = r.amount then raise exception '內容沒有改變'; end if;
        update public.rules set change = 'edit', new_title = v_title, new_amount = v_amount, change_by = who where id = r.id;
        perform public._ping(c.id, op, '📜 ' || public._name(c, who) || ' 想修改一條規則',
          r.title || ' · $' || public._amt(r.amount) || E'\n→ ' || v_title || ' · $' || public._amt(v_amount) || E'\n請到網站同意或不同意。', x'FFC56B'::int, 'rules');
      end if;

    when 'answerRuleChange' then
      select * into r from public.rules where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or r.status <> 'active' or r.change = '' then raise exception '沒有待處理的變更'; end if;
      if public._bool(d->'accept') then
        if r.change_by = who then raise exception '要由對方同意'; end if;
        if r.change = 'delete' then
          update public.rules set status = 'deleted', change = '', new_title = '', new_amount = null, change_by = '' where id = r.id;
        else
          update public.rules set title = r.new_title, amount = r.new_amount, change = '', new_title = '', new_amount = null, change_by = '' where id = r.id;
        end if;
      else
        update public.rules set change = '', new_title = '', new_amount = null, change_by = '' where id = r.id;
      end if;

    when 'agreeRule' then
      select * into r from public.rules where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or r.status <> 'pending' or r.by_slot = who then raise exception '這條規則要由對方同意'; end if;
      update public.rules set status = 'active' where id = r.id;

    when 'removeRule' then
      select * into r from public.rules where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or r.status <> 'pending' then raise exception '只能移除未生效的提議'; end if;
      delete from public.rules where id = r.id;

    when 'giveCard' then
      v_cat := coalesce(d->>'kind', '') = 'cat';
      v_reason := public._txt(d->'reason', 60);
      v_title := public._txt(d->'title', 12);
      v_desc := coalesce(nullif(public._txt(d->'desc', 40), ''), '兌換內容由你們決定');
      if v_reason = '' then raise exception '請填寫送卡原因'; end if;
      if not v_cat and v_title = '' then raise exception '請填寫卡片名稱'; end if;
      insert into public.cards (couple_id, kind, title, descr, color, icon, owner_slot, from_slot, reason)
      values (c.id, case when v_cat then 'cat' else 'custom' end,
              case when v_cat then '賴貓卡' else v_title end,
              case when v_cat then '免除一張罰單' else v_desc end,
              case when v_cat then 'gold' when d->>'color' in ('pink','mint','sky','lilac') then d->>'color' else 'pink' end,
              case when v_cat then '' when d->>'icon' in ('star','heart','hug','food','coffee','movie','plane','moon','gift','flower','game','music') then d->>'icon' else 'star' end,
              op, who, v_reason);
      perform public._ping(c.id, op, case when v_cat then '🐱 你收到一張賴貓卡！' else '🎁 你收到一張「' || v_title || '」' end,
        case when v_cat then '可以免除一張罰單。' else v_desc end || E'\n來自 ' || public._name(c, who) || '：「' || v_reason || '」', x'FFD15C'::int, 'cards');

    when 'useCard' then
      select * into k from public.cards where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or k.owner_slot <> who or k.used or k.kind <> 'custom' then raise exception '這張卡不能使用'; end if;
      update public.cards set used = true, used_at = now() where id = k.id;
      perform public._ping(c.id, k.from_slot, '✨ ' || public._name(c, who) || ' 使用了「' || k.title || '」',
        k.descr || E'\n記得兌現喔！', x'FFD15C'::int, 'cards');

    when 'saveSettings' then
      if public._txt(d->'nameA', 20) <> '' then update public.couples set name_a = public._txt(d->'nameA', 20) where id = c.id; end if;
      if public._txt(d->'nameB', 20) <> '' then update public.couples set name_b = public._txt(d->'nameB', 20) where id = c.id; end if;
      if d ? 'discordA' then update public.couples set discord_a = left(regexp_replace(coalesce(d->>'discordA', ''), '\D', '', 'g'), 20) where id = c.id; end if;
      if d ? 'discordB' then update public.couples set discord_b = left(regexp_replace(coalesce(d->>'discordB', ''), '\D', '', 'g'), 20) where id = c.id; end if;
      if public._txt(d->'start', 20) <> '' then
        begin v_date := public._txt(d->'start', 20)::date; exception when others then v_date := null; end;
        if v_date is not null then update public.couples set start_date = v_date where id = c.id; end if;
      end if;
      if public._money(d->'weddingTarget') is not null then update public.couples set wedding_target = public._money(d->'weddingTarget') where id = c.id; end if;
      if public._money(d->'travelTarget') is not null then update public.couples set travel_target = public._money(d->'travelTarget') where id = c.id; end if;

    else
      raise exception '未知的動作';
    end case;
  exception when raise_exception then
    return jsonb_build_object('ok', false, 'error', sqlerrm, 'state', public.get_state());
  end;
  return jsonb_build_object('ok', true, 'state', public.get_state());
end $$;

-- ---------- Discord 通知：寫入 notifications 時自動送出 ----------
create or replace function public._send_notification() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  site constant text := 'https://loreouo11.github.io/Meow-Court/';
  hook text; did text; c public.couples; link text; ok_id boolean;
begin
  select h.url into hook from public.discord_hooks h
   where h.couple_id = new.couple_id and h.slot in (new.to_slot, '*') and h.kind in (new.kind, '*')
   order by (h.slot = new.to_slot) desc, (h.kind = new.kind) desc limit 1;
  if hook is null then return new; end if;
  select * into c from public.couples where id = new.couple_id;
  did := case when new.to_slot = 'a' then c.discord_a else c.discord_b end;
  ok_id := did ~ '^\d{5,20}$';
  link := site || '#' || case when new.kind in ('cards','tickets','rules') then new.kind else 'home' end;
  perform net.http_post(
    url := hook || case when position('?' in hook) = 0 then '?wait=true' else '&wait=true' end,
    body := jsonb_build_object(
      'username', '賴貓法庭', 'avatar_url', site || 'icon-192.png',
      'content', case when ok_id then '<@' || did || '>' else public._name(c, new.to_slot) end,
      'allowed_mentions', jsonb_build_object('users', case when ok_id then jsonb_build_array(did) else '[]'::jsonb end),
      'embeds', jsonb_build_array(jsonb_build_object(
        'title', new.title, 'description', new.body || E'\n\n[打開賴貓法庭 →](' || link || ')', 'color', new.color, 'url', link))));
  return new;
exception when others then
  return new;  -- 通知失敗不影響主要操作
end $$;

drop trigger if exists send_notification on public.notifications;
create trigger send_notification after insert on public.notifications
  for each row execute function public._send_notification();

-- ---------- 權限 ----------
-- 每個人只看得到自己情侶空間的資料；網頁不能直接新增 / 修改 / 刪除，只能透過上面的函式。
drop policy if exists "read own couple" on public.couples;
create policy "read own couple" on public.couples for select to authenticated using (id = public.my_couple_id());
drop policy if exists "read own couple" on public.members;
create policy "read own couple" on public.members for select to authenticated using (couple_id = public.my_couple_id());
drop policy if exists "read own couple" on public.rules;
create policy "read own couple" on public.rules for select to authenticated using (couple_id = public.my_couple_id());
drop policy if exists "read own couple" on public.tickets;
create policy "read own couple" on public.tickets for select to authenticated using (couple_id = public.my_couple_id());
drop policy if exists "read own couple" on public.cards;
create policy "read own couple" on public.cards for select to authenticated using (couple_id = public.my_couple_id());

revoke all on public.couples, public.members, public.rules, public.tickets, public.cards,
              public.notifications, public.discord_hooks from anon, authenticated;
grant select on public.couples, public.members, public.rules, public.tickets, public.cards to authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.get_state(), public.create_couple(), public.join_couple(text),
                          public.act(text, jsonb), public.my_couple_id() to authenticated;
