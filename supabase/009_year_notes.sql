-- 第 9 版更新：年度卷宗的寄語。在 SQL Editor 執行一次即可，重複執行也沒關係。
--
-- 每年 12 月 1 日至翌年 1 月 31 日（香港時間）可以寫一句給對方的寄語，封存之前可以改。
-- 1 月 31 日之後封存，誰都看不到內容；到下一年 12 月 1 日年度卷宗開放時，才一起拆開。
-- 1 月 15 日和 1 月 28 日早上十點，會提醒還沒寫的人（只是提醒，不寫也沒關係）。

-- ---------- 表格 ----------
create table if not exists public.year_notes (
  couple_id   uuid not null references public.couples(id) on delete cascade,
  year        int  not null check (year between 2000 and 2999),
  by_slot     text not null check (by_slot in ('a','b')),
  body        text not null check (char_length(body) between 1 and 500),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (couple_id, year, by_slot)
);
alter table public.year_notes enable row level security;
revoke all on public.year_notes from anon, authenticated;

-- ---------- 時間 ----------
create or replace function public._hk_today() returns date
language sql stable set search_path = '' as $$
  select (now() at time zone 'Asia/Hong_Kong')::date
$$;
-- 寫得到：Y 年 12 月 1 日至 Y+1 年 1 月 31 日
create or replace function public._note_open(y int) returns boolean
language sql stable set search_path = '' as $$
  select public._hk_today() between make_date(y, 12, 1) and make_date(y + 1, 1, 31)
$$;
-- 拆開：Y+1 年 12 月 1 日起
create or replace function public._note_revealed(y int) returns boolean
language sql stable set search_path = '' as $$
  select public._hk_today() >= make_date(y + 1, 12, 1)
$$;

-- ---------- 讀取 ----------
create or replace function public._year_notes(cid uuid, slot text, y int) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'year', y,
    'open', public._note_open(y),
    'sealed', public._hk_today() > make_date(y + 1, 1, 31),
    'revealed', public._note_revealed(y),
    'count', (select count(*) from public.year_notes n where n.couple_id = cid and n.year = y),
    -- 自己寫的：封存之前看得到、改得到
    'mine', case when public._hk_today() <= make_date(y + 1, 1, 31) or public._note_revealed(y)
                 then coalesce((select n.body from public.year_notes n where n.couple_id = cid and n.year = y and n.by_slot = slot), '')
                 else '' end,
    -- 兩個人的：到拆開那天才有
    'notes', case when public._note_revealed(y) then
               coalesce((select jsonb_agg(jsonb_build_object('by', n.by_slot, 'body', n.body) order by n.by_slot)
                           from public.year_notes n where n.couple_id = cid and n.year = y), '[]'::jsonb)
             else '[]'::jsonb end)
$$;

create or replace function public.get_year_notes(y int) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare me public.members;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  return jsonb_build_object('ok', true, 'data', public._year_notes(me.couple_id, me.slot, y));
end $$;

-- ---------- 寫／改／清空 ----------
create or replace function public.save_year_note(y int, body text default '') returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; v text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  if not public._note_open(y) then
    return jsonb_build_object('ok', false, 'error', '寄語只可以在 12 月 1 日至 1 月 31 日之間寫');
  end if;
  v := left(btrim(coalesce(body, '')), 500);
  if v = '' then
    delete from public.year_notes n where n.couple_id = me.couple_id and n.year = y and n.by_slot = me.slot;
  else
    insert into public.year_notes (couple_id, year, by_slot, body) values (me.couple_id, y, me.slot, v)
    on conflict (couple_id, year, by_slot) do update set body = excluded.body, updated_at = now();
  end if;
  return jsonb_build_object('ok', true, 'data', public._year_notes(me.couple_id, me.slot, y));
end $$;

-- ---------- 提醒還沒寫的人 ----------
create or replace function public.remind_year_notes() returns int
language plpgsql volatile security definer set search_path = '' as $$
declare y int; r record; n int := 0;
begin
  y := extract(year from public._hk_today())::int - 1;   -- 1 月提醒的是上一年的卷宗
  if not public._note_open(y) then return 0; end if;
  for r in
    select c.id as cid, m.slot
      from public.couples c
      join public.members m on m.couple_id = c.id
     where exists (select 1 from public.members o where o.couple_id = c.id and o.slot <> m.slot)
       and not exists (select 1 from public.year_notes x where x.couple_id = c.id and x.year = y and x.by_slot = m.slot)
  loop
    perform public._ping(r.cid, r.slot, '✉️ ' || y || ' 年度卷宗的寄語',
      '寄語會在 1 月 31 日封存，想寫一句給對方的話，還來得及。', x'EE5F92'::int, 'review');
    n := n + 1;
  end loop;
  return n;
end $$;

-- 推播的連結：寄語提醒打開年度卷宗
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
                   when 'review' then 'review' else 'home' end;
  perform net.http_post(
    url := cfg.url,
    body := jsonb_build_object('secret', cfg.secret, 'messages', jsonb_build_array(jsonb_build_object(
      'subs', subs, 'title', title, 'body', body, 'url', cfg.site || '#' || tab))));
  return 'sent';
end $$;

-- ---------- 權限 ----------
revoke execute on function public._hk_today(), public._note_open(int), public._note_revealed(int),
                           public._year_notes(uuid, text, int), public.remind_year_notes() from public, anon, authenticated;
revoke execute on function public.get_year_notes(int), public.save_year_note(int, text) from public, anon;
grant execute on function public.get_year_notes(int), public.save_year_note(int, text) to authenticated;

-- ---------- 排程：每年 1 月 15 日和 1 月 28 日香港時間早上十點（UTC 02:00） ----------
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname = 'meow-year-notes';
select cron.schedule('meow-year-notes', '0 2 15,28 1 *', 'select public.remind_year_notes()');
