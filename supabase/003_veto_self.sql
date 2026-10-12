-- 第 3 版更新：否決自首（vetoSelf）。在 SQL Editor 執行一次即可。
alter table public.tickets drop constraint if exists tickets_status_check;
alter table public.tickets add constraint tickets_status_check
  check (status in ('pending','paid','waived','appeal','voided','vetoed'));

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

    when 'vetoSelf' then
      -- 對方可以單方面否決自首：不入帳，但紀錄保留
      select * into t from public.tickets where id = public._uuid(d->'id') and couple_id = c.id;
      if not found or t.status <> 'paid' or not t.is_self then raise exception '只有自首可以否決'; end if;
      if t.to_slot = who then raise exception '要由對方否決'; end if;
      update public.tickets set status = 'vetoed', void_by = '', updated_at = now() where id = t.id;
      perform public._ping(c.id, t.to_slot, '🙅 ' || public._name(c, who) || ' 否決了你的自首',
        t.title || ' · $' || public._amt(t.final) || '，這次不算，已從基金扣除。', x'8FD6B4'::int, 'tickets');

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
