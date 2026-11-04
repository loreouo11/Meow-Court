-- 第 11 版更新：七七來決定（轉盤／抽籤）。在 SQL Editor 執行一次即可，重複執行也沒關係。
--
-- 籤筒（wheels）兩個人共用：網頁內建三個預設籤筒（今晚吃什麼、約會去哪裡、誰來做），
-- 修改預設籤筒時才會存一份（preset 欄記住是哪一個）；自己開的籤筒 preset 是 null。
-- 抽中之後按「就這樣決定」才會記錄（spins）並通知對方；上訴（再抽）的次數一起記下。
-- 選項裡的 @a / @b 代表兩個人的名字，網頁顯示時才換成名字，改名後也會跟著變。

-- ---------- 表格 ----------
create table if not exists public.wheels (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  by_slot     text not null check (by_slot in ('a','b')),
  preset      text check (preset is null or preset in ('food','date','who')),
  title       text not null check (char_length(title) between 1 and 20),
  options     jsonb not null check (jsonb_typeof(options) = 'array'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (couple_id, preset)
);
create index if not exists wheels_couple on public.wheels(couple_id, created_at);
alter table public.wheels enable row level security;
revoke all on public.wheels from anon, authenticated;

create table if not exists public.spins (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  by_slot     text not null check (by_slot in ('a','b')),
  title       text not null check (char_length(title) between 1 and 20),
  result      text not null check (char_length(result) between 1 and 40),
  appeals     int not null default 0 check (appeals between 0 and 999),
  created_at  timestamptz not null default now()
);
create index if not exists spins_couple on public.spins(couple_id, created_at desc);
alter table public.spins enable row level security;
revoke all on public.spins from anon, authenticated;

-- ---------- 小工具 ----------
create or replace function public._spin_data(cid uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'wheels', coalesce((select jsonb_agg(jsonb_build_object(
        'id', w.id, 'by', w.by_slot, 'preset', coalesce(w.preset, ''), 'title', w.title, 'options', w.options,
        'ts', public._ts(w.created_at)) order by w.created_at)
      from public.wheels w where w.couple_id = cid), '[]'::jsonb),
    'spins', coalesce((select jsonb_agg(x.j order by x.created_at desc) from (
        select s.created_at, jsonb_build_object('id', s.id, 'by', s.by_slot, 'title', s.title, 'result', s.result,
               'appeals', s.appeals, 'ts', public._ts(s.created_at)) j
          from public.spins s where s.couple_id = cid order by s.created_at desc limit 60) x), '[]'::jsonb))
$$;

-- 整理選項：去頭尾空白、去重複、每個最多 20 字；回傳 null 代表格式不對
create or replace function public._spin_options(v jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare v_out jsonb := '[]'::jsonb; t text; seen text[] := '{}';
begin
  if v is null or jsonb_typeof(v) <> 'array' then return null; end if;
  for t in select btrim(e) from jsonb_array_elements_text(v) e loop
    t := left(t, 20);
    if t = '' or t = any(seen) then continue; end if;
    seen := seen || t;
    v_out := v_out || to_jsonb(t);
  end loop;
  return v_out;
end $$;

-- ---------- 讀取 ----------
create or replace function public.get_spin() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare me public.members;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('wheels', '[]'::jsonb, 'spins', '[]'::jsonb); end if;
  return public._spin_data(me.couple_id);
end $$;

-- ---------- 新增／修改籤筒 ----------
-- id 有填：修改那一個；preset 有填：修改預設籤筒（第一次會新增一份）；兩個都沒有：開新籤筒
create or replace function public.save_wheel(title text, options jsonb, id uuid default null, preset text default '') returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
#variable_conflict use_column
declare me public.members; v_title text; v_opts jsonb; v_preset text; n int;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  v_title := left(btrim(coalesce(save_wheel.title, '')), 20);
  if v_title = '' then return jsonb_build_object('ok', false, 'error', '請幫籤筒取個名字'); end if;
  v_opts := public._spin_options(save_wheel.options);
  if v_opts is null then return jsonb_build_object('ok', false, 'error', '選項格式不正確'); end if;
  n := jsonb_array_length(v_opts);
  if n < 2 then return jsonb_build_object('ok', false, 'error', '最少要有兩個選項'); end if;
  if n > 30 then return jsonb_build_object('ok', false, 'error', '最多 30 個選項'); end if;
  v_preset := nullif(btrim(coalesce(save_wheel.preset, '')), '');
  if v_preset is not null and v_preset not in ('food', 'date', 'who') then v_preset := null; end if;

  if save_wheel.id is not null then
    update public.wheels w set title = v_title, options = v_opts, updated_at = now()
     where w.id = save_wheel.id and w.couple_id = me.couple_id;
    if not found then return jsonb_build_object('ok', false, 'error', '這個籤筒已經不在了'); end if;
  elsif v_preset is not null then
    insert into public.wheels (couple_id, by_slot, preset, title, options)
    values (me.couple_id, me.slot, v_preset, v_title, v_opts)
    on conflict (couple_id, preset) do update set title = excluded.title, options = excluded.options, updated_at = now();
  else
    if (select count(*) from public.wheels w where w.couple_id = me.couple_id and w.preset is null) >= 20 then
      return jsonb_build_object('ok', false, 'error', '最多 20 個自己開的籤筒');
    end if;
    insert into public.wheels (couple_id, by_slot, preset, title, options)
    values (me.couple_id, me.slot, null, v_title, v_opts);
  end if;
  return jsonb_build_object('ok', true, 'data', public._spin_data(me.couple_id));
end $$;

-- 刪除：自己開的籤筒會刪掉；預設籤筒會還原成原本的選項
create or replace function public.delete_wheel(id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  delete from public.wheels w where w.id = delete_wheel.id and w.couple_id = me.couple_id;
  return jsonb_build_object('ok', true, 'data', public._spin_data(me.couple_id));
end $$;

-- ---------- 記下判決，通知對方 ----------
create or replace function public.add_spin(title text, result text, appeals int default 0) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
#variable_conflict use_column
declare me public.members; c public.couples; op text; v_title text; v_result text; v_ap int;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  v_title := left(btrim(coalesce(add_spin.title, '')), 20);
  v_result := left(btrim(coalesce(add_spin.result, '')), 40);
  if v_title = '' or v_result = '' then return jsonb_build_object('ok', false, 'error', '判決內容不完整'); end if;
  v_ap := least(greatest(coalesce(add_spin.appeals, 0), 0), 999);
  -- 同一個人一分鐘內最多記 6 次，免得連按
  if (select count(*) from public.spins s where s.couple_id = me.couple_id and s.by_slot = me.slot
        and s.created_at > now() - interval '1 minute') >= 6 then
    return jsonb_build_object('ok', false, 'error', '七七判得太快了，休息一下再抽');
  end if;
  insert into public.spins (couple_id, by_slot, title, result, appeals)
  values (me.couple_id, me.slot, v_title, v_result, v_ap);
  select * into c from public.couples where id = me.couple_id;
  op := case when me.slot = 'a' then 'b' else 'a' end;
  if exists (select 1 from public.members where couple_id = c.id and slot = op) then
    perform public._ping(c.id, op, '🎲 七七判決：' || v_result,
      public._name(c, me.slot) || ' 抽了「' || v_title || '」' || case when v_ap > 0 then '（上訴了 ' || v_ap || ' 次）' else '' end,
      x'FFD15C'::int, 'spin');
  end if;
  return jsonb_build_object('ok', true, 'data', public._spin_data(me.couple_id));
end $$;

-- 推播的連結：判決的通知打開「七七來決定」
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
                   when 'review' then 'review' when 'events' then 'cal' when 'spin' then 'spin' else 'home' end;
  perform net.http_post(
    url := cfg.url,
    body := jsonb_build_object('secret', cfg.secret, 'messages', jsonb_build_array(jsonb_build_object(
      'subs', subs, 'title', title, 'body', body, 'url', cfg.site || '#' || tab))));
  return 'sent';
end $$;

-- ---------- 權限 ----------
revoke execute on function public._spin_data(uuid), public._spin_options(jsonb) from public, anon, authenticated;
revoke execute on function public.get_spin(), public.save_wheel(text, jsonb, uuid, text),
                           public.delete_wheel(uuid), public.add_spin(text, text, int) from public, anon;
grant execute on function public.get_spin(), public.save_wheel(text, jsonb, uuid, text),
                          public.delete_wheel(uuid), public.add_spin(text, text, int) to authenticated;
