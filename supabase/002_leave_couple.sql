-- 第 2 版更新：離開情侶空間、空位加入。在 SQL Editor 執行一次即可。
create or replace function public.join_couple(code text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare c public.couples; free_slot text;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then raise exception '你已經在一個情侶空間裡了'; end if;
  select * into c from public.couples where invite_code = upper(btrim(coalesce(code, ''))) for update;
  if not found then raise exception '邀請碼不正確'; end if;
  select s into free_slot from (values ('a'), ('b')) v(s)
   where not exists (select 1 from public.members m where m.couple_id = c.id and m.slot = v.s) order by s limit 1;
  if free_slot is null then raise exception '這個情侶空間已經滿了'; end if;
  insert into public.members (couple_id, user_id, slot) values (c.id, auth.uid(), free_slot);
  update public.couples set invite_code = null where id = c.id;
  return public.get_state();
end $$;

-- 離開情侶空間：另一半還在的話，資料留給對方並產生新的邀請碼；
-- 兩個人都離開了，整個空間（包括所有紀錄）一起刪除。
create or replace function public.leave_couple() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me public.members;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select * into me from public.members where user_id = auth.uid();
  if not found then raise exception '你目前不在任何情侶空間'; end if;
  perform pg_advisory_xact_lock(hashtext(me.couple_id::text));
  delete from public.members where user_id = auth.uid();
  if exists (select 1 from public.members where couple_id = me.couple_id) then
    update public.couples set invite_code = public._new_code() where id = me.couple_id;
  else
    delete from public.couples where id = me.couple_id;
  end if;
  return public.get_state();
end $$;

revoke execute on function public.leave_couple() from public, anon;
grant execute on function public.leave_couple() to authenticated;
