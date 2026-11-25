-- Allow managers to append unpaid installments to an active bundle contract.
-- The receivable remains linked to the subscription and is created atomically.

alter table public.subscription_bundle_installments
  drop constraint if exists subscription_bundle_installments_installment_number_check,
  drop constraint if exists subscription_bundle_installments_check;

alter table public.subscription_bundle_installments
  add constraint subscription_bundle_installments_installment_number_check
    check (installment_number between 0 and 300),
  add constraint subscription_bundle_installments_check
    check ((kind = 'ENTRY' and installment_number = 0)
        or (kind = 'INSTALLMENT' and installment_number between 1 and 300));

alter table public.subscription_bundle_installments
  add column creation_idempotency_key text,
  add column creation_payload jsonb;

create unique index subscription_bundle_installments_creation_key_uidx
  on public.subscription_bundle_installments (organization_id, creation_idempotency_key)
  where creation_idempotency_key is not null;

alter table public.financial_entries add column notes text;

create or replace function public.add_subscription_bundle_installment(
  p_organization_id uuid,
  p_subscription_id uuid,
  p_amount_cents bigint,
  p_due_on date,
  p_issue_on date,
  p_method public.subscription_payment_method,
  p_chart_account_id uuid,
  p_financial_account_id uuid,
  p_cost_center_id uuid,
  p_document_number text,
  p_tag_ids uuid[],
  p_description text,
  p_idempotency_key text,
  p_observations text default null
)
returns public.subscription_bundle_installments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_subscription public.customer_subscriptions%rowtype;
  v_installment public.subscription_bundle_installments%rowtype;
  v_payload jsonb;
  v_installment_id uuid;
  v_installment_number integer;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription installment creation denied';
  end if;
  if char_length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 200 then
    raise exception using errcode = '22023', message = 'installment idempotency key is required';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 or p_due_on is null or p_issue_on is null or p_due_on < p_issue_on then
    raise exception using errcode = '22023', message = 'installment amount and dates are invalid';
  end if;
  if p_method is null then
    raise exception using errcode = '22023', message = 'installment payment method is required';
  end if;
  if char_length(btrim(coalesce(p_description, ''))) not between 2 and 500
     or char_length(btrim(coalesce(p_document_number, ''))) not between 2 and 100
     or char_length(btrim(coalesce(p_observations, ''))) > 500 then
    raise exception using errcode = '22023', message = 'installment financial details are invalid';
  end if;
  if not exists (
    select 1 from public.chart_of_accounts account
     where account.id = p_chart_account_id and account.organization_id = p_organization_id
       and account.kind = 'REVENUE' and account.active
  ) or not exists (
    select 1 from public.financial_accounts account
     where account.id = p_financial_account_id and account.organization_id = p_organization_id
       and account.active
  ) then
    raise exception using errcode = '22023', message = 'active revenue and financial accounts are required';
  end if;
  if p_cost_center_id is not null and not exists (
    select 1 from public.cost_centers center
     where center.id = p_cost_center_id and center.organization_id = p_organization_id and center.active
  ) then
    raise exception using errcode = '22023', message = 'active cost center is required';
  end if;
  if exists (
    select 1 from unnest(coalesce(p_tag_ids, '{}'::uuid[])) requested(tag_id)
      left join public.financial_tags tag
        on tag.id = requested.tag_id and tag.organization_id = p_organization_id and tag.active
     where tag.id is null
  ) then
    raise exception using errcode = '22023', message = 'active financial tags are required';
  end if;

  v_payload := jsonb_build_object(
    'subscription_id', p_subscription_id,
    'amount_cents', p_amount_cents,
    'due_on', p_due_on,
    'issue_on', p_issue_on,
    'method', p_method,
    'chart_account_id', p_chart_account_id,
    'financial_account_id', p_financial_account_id,
    'cost_center_id', p_cost_center_id,
    'document_number', btrim(p_document_number),
    'tag_ids', coalesce(p_tag_ids, '{}'::uuid[]),
    'description', btrim(p_description),
    'observations', nullif(btrim(coalesce(p_observations, '')), '')
  );

  select * into v_installment from public.subscription_bundle_installments installment
   where installment.organization_id = p_organization_id
     and installment.creation_idempotency_key = btrim(p_idempotency_key);
  if found then
    if v_installment.creation_payload is distinct from v_payload then
      raise exception using errcode = '23505', message = 'installment idempotency key was already used';
    end if;
    return v_installment;
  end if;

  select * into strict v_subscription from public.customer_subscriptions subscription
   where subscription.id = p_subscription_id and subscription.organization_id = p_organization_id
   for update;
  if v_subscription.status <> 'ACTIVE'
     or (v_subscription.contract_accepted_at is null and v_subscription.manager_activated_provisionally_at is null) then
    raise exception using errcode = '22023', message = 'only an active subscription contract can receive an extra installment';
  end if;
  perform 1 from public.subscription_bundle_contracts contract
   where contract.subscription_id = p_subscription_id and contract.organization_id = p_organization_id
   for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'subscription bundle contract not found';
  end if;
  select * into v_installment from public.subscription_bundle_installments installment
   where installment.organization_id = p_organization_id
     and installment.creation_idempotency_key = btrim(p_idempotency_key);
  if found then
    if v_installment.creation_payload is distinct from v_payload then
      raise exception using errcode = '23505', message = 'installment idempotency key was already used';
    end if;
    return v_installment;
  end if;

  select coalesce(max(installment.installment_number), 0) + 1
    into v_installment_number
    from public.subscription_bundle_installments installment
   where installment.subscription_id = p_subscription_id and installment.organization_id = p_organization_id;
  if v_installment_number > 300 then
    raise exception using errcode = '22023', message = 'subscription bundle installment limit reached';
  end if;

  insert into public.subscription_bundle_installments(
    organization_id, subscription_id, installment_number, kind, due_on,
    amount_cents, payment_method, status, creation_idempotency_key, creation_payload
  ) values (
    p_organization_id, p_subscription_id, v_installment_number, 'INSTALLMENT', p_due_on,
    p_amount_cents, p_method, 'OPEN', btrim(p_idempotency_key), v_payload
  ) returning id into v_installment_id;

  select * into strict v_installment from public.subscription_bundle_installments installment
   where installment.id = v_installment_id and installment.organization_id = p_organization_id;

  if v_installment.financial_entry_id is null then
    raise exception using errcode = '22023', message = 'subscription receivable was not created';
  end if;
  update public.financial_entries
     set issue_date = p_issue_on,
         competence_date = p_issue_on,
         due_date = p_due_on,
         total_cents = p_amount_cents,
         chart_account_id = p_chart_account_id,
         preferred_financial_account_id = p_financial_account_id,
         cost_center_id = p_cost_center_id,
         document_number = btrim(p_document_number),
         description = btrim(p_description),
         notes = nullif(btrim(coalesce(p_observations, '')), '')
   where id = v_installment.financial_entry_id and organization_id = p_organization_id
     and source = 'SUBSCRIPTION' and canceled_at is null;
  if not found then
    raise exception using errcode = '22023', message = 'subscription receivable could not be updated';
  end if;
  delete from public.financial_entry_tags
   where entry_id = v_installment.financial_entry_id and organization_id = p_organization_id;
  insert into public.financial_entry_tags (organization_id, entry_id, tag_id)
  select p_organization_id, v_installment.financial_entry_id, requested.tag_id
    from (select distinct tag_id from unnest(coalesce(p_tag_ids, '{}'::uuid[])) tag_ids(tag_id)) requested;

  select * into strict v_installment from public.subscription_bundle_installments installment
   where installment.id = v_installment.id and installment.organization_id = p_organization_id;
  return v_installment;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle contract not found';
end;
$$;

revoke all on function public.add_subscription_bundle_installment(uuid,uuid,bigint,date,date,public.subscription_payment_method,uuid,uuid,uuid,text,uuid[],text,text,text) from public, anon;
grant execute on function public.add_subscription_bundle_installment(uuid,uuid,bigint,date,date,public.subscription_payment_method,uuid,uuid,uuid,text,uuid[],text,text,text) to authenticated;
