-- 第 7 版更新：回憶（放相）。在 SQL Editor 執行一次即可，重複執行也沒關係。
--
-- 相片放在 Storage 的私人 bucket「memories」，路徑一定是「<情侶空間 id>/<隨機 id>.jpg」，
-- 所以每個人只讀得到、上載得到自己情侶空間資料夾裡的相片。
-- 相片的文字、日期記在 public.memories；網頁不能直接改這張表，只能透過下面的函式。
-- 網頁上載前會先把相片壓細（約 1600px、JPEG），每張上限 5MB。

-- ---------- 表格 ----------
create table if not exists public.memories (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  by_slot     text not null check (by_slot in ('a','b')),
  path        text not null unique,
  caption     text not null default '',
  taken_on    date not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists memories_couple on public.memories(couple_id, taken_on desc);
alter table public.memories enable row level security;
revoke all on public.memories from anon, authenticated;

-- ---------- Storage：私人 bucket ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('memories', 'memories', false, 5242880, array['image/jpeg', 'image/webp', 'image/png'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- 這個檔案還有沒有回憶在用（刪檔前檢查，避免刪走仍在顯示的相片）
create or replace function public.memory_path_free(p text) returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from public.memories m where m.path = p)
$$;

drop policy if exists "memories read own couple" on storage.objects;
create policy "memories read own couple" on storage.objects for select to authenticated
  using (bucket_id = 'memories' and (storage.foldername(name))[1] = (select public.my_couple_id())::text);
drop policy if exists "memories upload own couple" on storage.objects;
create policy "memories upload own couple" on storage.objects for insert to authenticated
  with check (bucket_id = 'memories' and (storage.foldername(name))[1] = (select public.my_couple_id())::text);
drop policy if exists "memories delete unused" on storage.objects;
create policy "memories delete unused" on storage.objects for delete to authenticated
  using (bucket_id = 'memories' and (storage.foldername(name))[1] = (select public.my_couple_id())::text
         and public.memory_path_free(name));

-- ---------- 函式 ----------
create or replace function public._memories(cid uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'by', m.by_slot, 'path', m.path, 'caption', m.caption,
      'date', to_char(m.taken_on, 'YYYY-MM-DD'), 'ts', public._ts(m.created_at))
    order by m.taken_on desc, m.created_at desc), '[]'::jsonb)
  from public.memories m where m.couple_id = cid
$$;

create or replace function public._memory_date(v text) returns date
language plpgsql immutable set search_path = '' as $$
begin
  if coalesce(v, '') ~ '^\d{4}-\d{2}-\d{2}$' then return v::date; end if;
  return null;
exception when others then return null;
end $$;

create or replace function public.get_memories() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare me public.members;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return '[]'::jsonb; end if;
  return public._memories(me.couple_id);
end $$;

-- 新增回憶：網頁先把相片上載到 memories/<情侶空間 id>/<uuid>.jpg，再呼叫這個函式
create or replace function public.add_memory(path text, caption text default '', taken text default '') returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; c public.couples; v_path text; v_cap text; v_date date; op text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  v_path := btrim(coalesce(path, ''));
  if v_path !~ ('^' || me.couple_id::text || '/[0-9a-f-]{36}\.(jpg|jpeg|webp|png)$') then
    return jsonb_build_object('ok', false, 'error', '相片路徑不正確');
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'memories' and o.name = v_path) then
    return jsonb_build_object('ok', false, 'error', '相片還沒上載成功，請再試一次');
  end if;
  v_cap := left(btrim(coalesce(caption, '')), 120);
  v_date := coalesce(public._memory_date(taken), (now() at time zone 'Asia/Hong_Kong')::date);
  insert into public.memories (couple_id, by_slot, path, caption, taken_on)
  values (me.couple_id, me.slot, v_path, v_cap, v_date)
  on conflict on constraint memories_path_key do nothing;
  select * into c from public.couples where id = me.couple_id;
  op := case when me.slot = 'a' then 'b' else 'a' end;
  if exists (select 1 from public.members where couple_id = c.id and slot = op) then
    perform public._ping(c.id, op, '📷 ' || public._name(c, me.slot) || ' 記下了一個回憶',
      case when v_cap <> '' then v_cap else '放了一張相片。' end, x'FFD15C'::int, 'memories');
  end if;
  return jsonb_build_object('ok', true, 'memories', public._memories(me.couple_id));
end $$;

-- 改文字或日期：只有放相的人可以改
create or replace function public.edit_memory(id uuid, caption text default '', taken text default '') returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; v_date date;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  v_date := public._memory_date(taken);
  update public.memories m
     set caption = left(btrim(coalesce(edit_memory.caption, '')), 120),
         taken_on = coalesce(v_date, m.taken_on), updated_at = now()
   where m.id = edit_memory.id and m.couple_id = me.couple_id and m.by_slot = me.slot;
  if not found then return jsonb_build_object('ok', false, 'error', '只有放相的人可以修改'); end if;
  return jsonb_build_object('ok', true, 'memories', public._memories(me.couple_id));
end $$;

-- 刪除回憶：只有放相的人可以刪。刪完網頁再用 Storage API 刪檔（路徑會一併回傳）
create or replace function public.delete_memory(id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members; v_path text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', '請先登入'); end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', '請先建立或加入情侶空間'); end if;
  delete from public.memories m
   where m.id = delete_memory.id and m.couple_id = me.couple_id and m.by_slot = me.slot
   returning m.path into v_path;
  if v_path is null then return jsonb_build_object('ok', false, 'error', '只有放相的人可以刪除'); end if;
  return jsonb_build_object('ok', true, 'path', v_path, 'memories', public._memories(me.couple_id));
end $$;

-- ---------- 權限 ----------
revoke execute on function public._memories(uuid), public._memory_date(text) from public, anon, authenticated;
revoke execute on function public.get_memories(), public.add_memory(text, text, text),
                           public.edit_memory(uuid, text, text), public.delete_memory(uuid),
                           public.memory_path_free(text) from public, anon;
grant execute on function public.get_memories(), public.add_memory(text, text, text),
                          public.edit_memory(uuid, text, text), public.delete_memory(uuid),
                          public.memory_path_free(text) to authenticated;
