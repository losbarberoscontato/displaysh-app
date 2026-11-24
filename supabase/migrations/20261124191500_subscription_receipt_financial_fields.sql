-- Extend subscription installment receipts with the same finance metadata used
-- by manager appointment receipts while preserving the existing atomic payment RPCs.
create or replace function public.record_subscription_payment_with_receipt_metadata(
  p_organization_id uuid,
  p_subscription_id uuid,
  p_cycle_id uuid,
  p_amount_cents bigint,
  p_method public.subscription_payment_method,
  p_idempotency_key text,
  p_chart_account_id uuid,
  p_financial_account_id uuid,
  p_external_reference text,
  p_paid_on date,
  p_cost_center_id uuid,
  p_document_number text,
  p_tag_ids uuid[],
  p_description text
)
returns public.subscription_payments
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_payment public.subscription_payments%rowtype;
  v_entry_id uuid;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription payment denied';
  end if;
  if p_method is null then
    raise exception using errcode = '22023', message = 'subscription payment method is required';
  end if;
  if p_chart_account_id is null or not exists (
    select 1 from public.chart_of_accounts account
     where account.id = p_chart_account_id and account.organization_id = p_organization_id
       and account.kind = 'REVENUE' and account.active
  ) then
    raise exception using errcode = '22023', message = 'active revenue account is required';
  end if;
  if p_financial_account_id is null or not exists (
    select 1 from public.financial_accounts account
     where account.id = p_financial_account_id and account.organization_id = p_organization_id
       and account.active
  ) then
    raise exception using errcode = '22023', message = 'active financial account is required';
  end if;
  if p_cost_center_id is not null and not exists (
    select 1 from public.cost_centers center
     where center.id = p_cost_center_id and center.organization_id = p_organization_id
       and center.active
  ) then
    raise exception using errcode = '22023', message = 'active cost center is required';
  end if;
  if char_length(btrim(coalesce(p_description, ''))) not between 2 and 500 then
    raise exception using errcode = '22023', message = 'receipt description is invalid';
  end if;
  if char_length(btrim(coalesce(p_document_number, ''))) not between 2 and 100 then
    raise exception using errcode = '22023', message = 'receipt document number is invalid';
  end if;
  if exists (
    select 1
      from unnest(coalesce(p_tag_ids, '{}'::uuid[])) requested(tag_id)
      left join public.financial_tags tag
        on tag.id = requested.tag_id and tag.organization_id = p_organization_id and tag.active
     where tag.id is null
  ) then
    raise exception using errcode = '22023', message = 'active financial tags are required';
  end if;

  v_payment := public.record_subscription_payment(
    p_organization_id, p_subscription_id, p_cycle_id, p_amount_cents, p_method,
    p_idempotency_key, p_chart_account_id, p_financial_account_id,
    p_external_reference, p_paid_on
  );
  select cycle.financial_entry_id into v_entry_id
    from public.customer_subscription_cycles cycle
   where cycle.id = p_cycle_id and cycle.subscription_id = p_subscription_id
     and cycle.organization_id = p_organization_id;
  if v_entry_id is null then
    select entry.id into v_entry_id from public.financial_entries entry
     where entry.organization_id = p_organization_id
       and entry.subscription_cycle_id = p_cycle_id and entry.source = 'SUBSCRIPTION'
       and entry.canceled_at is null order by entry.created_at desc limit 1;
  end if;
  if v_entry_id is null then
    raise exception using errcode = '22023', message = 'subscription receivable was not found';
  end if;
  update public.financial_entries
     set chart_account_id = p_chart_account_id,
         preferred_financial_account_id = p_financial_account_id,
         cost_center_id = p_cost_center_id,
         document_number = btrim(p_document_number),
         description = btrim(p_description)
   where id = v_entry_id and organization_id = p_organization_id;
  delete from public.financial_entry_tags
   where entry_id = v_entry_id and organization_id = p_organization_id;
  insert into public.financial_entry_tags (organization_id, entry_id, tag_id)
  select p_organization_id, v_entry_id, requested.tag_id
    from (select distinct tag_id from unnest(coalesce(p_tag_ids, '{}'::uuid[])) tag_ids(tag_id)) requested;
  return v_payment;
end;
$$;

create or replace function public.record_subscription_bundle_payment_with_receipt_metadata(
  p_organization_id uuid,
  p_installment_id uuid,
  p_amount_cents bigint,
  p_method public.subscription_payment_method,
  p_chart_account_id uuid,
  p_financial_account_id uuid,
  p_idempotency_key text,
  p_external_reference text,
  p_paid_on date,
  p_cost_center_id uuid,
  p_document_number text,
  p_tag_ids uuid[],
  p_description text
)
returns public.subscription_bundle_payments
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_installment public.subscription_bundle_installments%rowtype;
  v_subscription public.customer_subscriptions%rowtype;
  v_payment public.subscription_bundle_payments%rowtype;
  v_entry_id uuid;
  v_net_settled bigint;
  v_remaining_cents bigint;
  v_financial_method public.financial_payment_method;
  v_paid_at timestamptz;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription bundle payment denied';
  end if;
  if p_method is null then
    raise exception using errcode = '22023', message = 'subscription payment method is required';
  end if;
  if char_length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 200 then
    raise exception using errcode = '22023', message = 'payment idempotency key is required';
  end if;
  select * into v_payment from public.subscription_bundle_payments payment
   where payment.organization_id = p_organization_id and payment.idempotency_key = p_idempotency_key;
  if found then
    if v_payment.installment_id = p_installment_id then return v_payment; end if;
    raise exception using errcode = '23505', message = 'subscription bundle payment idempotency key was already used';
  end if;
  select * into strict v_installment from public.subscription_bundle_installments installment
   where installment.id = p_installment_id and installment.organization_id = p_organization_id for update;
  select * into strict v_subscription from public.customer_subscriptions subscription
   where subscription.id = v_installment.subscription_id and subscription.organization_id = p_organization_id for update;
  v_entry_id := v_installment.financial_entry_id;
  if v_entry_id is null then
    raise exception using errcode = '22023', message = 'subscription receivable has not been generated';
  end if;
  perform 1 from public.financial_entries entry
   where entry.id = v_entry_id and entry.organization_id = p_organization_id
     and entry.source = 'SUBSCRIPTION' and entry.canceled_at is null for update;
  if not found then
    raise exception using errcode = '22023', message = 'active subscription receivable has not been generated';
  end if;
  if v_installment.status = 'PAID' then
    select * into v_payment from public.subscription_bundle_payments payment
     where payment.installment_id = v_installment.id and payment.organization_id = p_organization_id;
    if found then return v_payment; end if;
    raise exception using errcode = '22023', message = 'subscription installment is already settled in Finance';
  end if;
  if v_installment.status not in ('OPEN', 'OVERDUE') or v_subscription.status not in ('ACTIVE', 'CANCELED', 'EXPIRED') then
    raise exception using errcode = '22023', message = 'subscription bundle payment status is invalid';
  end if;
  select coalesce(sum(case when settlement.kind = 'SETTLEMENT' then settlement.amount_cents
      else -settlement.amount_cents end), 0)::bigint
    into v_net_settled from public.financial_settlements settlement
   where settlement.organization_id = p_organization_id and settlement.entry_id = v_entry_id;
  v_remaining_cents := v_installment.amount_cents - v_net_settled;
  if v_remaining_cents <= 0 or p_amount_cents <> v_remaining_cents then
    raise exception using errcode = '22023', message = 'payment amount must match the remaining subscription receivable balance';
  end if;
  if p_chart_account_id is null or not exists (
    select 1 from public.chart_of_accounts account
     where account.id = p_chart_account_id and account.organization_id = p_organization_id
       and account.kind = 'REVENUE' and account.active
  ) then
    raise exception using errcode = '22023', message = 'active revenue account is required';
  end if;
  if p_financial_account_id is null or not exists (
    select 1 from public.financial_accounts account
     where account.id = p_financial_account_id and account.organization_id = p_organization_id
       and account.active
  ) then
    raise exception using errcode = '22023', message = 'active financial account is required';
  end if;
  if p_cost_center_id is not null and not exists (
    select 1 from public.cost_centers center
     where center.id = p_cost_center_id and center.organization_id = p_organization_id
       and center.active
  ) then
    raise exception using errcode = '22023', message = 'active cost center is required';
  end if;
  if char_length(btrim(coalesce(p_description, ''))) not between 2 and 500 then
    raise exception using errcode = '22023', message = 'receipt description is invalid';
  end if;
  if char_length(btrim(coalesce(p_document_number, ''))) not between 2 and 100 then
    raise exception using errcode = '22023', message = 'receipt document number is invalid';
  end if;
  if exists (
    select 1
      from unnest(coalesce(p_tag_ids, '{}'::uuid[])) requested(tag_id)
      left join public.financial_tags tag
        on tag.id = requested.tag_id and tag.organization_id = p_organization_id and tag.active
     where tag.id is null
  ) then
    raise exception using errcode = '22023', message = 'active financial tags are required';
  end if;
  v_financial_method := case p_method::text
    when 'PIX' then 'PIX'::public.financial_payment_method
    when 'CARD' then 'CARD'::public.financial_payment_method
    when 'BOLETO' then 'BOLETO'::public.financial_payment_method
    when 'CASH' then 'CASH'::public.financial_payment_method
    else 'OTHER'::public.financial_payment_method end;
  update public.financial_entries
     set chart_account_id = p_chart_account_id,
         preferred_financial_account_id = p_financial_account_id,
         cost_center_id = p_cost_center_id,
         document_number = btrim(p_document_number),
         description = btrim(p_description)
   where id = v_entry_id and organization_id = p_organization_id;
  delete from public.financial_entry_tags
   where entry_id = v_entry_id and organization_id = p_organization_id;
  insert into public.financial_entry_tags (organization_id, entry_id, tag_id)
  select p_organization_id, v_entry_id, requested.tag_id
    from (select distinct tag_id from unnest(coalesce(p_tag_ids, '{}'::uuid[])) tag_ids(tag_id)) requested;

  perform public.settle_financial_entry(
    v_entry_id, p_financial_account_id, p_amount_cents,
    coalesce(p_paid_on, current_date), v_financial_method,
    nullif(btrim(coalesce(p_external_reference, '')), ''), p_idempotency_key
  );
  select (coalesce(p_paid_on, current_date)::timestamp at time zone organization.timezone)
    into strict v_paid_at from public.organizations organization where organization.id = p_organization_id;
  insert into public.subscription_bundle_payments(
    organization_id, subscription_id, installment_id, amount_cents, method,
    financial_entry_id, idempotency_key, external_reference, paid_at, created_by
  ) values (
    p_organization_id, v_subscription.id, v_installment.id, v_installment.amount_cents,
    p_method, v_entry_id, btrim(p_idempotency_key),
    nullif(btrim(coalesce(p_external_reference, '')), ''), v_paid_at, auth.uid()
  ) on conflict (installment_id) do nothing returning * into v_payment;
  if not found then
    select * into strict v_payment from public.subscription_bundle_payments payment
     where payment.installment_id = v_installment.id and payment.organization_id = p_organization_id;
  end if;
  update public.subscription_bundle_installments set status = 'PAID', paid_at = v_paid_at
   where id = v_installment.id and organization_id = p_organization_id;
  return v_payment;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle installment or account not found';
end;
$$;

revoke all on function public.record_subscription_payment_with_receipt_metadata(uuid,uuid,uuid,bigint,public.subscription_payment_method,text,uuid,uuid,text,date,uuid,text,uuid[],text) from public, anon;
revoke all on function public.record_subscription_bundle_payment_with_receipt_metadata(uuid,uuid,bigint,public.subscription_payment_method,uuid,uuid,text,text,date,uuid,text,uuid[],text) from public, anon;
grant execute on function public.record_subscription_payment_with_receipt_metadata(uuid,uuid,uuid,bigint,public.subscription_payment_method,text,uuid,uuid,text,date,uuid,text,uuid[],text) to authenticated;
grant execute on function public.record_subscription_bundle_payment_with_receipt_metadata(uuid,uuid,bigint,public.subscription_payment_method,uuid,uuid,text,text,date,uuid,text,uuid[],text) to authenticated;
