-- 第 6 版更新：新版（Supabase）的手機推播通知。在 SQL Editor 執行一次即可。
--
-- 做法：每部手機在網站「設定 → 手機通知」開啟後，訂閱會存在 push_subs。
-- 之後每次寫入 notifications（開罰單、遞申請書、送卡……本來就會寫，用來發 Discord），
-- 資料庫會順便把通知交給已經部署好的 Edge Function「push」，由它加密送到手機。
--
-- 執行完之後，還要在 SQL Editor 填一次設定（只有一行，網頁讀不到）：
--   insert into public.push_config (url, secret)
--   values ('https://phctyqitfywvstsdicyh.supabase.co/functions/v1/push', '這裡填 PUSH_SECRET')
--   on conflict (id) do update set url = excluded.url, secret = excluded.secret;
-- PUSH_SECRET 要和 Edge Functions → Secrets 裡的一樣（舊版 Apps Script 的「指令碼屬性」也有同一個）。
-- （2026-10-25 新版已換上主網址。之前用 next/ 測試時填過設定的話，執行一次：
--   update public.push_config set site = 'https://loreouo11.github.io/Meow-Court/';）

-- ---------- 資料表 ----------
create table if not exists public.push_subs (
  id          bigint generated always as identity primary key,
  couple_id   uuid not null references public.couples(id) on delete cascade,
  slot        text not null check (slot in ('a','b')),
  user_id     uuid not null references auth.users(id) on delete cascade,
  device_id   text not null,                 -- 每部手機自己產生的隨機代號，重新開啟時用來取代舊訂閱
  device      text not null default '',      -- iPhone / Android / Mac…，方便辨認
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now()
);
create index if not exists push_subs_couple on public.push_subs(couple_id, slot);

create table if not exists public.push_config (
  id      int primary key default 1 check (id = 1),
  url     text not null,
  secret  text not null,
  site    text not null default 'https://loreouo11.github.io/Meow-Court/'
);

alter table public.push_subs   enable row level security;
alter table public.push_config enable row level security;
revoke all on public.push_subs, public.push_config from anon, authenticated;

-- ---------- 送出（給觸發器和「發送測試」共用） ----------
create or replace function public._push_to(cid uuid, to_slot text, title text, body text, kind text) returns text
language plpgsql security definer set search_path = '' as $$
declare cfg public.push_config; subs jsonb; tab text;
begin
  select * into cfg from public.push_config where id = 1;
  if not found then return 'no-config'; end if;

  -- 順手清走手機已經取消的訂閱（push function 回覆的 gone 清單，pg_net 會保留幾個小時）
  begin
    delete from public.push_subs p
     where p.endpoint in (
       select jsonb_array_elements_text(r.content::jsonb -> 'gone')
         from net._http_response r
        where r.created > now() - interval '1 day' and r.content like '%"gone":["%');
  exception when others then null;
  end;

  select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.auth))), '[]'::jsonb)
    into subs
    from (select p.endpoint, p.p256dh, p.auth
            from public.push_subs p
            join public.members m on m.couple_id = p.couple_id and m.slot = p.slot and m.user_id = p.user_id
           where p.couple_id = cid and p.slot = to_slot
           order by p.created_at desc limit 8) s;
  if jsonb_array_length(subs) = 0 then return 'no-subs'; end if;

  tab := case kind when 'rules' then 'rules' when 'cards' then 'cards' when 'tickets' then 'inbox' when 'requests' then 'inbox' else 'home' end;
  perform net.http_post(
    url := cfg.url,
    body := jsonb_build_object('secret', cfg.secret, 'messages', jsonb_build_array(jsonb_build_object(
      'subs', subs, 'title', title, 'body', body, 'url', cfg.site || '#' || tab))));
  return 'sent';
end $$;

create or replace function public._send_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public._push_to(new.couple_id, new.to_slot, new.title, new.body, new.kind);
  return new;
exception when others then
  return new;  -- 推播失敗不影響主要操作
end $$;

drop trigger if exists send_push on public.notifications;
create trigger send_push after insert on public.notifications
  for each row execute function public._send_push();

-- ---------- 網頁用的函式 ----------
create or replace function public.save_push(sub jsonb, device_id text, device text default '') returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; ep text; k1 text; k2 text; did text;
begin
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  ep := left(coalesce(sub->>'endpoint', ''), 1000);
  k1 := left(coalesce(sub#>>'{keys,p256dh}', ''), 200);
  k2 := left(coalesce(sub#>>'{keys,auth}', ''), 100);
  did := left(coalesce(device_id, ''), 64);
  if ep !~ '^https://' or k1 = '' or k2 = '' or did = '' then
    return jsonb_build_object('ok', false, 'error', '通知訂閱資料不正確');
  end if;
  delete from public.push_subs p where p.endpoint = ep or (p.user_id = auth.uid() and p.device_id = did);
  insert into public.push_subs (couple_id, slot, user_id, device_id, device, endpoint, p256dh, auth)
  values (me.couple_id, me.slot, auth.uid(), did, left(coalesce(device, ''), 40), ep, k1, k2);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.remove_push(endpoint text) returns jsonb
language sql volatile security definer set search_path = '' as $$
  delete from public.push_subs p where p.endpoint = remove_push.endpoint and p.user_id = auth.uid();
  select jsonb_build_object('ok', true);
$$;

create or replace function public.test_push() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; res text;
begin
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  res := public._push_to(me.couple_id, me.slot, '🔔 測試通知', '收到這條，代表這部手機的通知已經開好了。', 'home');
  if res = 'no-config' then return jsonb_build_object('ok', false, 'error', '後台還沒填推播設定（push_config）'); end if;
  if res = 'no-subs' then return jsonb_build_object('ok', false, 'error', '找不到這部手機的通知訂閱，請重新開啟通知'); end if;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public._push_to(uuid, text, text, text, text), public._send_push() from public, anon, authenticated;
revoke execute on function public.save_push(jsonb, text, text), public.remove_push(text), public.test_push() from public, anon;
grant execute on function public.save_push(jsonb, text, text), public.remove_push(text), public.test_push() to authenticated;
