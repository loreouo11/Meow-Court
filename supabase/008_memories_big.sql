-- 第 8 版更新：回憶可以不放相片（只寫一句），也可以標記「這是大事」。
-- 在 SQL Editor 執行一次即可，重複執行也沒關係。需要先執行過 007_memories.sql。

alter table public.memories add column if not exists is_big boolean not null default false;
alter table public.memories alter column path drop not null;

create or replace function public._memories(cid uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'by', m.by_slot, 'path', coalesce(m.path, ''), 'caption', m.caption, 'big', m.is_big,
      'date', to_char(m.taken_on, 'YYYY-MM-DD'), 'ts', public._ts(m.created_at))
    order by m.taken_on desc, m.created_at desc), '[]'::jsonb)
  from public.memories m where m.couple_id = cid
$$;

-- 舊版函式（少了 big）先刪掉，避免網頁叫錯版本
drop function if exists public.add_memory(text, text, text);
drop function if exists public.edit_memory(uuid, text, text);

-- 新增回憶：有相片的話先上載到 memories/<情侶空間 id>/<uuid>.jpg；沒有相片的話 path 留空，但一定要寫一句
create or replace function public.add_memory(path text default '', caption text default '', taken text default '', big boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; c public.couples; v_path text; v_cap text; v_date date; op text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  v_path := nullif(btrim(coalesce(path, '')), '');
  v_cap := left(btrim(coalesce(caption, '')), 120);
  if v_path is null and v_cap = '' then
    return jsonb_build_object('ok', false, 'error', '請選一張相片，或寫一句話');
  end if;
  if v_path is not null then
    if v_path !~ ('^' || me.couple_id::text || '/[0-9a-f-]{36}\.(jpg|jpeg|webp|png)$') then
      return jsonb_build_object('ok', false, 'error', '相片路徑不正確');
    end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'memories' and o.name = v_path) then
      return jsonb_build_object('ok', false, 'error', '相片還沒上載成功，請再試一次');
    end if;
  end if;
  v_date := coalesce(public._memory_date(taken), (now() at time zone 'Asia/Hong_Kong')::date);
  insert into public.memories (couple_id, by_slot, path, caption, taken_on, is_big)
  values (me.couple_id, me.slot, v_path, v_cap, v_date, coalesce(big, false))
  on conflict on constraint memories_path_key do nothing;
  select * into c from public.couples where id = me.couple_id;
  op := case when me.slot = 'a' then 'b' else 'a' end;
  if exists (select 1 from public.members where couple_id = c.id and slot = op) then
    perform public._ping(c.id, op,
      case when coalesce(big, false) then '⭐ ' || public._name(c, me.slot) || ' 記下了一件大事'
           else '📷 ' || public._name(c, me.slot) || ' 記下了一個回憶' end,
      case when v_cap <> '' then v_cap else '放了一張相片。' end, x'FFD15C'::int, 'memories');
  end if;
  return jsonb_build_object('ok', true, 'memories', public._memories(me.couple_id));
end $$;

-- 改文字、日期、大事：只有記下的人可以改
create or replace function public.edit_memory(id uuid, caption text default '', taken text default '', big boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; v_date date; v_cap text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  v_date := public._memory_date(taken);
  v_cap := left(btrim(coalesce(edit_memory.caption, '')), 120);
  update public.memories m
     set caption = v_cap, taken_on = coalesce(v_date, m.taken_on), is_big = coalesce(edit_memory.big, false), updated_at = now()
   where m.id = edit_memory.id and m.couple_id = me.couple_id and m.by_slot = me.slot
     and (m.path is not null or v_cap <> '');
  if not found then return jsonb_build_object('ok', false, 'error', '只有記下的人可以修改；沒有相片的回憶要寫一句話'); end if;
  return jsonb_build_object('ok', true, 'memories', public._memories(me.couple_id));
end $$;

-- 刪除：沒有相片的回憶，path 會是空字串，網頁就不用刪檔
create or replace function public.delete_memory(id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; v_path text; v_found boolean := false;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  delete from public.memories m
   where m.id = delete_memory.id and m.couple_id = me.couple_id and m.by_slot = me.slot
   returning coalesce(m.path, ''), true into v_path, v_found;
  if v_found is not true then return jsonb_build_object('ok', false, 'error', '只有記下的人可以刪除'); end if;
  return jsonb_build_object('ok', true, 'path', v_path, 'memories', public._memories(me.couple_id));
end $$;

revoke execute on function public._memories(uuid) from public, anon, authenticated;
revoke execute on function public.add_memory(text, text, text, boolean), public.edit_memory(uuid, text, text, boolean),
                           public.delete_memory(uuid) from public, anon;
grant execute on function public.add_memory(text, text, text, boolean), public.edit_memory(uuid, text, text, boolean),
                          public.delete_memory(uuid) to authenticated;
