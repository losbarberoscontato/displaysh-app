-- Receipts adjusted from Cash remain append-only: reverse the original movement
-- and insert its replacement in the same transaction.
alter table public.payment_transactions
  add column if not exists source_payment_transaction_id uuid;

alter table public.payment_transactions
  drop constraint if exists payment_transactions_source_transaction_fk;
alter table public.payment_transactions
  add constraint payment_transactions_source_transaction_fk
  foreign key (source_payment_transaction_id, organization_id)
  references public.payment_transactions(id, organization_id);

create or replace function public.edit_financial_cash_receipt(
  p_settlement_id uuid,
  p_amount_cents bigint,
  p_settled_on date,
  p_financial_account_id uuid,
  p_payment_method public.financial_payment_method,
  p_reference text,
  p_idempotency_key text
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_source public.financial_settlements%rowtype;
  v_entry public.financial_entries%rowtype;
  v_existing public.financial_settlements%rowtype;
  v_reversed bigint;
  v_result uuid;
begin
  if p_amount_cents <= 0 or p_settled_on is null
     or nullif(btrim(p_idempotency_key), '') is null then
    raise exception using errcode = '22023', message = 'positive amount, date and idempotency key are required';
  end if;
  select * into strict v_source from public.financial_settlements
   where id = p_settlement_id for update;
  select * into strict v_entry from public.financial_entries
   where id = v_source.entry_id and organization_id = v_source.organization_id for update;
  perform public.require_financial_owner(v_entry.organization_id, 'cash receipt edit');
  if v_entry.kind <> 'REVENUE' or v_entry.source not in ('MANUAL', 'PROJECT', 'SUBSCRIPTION')
     or v_source.kind <> 'SETTLEMENT' then
    raise exception using errcode = '22023', message = 'only received financial entries can be edited in Cash';
  end if;
  select coalesce(sum(amount_cents), 0)::bigint into v_reversed
    from public.financial_settlements
   where source_settlement_id = v_source.id and kind = 'REVERSAL';
  if v_reversed <> 0 then
    raise exception using errcode = '22023', message = 'cash receipt with an existing reversal cannot be edited';
  end if;
  select * into v_existing from public.financial_settlements
   where organization_id = v_entry.organization_id and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.entry_id <> v_entry.id or v_existing.kind <> 'SETTLEMENT' then
      raise exception using errcode = '22023', message = 'idempotency key belongs to another cash receipt';
    end if;
    return v_existing.id;
  end if;
  perform public.reverse_financial_settlement(
    v_source.id, v_source.amount_cents, 'Recebimento editado no Caixa', p_idempotency_key || ':reversal'
  );
  v_result := public.settle_financial_entry(
    v_entry.id, p_financial_account_id, p_amount_cents, p_settled_on,
    p_payment_method, p_reference, p_idempotency_key
  );
  return v_result;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'cash receipt not found';
end;
$$;

create or replace function public.reverse_financial_cash_receipt(
  p_settlement_id uuid,
  p_reason text,
  p_idempotency_key text
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_source public.financial_settlements%rowtype;
  v_entry public.financial_entries%rowtype;
  v_reversed bigint;
begin
  if nullif(btrim(p_reason), '') is null or nullif(btrim(p_idempotency_key), '') is null then
    raise exception using errcode = '22023', message = 'reason and idempotency key are required';
  end if;
  select * into strict v_source from public.financial_settlements
   where id = p_settlement_id for update;
  select * into strict v_entry from public.financial_entries
   where id = v_source.entry_id and organization_id = v_source.organization_id for update;
  perform public.require_financial_owner(v_entry.organization_id, 'cash receipt reversal');
  if v_entry.kind <> 'REVENUE' or v_entry.source not in ('MANUAL', 'PROJECT', 'SUBSCRIPTION')
     or v_source.kind <> 'SETTLEMENT' then
    raise exception using errcode = '22023', message = 'only received financial entries can be reversed in Cash';
  end if;
  select coalesce(sum(amount_cents), 0)::bigint into v_reversed
    from public.financial_settlements
   where source_settlement_id = v_source.id and kind = 'REVERSAL';
  if v_reversed >= v_source.amount_cents then
    raise exception using errcode = '22023', message = 'cash receipt is already reversed';
  end if;
  return public.reverse_financial_settlement(
    v_source.id, v_source.amount_cents - v_reversed, p_reason, p_idempotency_key
  );
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'cash receipt not found';
end;
$$;

create or replace function public.apply_manual_appointment_cash_receipt_change(
  p_payment_transaction_id uuid,
  p_new_amount_cents bigint,
  p_reference text,
  p_idempotency_key text
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_source public.payment_transactions%rowtype;
  v_appointment public.appointments%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_net_paid bigint;
  v_refunded bigint;
  v_total bigint;
  v_new_order_id uuid;
  v_refund_order_id uuid;
  v_result uuid;
  v_cash_available bigint;
begin
  if nullif(btrim(p_idempotency_key), '') is null then
    raise exception using errcode = '22023', message = 'idempotency key is required';
  end if;
  select * into strict v_source from public.payment_transactions
   where id = p_payment_transaction_id for update;
  select * into strict v_appointment from public.appointments
   where id = v_source.appointment_id and organization_id = v_source.organization_id for update;
  perform public.require_financial_owner(v_appointment.organization_id, 'appointment cash receipt change');
  if not public.organization_allows_existing_operations(v_appointment.organization_id) then
    raise exception using errcode = '42501', message = 'organization access does not allow refunds';
  end if;
  if v_source.provider <> 'MANUAL' or v_source.kind <> 'CAPTURE' then
    raise exception using errcode = '22023', message = 'only manual appointment receipts can be edited in Cash';
  end if;

  if p_new_amount_cents is null then
    select * into v_existing from public.payment_transactions
     where organization_id = v_appointment.organization_id and idempotency_key = p_idempotency_key;
    if found then
      if v_existing.source_payment_transaction_id <> v_source.id or v_existing.kind <> 'REFUND' then
        raise exception using errcode = '22023', message = 'idempotency key belongs to another receipt reversal';
      end if;
      return v_existing.id;
    end if;
  else
    if p_new_amount_cents <= 0 then
      raise exception using errcode = '22023', message = 'replacement receipt amount must be positive';
    end if;
    select * into v_existing from public.payment_transactions
     where organization_id = v_appointment.organization_id
       and idempotency_key = p_idempotency_key || ':replacement-capture';
    if found then return v_existing.id; end if;
  end if;

  select coalesce(sum(amount_cents), 0)::bigint into v_refunded
    from public.payment_transactions
   where organization_id = v_appointment.organization_id
     and source_payment_transaction_id = v_source.id
     and kind in ('REFUND', 'REVERSAL');
  v_cash_available := greatest(v_source.amount_cents - v_refunded, 0);
  if v_cash_available <= 0 then
    raise exception using errcode = '22023', message = 'appointment cash receipt is already reversed';
  end if;

  select coalesce(sum(case when transaction.kind in ('CAPTURE', 'ADJUSTMENT') then transaction.amount_cents
                           when transaction.kind in ('REFUND', 'REVERSAL') then -transaction.amount_cents end), 0)::bigint
    into v_net_paid
    from public.payment_transactions transaction
   where transaction.organization_id = v_appointment.organization_id
     and transaction.appointment_id = v_appointment.id;
  select coalesce((select adjustment.final_total_cents
      from public.appointment_amount_adjustments adjustment
     where adjustment.organization_id = v_appointment.organization_id
       and adjustment.appointment_id = v_appointment.id
     order by adjustment.created_at desc, adjustment.id desc limit 1),
    v_appointment.total_cents_snapshot)::bigint into v_total;

  insert into public.payment_orders (
    organization_id, appointment_id, provider, kind, status, amount_cents,
    currency, idempotency_key, external_order_id, metadata
  ) values (
    v_appointment.organization_id, v_appointment.id, 'MANUAL', 'REFUND', 'REFUNDED',
    v_cash_available, v_appointment.currency, p_idempotency_key || ':refund-order',
    nullif(btrim(p_reference), ''), jsonb_build_object('reason', 'Cash receipt edit/reversal',
      'source_payment_transaction_id', v_source.id)
  ) returning id into v_refund_order_id;
  insert into public.payment_transactions (
    organization_id, payment_order_id, appointment_id, provider, kind,
    amount_cents, currency, idempotency_key, metadata, source_payment_transaction_id
  ) values (
    v_appointment.organization_id, v_refund_order_id, v_appointment.id, 'MANUAL', 'REFUND',
    v_cash_available, v_appointment.currency,
    case when p_new_amount_cents is null then p_idempotency_key else p_idempotency_key || ':refund' end,
    jsonb_build_object('reference', nullif(btrim(p_reference), ''), 'reason', 'Cash receipt edit/reversal'),
    v_source.id
  ) returning id into v_result;
  if p_new_amount_cents is null then return v_result; end if;

  if p_new_amount_cents > greatest(v_total - v_appointment.amount_waived_cents - (v_net_paid - v_cash_available), 0) then
    raise exception using errcode = '22023', message = 'replacement receipt exceeds appointment balance';
  end if;
  insert into public.payment_orders (
    organization_id, appointment_id, provider, kind, status, amount_cents,
    currency, idempotency_key, external_order_id, metadata
  ) values (
    v_appointment.organization_id, v_appointment.id, 'MANUAL', 'BALANCE', 'PAID',
    p_new_amount_cents, v_appointment.currency, p_idempotency_key || ':replacement-order',
    nullif(btrim(p_reference), ''), jsonb_build_object('cash_receipt_replacement_for', v_source.id)
  ) returning id into v_new_order_id;
  insert into public.payment_transactions (
    organization_id, payment_order_id, appointment_id, provider, kind,
    amount_cents, currency, idempotency_key, metadata
  ) values (
    v_appointment.organization_id, v_new_order_id, v_appointment.id, 'MANUAL', 'CAPTURE',
    p_new_amount_cents, v_appointment.currency, p_idempotency_key || ':replacement-capture',
    jsonb_build_object('reference', nullif(btrim(p_reference), ''), 'replaces_receipt_id', v_source.id)
  ) returning id into v_result;
  return v_result;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'appointment cash receipt not found';
end;
$$;

create or replace function public.edit_manual_appointment_cash_receipt(
  p_payment_transaction_id uuid, p_amount_cents bigint, p_reference text, p_idempotency_key text
) returns uuid language sql security definer set search_path = '' as $$
  select public.apply_manual_appointment_cash_receipt_change(
    p_payment_transaction_id, p_amount_cents, p_reference, p_idempotency_key
  );
$$;

create or replace function public.reverse_manual_appointment_cash_receipt(
  p_payment_transaction_id uuid, p_reference text, p_idempotency_key text
) returns uuid language sql security definer set search_path = '' as $$
  select public.apply_manual_appointment_cash_receipt_change(
    p_payment_transaction_id, null, p_reference, p_idempotency_key
  );
$$;

create or replace function public.sync_legacy_subscription_cycle_from_settlement()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_entry public.financial_entries%rowtype;
  v_net_settled bigint;
  v_timezone text;
  v_today date;
  v_paid_at timestamptz;
begin
  select * into v_entry from public.financial_entries entry
   where entry.id = new.entry_id and entry.organization_id = new.organization_id
     and entry.source = 'SUBSCRIPTION' and entry.subscription_cycle_id is not null;
  if not found then return new; end if;
  select coalesce(sum(case when settlement.kind = 'SETTLEMENT' then settlement.amount_cents
                           else -settlement.amount_cents end), 0)::bigint
    into v_net_settled from public.financial_settlements settlement
   where settlement.organization_id = v_entry.organization_id and settlement.entry_id = v_entry.id;
  select organization.timezone into strict v_timezone from public.organizations organization
   where organization.id = v_entry.organization_id;
  v_today := (now() at time zone v_timezone)::date;
  select (max(settlement.settled_on)::timestamp at time zone v_timezone)
    into v_paid_at from public.financial_settlements settlement
   where settlement.organization_id = v_entry.organization_id and settlement.entry_id = v_entry.id
     and settlement.kind = 'SETTLEMENT';
  if v_net_settled >= v_entry.total_cents and v_entry.canceled_at is null then
    update public.customer_subscription_cycles cycle
       set status = 'PAID', paid_at = coalesce(cycle.paid_at, v_paid_at)
     where cycle.organization_id = v_entry.organization_id
       and cycle.financial_entry_id = v_entry.id and cycle.status <> 'CANCELED';
  else
    update public.customer_subscription_cycles cycle
       set status = case when cycle.due_on < v_today then 'OVERDUE'::public.subscription_cycle_status
                         else 'OPEN'::public.subscription_cycle_status end,
           paid_at = null
     where cycle.organization_id = v_entry.organization_id
       and cycle.financial_entry_id = v_entry.id and cycle.status = 'PAID';
  end if;
  return new;
end;
$$;
revoke all on function public.sync_legacy_subscription_cycle_from_settlement() from public, anon, authenticated, service_role;
drop trigger if exists financial_settlements_legacy_subscription_cycle_sync on public.financial_settlements;
create trigger financial_settlements_legacy_subscription_cycle_sync
  after insert on public.financial_settlements
  for each row execute function public.sync_legacy_subscription_cycle_from_settlement();

create or replace view public.appointment_cash_activity
with (security_invoker = true) as
select t.id as payment_transaction_id, t.organization_id, t.appointment_id,
  a.customer_id, a.payment_mode, t.provider, t.kind, t.amount_cents, t.currency,
  t.occurred_at, coalesce(rc.financial_account_id, m.financial_account_id) as financial_account_id,
  (coalesce(rc.financial_account_id, m.financial_account_id) is null) as needs_reconciliation,
  case when t.kind in ('CAPTURE', 'ADJUSTMENT') then t.amount_cents else -t.amount_cents end::bigint as signed_cents,
  case when reconciliation.id is not null then reconciliation.reconciled_at else t.occurred_at end as conciliation_at,
  reconciliation.id as reconciliation_id,
  case when reconciliation.id is not null then 'Conciliado | Barbeiro ' || barber.display_name || ' | ID ' || reconciliation.id::text else null end as reconciliation_label,
  t.payment_order_id,
  case when t.kind = 'CAPTURE' and t.provider = 'MANUAL'
    then greatest(t.amount_cents - coalesce((select sum(refund.amount_cents)::bigint
      from public.payment_transactions refund
     where refund.organization_id = t.organization_id
       and refund.source_payment_transaction_id = t.id
       and refund.kind in ('REFUND', 'REVERSAL')), 0), 0)
    when t.kind = 'CAPTURE' and t.provider = 'MERCADO_PAGO'
    then greatest(t.amount_cents - coalesce((select sum(refund.amount_cents)::bigint
      from public.payment_transactions refund
     where refund.organization_id = t.organization_id and refund.provider = t.provider
       and refund.kind in ('REFUND', 'REVERSAL')
       and refund.metadata ->> 'payment_id' = t.external_transaction_id), 0), 0)
    else 0 end::bigint as cash_remaining_cents,
  case
    when t.kind <> 'CAPTURE' then false
    when t.provider = 'MANUAL' then not exists (
      select 1 from public.payment_transactions refund
       where refund.organization_id = t.organization_id and refund.appointment_id = t.appointment_id
         and refund.provider = 'MANUAL' and refund.kind in ('REFUND', 'REVERSAL')
         and refund.source_payment_transaction_id is null)
    when t.provider = 'MERCADO_PAGO' then not exists (
      select 1 from public.payment_orders refund_order
       where refund_order.organization_id = t.organization_id and refund_order.kind = 'REFUND'
         and refund_order.status <> 'CANCELED'
         and refund_order.metadata ->> 'capture_transaction_id' = t.id::text)
    else false
  end as can_manage_cash_receipt
from public.payment_transactions t
join public.appointments a on a.id = t.appointment_id and a.organization_id = t.organization_id
left join public.appointment_receipt_classifications rc
  on rc.organization_id = t.organization_id and rc.payment_transaction_id = t.id
left join public.payment_account_mappings m
  on m.organization_id = t.organization_id and m.provider = t.provider and m.payment_mode = a.payment_mode
left join public.barber_cash_receipts barber_receipt
  on barber_receipt.organization_id = t.organization_id and barber_receipt.payment_transaction_id = t.id
left join public.barber_cash_reconciliations reconciliation
  on reconciliation.organization_id = barber_receipt.organization_id and reconciliation.cash_session_id = barber_receipt.cash_session_id
left join public.barbers barber
  on barber.organization_id = barber_receipt.organization_id and barber.id = barber_receipt.received_by_barber_id;

revoke all on function public.apply_manual_appointment_cash_receipt_change(uuid, bigint, text, text) from public, anon, authenticated, service_role;
revoke all on function public.edit_financial_cash_receipt(uuid, bigint, date, uuid, public.financial_payment_method, text, text) from public, anon, service_role;
revoke all on function public.reverse_financial_cash_receipt(uuid, text, text) from public, anon, service_role;
revoke all on function public.edit_manual_appointment_cash_receipt(uuid, bigint, text, text) from public, anon, service_role;
revoke all on function public.reverse_manual_appointment_cash_receipt(uuid, text, text) from public, anon, service_role;
grant execute on function public.edit_financial_cash_receipt(uuid, bigint, date, uuid, public.financial_payment_method, text, text) to authenticated;
grant execute on function public.reverse_financial_cash_receipt(uuid, text, text) to authenticated;
grant execute on function public.edit_manual_appointment_cash_receipt(uuid, bigint, text, text) to authenticated;
grant execute on function public.reverse_manual_appointment_cash_receipt(uuid, text, text) to authenticated;
grant select on public.appointment_cash_activity to authenticated;
