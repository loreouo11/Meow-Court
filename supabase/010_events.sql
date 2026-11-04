-- 第 10 版更新：日曆。在 SQL Editor 執行一次即可，重複執行也沒關係。
--
-- 兩種事：「我們的約會」（ours，兩個人都可以改）和「我的行程」（mine，讓對方知道，只有自己可以改）。
-- 可以跨幾天（旅行），也可以每年重複（生日、紀念日）。週年和每一百天由網頁自動計算，不用存。
-- 新增時通知對方；約會的前一天早上九點提醒兩個人。

-- ---------- 表格 ----------
create table if not exists public.events (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  by_slot     text not null check (by_slot in ('a','b')),
  kind        text not null check (kind in ('ours','mine')),
  title       text not null check (char_length(title) between 1 and 40),
  start_on    date not null,
  end_on      date check (end_on is null or end_on >= start_on),
  at_time     time,
  yearly      boolean not null default false,
  note        text not null default '' check (char_length(note) <= 200),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists events_couple on public.events(couple_id, start_on);
alter table public.events enable row level security;
revoke all on public.events from anon, authenticated;

-- ---------- 小工具 ----------
create or replace function public._events(cid uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'by', e.by_slot, 'kind', e.kind, 'title', e.title,
      'start', to_char(e.start_on, 'YYYY-MM-DD'), 'end', coalesce(to_char(e.end_on, 'YYYY-MM-DD'), ''),
      'at', coalesce(to_char(e.at_time, 'HH24:MI'), ''), 'yearly', e.yearly, 'note', e.note,
      'ts', public._ts(e.created_at))
    order by e.start_on, e.at_time nulls first, e.created_at), '[]'::jsonb)
  from public.events e where e.couple_id = cid
$$;

create or replace function public._event_time(v text) returns time
language plpgsql immutable set search_path = '' as $$
begin
  if coalesce(v, '') ~ '^\d{1,2}:\d{2}$' then return v::time; end if;
  return null;
exception when others then return null;
end $$;

-- 檢查輸入，回傳錯誤訊息；沒問題就回傳 null
create or replace function public._event_check(title text, kind text, s date, e date, raw_s text, raw_e text) returns text
language sql immutable set search_path = '' as $$
  select case
    when btrim(coalesce(title, '')) = '' then '請寫上要做什麼'
    when coalesce(kind, '') not in ('ours', 'mine') then '請選擇是約會還是行程'
    when s is null then '請選擇日期'
    when coalesce(raw_e, '') <> '' and e is null then '結束日期不正確'
    when e is not null and e < s then '結束日期不能早過開始日期'
    when e is not null and e > s + 60 then '最長只可以連續 60 天'
    else null end
$$;

-- ---------- 讀取 ----------
create or replace function public.get_events() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare me public.members;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return '[]'::jsonb; end if;
  return public._events(me.couple_id);
end $$;

-- ---------- 新增 ----------
create or replace function public.add_event(title text, kind text, start_on text, end_on text default '', at text default '',
                                            yearly boolean default false, note text default '') returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; c public.couples; s date; e date; err text; op text; v_title text; who text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  s := public._memory_date(start_on); e := public._memory_date(end_on);
  err := public._event_check(title, kind, s, e, start_on, end_on);
  if err is not null then return jsonb_build_object('ok', false, 'error', err); end if;
  if e = s then e := null; end if;
  v_title := left(btrim(title), 40);
  insert into public.events (couple_id, by_slot, kind, title, start_on, end_on, at_time, yearly, note)
  values (me.couple_id, me.slot, kind, v_title, s, e, public._event_time(at),
          coalesce(yearly, false) and e is null, left(btrim(coalesce(note, '')), 200));
  select * into c from public.couples where id = me.couple_id;
  op := case when me.slot = 'a' then 'b' else 'a' end;
  who := public._name(c, me.slot);
  if exists (select 1 from public.members where couple_id = c.id and slot = op) then
    perform public._ping(c.id, op,
      case when kind = 'ours' then '📅 ' || who || ' 加了一個約會' else '🗓️ ' || who || ' 加了一個行程' end,
      v_title || ' · ' || extract(month from s)::int || '/' || extract(day from s)::int
        || case when e is not null then '–' || extract(month from e)::int || '/' || extract(day from e)::int else '' end,
      x'9CC9F5'::int, 'events');
  end if;
  return jsonb_build_object('ok', true, 'events', public._events(me.couple_id));
end $$;

-- ---------- 修改：約會兩個人都可以改；行程只有自己可以改 ----------
create or replace function public.edit_event(id uuid, title text, kind text, start_on text, end_on text default '', at text default '',
                                             yearly boolean default false, note text default '') returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; ev public.events; s date; e date; err text; v_kind text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  select * into ev from public.events x where x.id = edit_event.id and x.couple_id = me.couple_id;
  if not found then return jsonb_build_object('ok', false, 'error', '這件事已經不在日曆上了'); end if;
  if ev.kind = 'mine' and ev.by_slot <> me.slot then return jsonb_build_object('ok', false, 'error', '只有本人可以修改自己的行程'); end if;
  -- 對方的約會不可以改成自己的行程
  v_kind := case when ev.by_slot = me.slot then kind else 'ours' end;
  s := public._memory_date(start_on); e := public._memory_date(end_on);
  err := public._event_check(title, v_kind, s, e, start_on, end_on);
  if err is not null then return jsonb_build_object('ok', false, 'error', err); end if;
  if e = s then e := null; end if;
  update public.events x
     set title = left(btrim(edit_event.title), 40), kind = v_kind, start_on = s, end_on = e,
         at_time = public._event_time(at), yearly = coalesce(edit_event.yearly, false) and e is null,
         note = left(btrim(coalesce(edit_event.note, '')), 200), updated_at = now()
   where x.id = ev.id;
  return jsonb_build_object('ok', true, 'events', public._events(me.couple_id));
end $$;

create or replace function public.delete_event(id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; ev public.events;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  select * into ev from public.events x where x.id = delete_event.id and x.couple_id = me.couple_id;
  if not found then return jsonb_build_object('ok', true, 'events', public._events(me.couple_id)); end if;
  if ev.kind = 'mine' and ev.by_slot <> me.slot then return jsonb_build_object('ok', false, 'error', '只有本人可以刪除自己的行程'); end if;
  delete from public.events x where x.id = ev.id;
  return jsonb_build_object('ok', true, 'events', public._events(me.couple_id));
end $$;

-- ---------- 約會前一天早上提醒兩個人 ----------
create or replace function public.remind_events() returns int
language plpgsql volatile security definer set search_path = '' as $$
declare t date; r record; n int := 0;
begin
  t := public._hk_today() + 1;
  for r in
    select e.couple_id, e.title, e.at_time, m.slot
      from public.events e
      join public.members m on m.couple_id = e.couple_id
     where e.kind = 'ours'
       and (e.start_on = t or (e.yearly and e.start_on < t and to_char(e.start_on, 'MM-DD') = to_char(t, 'MM-DD')))
       and exists (select 1 from public.members o where o.couple_id = e.couple_id and o.slot <> m.slot)
  loop
    perform public._ping(r.couple_id, r.slot, '📅 明天：' || r.title,
      case when r.at_time is not null then to_char(r.at_time, 'HH24:MI') || '，' else '' end || '在日曆裡可以看到細節。',
      x'9CC9F5'::int, 'events');
    n := n + 1;
  end loop;
  return n;
end $$;

-- 推播的連結：日曆的通知打開日曆
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

  tab := case kind when 'rules' then 'rules' when 'cards' then 'cards' when 'tickets' then 'inbox' when 'requests' then 'inbox'
                   when 'review' then 'review' when 'events' then 'cal' else 'home' end;
  perform net.http_post(
    url := cfg.url,
    body := jsonb_build_object('secret', cfg.secret, 'messages', jsonb_build_array(jsonb_build_object(
      'subs', subs, 'title', title, 'body', body, 'url', cfg.site || '#' || tab))));
  return 'sent';
end $$;

-- ---------- 權限 ----------
revoke execute on function public._events(uuid), public._event_time(text), public._event_check(text, text, date, date, text, text),
                           public.remind_events() from public, anon, authenticated;
revoke execute on function public.get_events(),
                           public.add_event(text, text, text, text, text, boolean, text),
                           public.edit_event(uuid, text, text, text, text, text, boolean, text),
                           public.delete_event(uuid) from public, anon;
grant execute on function public.get_events(),
                          public.add_event(text, text, text, text, text, boolean, text),
                          public.edit_event(uuid, text, text, text, text, text, boolean, text),
                          public.delete_event(uuid) to authenticated;

-- ---------- 排程：每天香港時間早上九點（UTC 01:00） ----------
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname = 'meow-events-tomorrow';
select cron.schedule('meow-events-tomorrow', '0 1 * * *', 'select public.remind_events()');
