-- Session bundle plans are additive. Existing cycle subscriptions keep their old schema and RPCs.
alter type public.subscription_payment_method add value if not exists 'CRYPTO';

alter table public.subscription_plan_versions
  add column if not exists model text not null default 'LEGACY_CYCLE',
  add column if not exists bundle_scheduling_mode text,
  add column if not exists bundle_service_id uuid,
  add column if not exists bundle_sessions_per_week smallint,
  add column if not exists bundle_session_duration_minutes smallint,
  add column if not exists bundle_total_sessions smallint,
  add column if not exists bundle_price_per_session_cents bigint,
  add column if not exists bundle_entry_cents bigint,
  add column if not exists bundle_installment_count smallint,
  add column if not exists bundle_discount_type text,
  add column if not exists bundle_discount_value bigint;

alter table public.subscription_plan_versions
  add constraint subscription_plan_versions_model_check
    check (model in ('LEGACY_CYCLE', 'SESSION_BUNDLE_V1')),
  add constraint subscription_plan_versions_bundle_fields_check
    check (
      (model = 'LEGACY_CYCLE'
        and bundle_scheduling_mode is null and bundle_service_id is null
        and bundle_sessions_per_week is null and bundle_session_duration_minutes is null
        and bundle_total_sessions is null and bundle_price_per_session_cents is null
        and bundle_entry_cents is null and bundle_installment_count is null
        and bundle_discount_type is null and bundle_discount_value is null)
      or
      (model = 'SESSION_BUNDLE_V1'
        and bundle_scheduling_mode in ('FREE', 'FIXED')
        and bundle_service_id is not null
        and bundle_sessions_per_week between 1 and 21
        and bundle_session_duration_minutes between 5 and 180
        and bundle_total_sessions between 1 and 300
        and bundle_price_per_session_cents > 0
        and bundle_entry_cents >= 0
        and bundle_installment_count between 1 and 24
        and bundle_discount_type in ('NONE', 'FIXED', 'PERCENT')
        and bundle_discount_value >= 0)
    ),
  add constraint subscription_plan_versions_bundle_service_fk
    foreign key (bundle_service_id, organization_id)
    references public.services(id, organization_id);

create table public.subscription_bundle_contracts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  subscription_id uuid not null,
  plan_version_id uuid not null,
  scheduling_mode text not null check (scheduling_mode in ('FREE', 'FIXED')),
  service_id uuid not null,
  sessions_per_week smallint not null check (sessions_per_week between 1 and 21),
  session_duration_minutes smallint not null check (session_duration_minutes between 5 and 180),
  total_sessions smallint not null check (total_sessions between 1 and 300),
  price_per_session_cents bigint not null check (price_per_session_cents > 0),
  total_price_cents bigint not null check (total_price_cents > 0),
  entry_cents bigint not null check (entry_cents >= 0),
  installment_count smallint not null check (installment_count between 1 and 24),
  discount_type text not null check (discount_type in ('NONE', 'FIXED', 'PERCENT')),
  discount_value bigint not null check (discount_value >= 0),
  entry_due_on date not null,
  first_installment_due_on date not null,
  first_session_date date not null,
  idempotency_key text not null,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (subscription_id),
  unique (organization_id, idempotency_key),
  unique (id, organization_id),
  foreign key (subscription_id, organization_id)
    references public.customer_subscriptions(id, organization_id) on delete cascade,
  foreign key (plan_version_id, organization_id)
    references public.subscription_plan_versions(id, organization_id),
  foreign key (service_id, organization_id)
    references public.services(id, organization_id),
  check (total_price_cents = price_per_session_cents * total_sessions),
  check ((discount_type = 'NONE' and discount_value = 0)
      or (discount_type = 'FIXED' and discount_value > 0)
      or (discount_type = 'PERCENT' and discount_value between 1 and 9999))
);

create table public.subscription_bundle_installments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  subscription_id uuid not null,
  installment_number smallint not null check (installment_number between 0 and 24),
  kind text not null check (kind in ('ENTRY', 'INSTALLMENT')),
  due_on date not null,
  amount_cents bigint not null check (amount_cents >= 0),
  payment_method public.subscription_payment_method not null,
  status text not null default 'OPEN' check (status in ('OPEN', 'PAID', 'OVERDUE', 'CANCELED')),
  financial_entry_id uuid,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique (subscription_id, installment_number),
  unique (id, organization_id),
  foreign key (subscription_id, organization_id)
    references public.customer_subscriptions(id, organization_id) on delete cascade,
  check ((kind = 'ENTRY' and installment_number = 0)
      or (kind = 'INSTALLMENT' and installment_number between 1 and 24)),
  check ((status = 'PAID' and paid_at is not null) or status <> 'PAID')
);

create table public.subscription_bundle_sessions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  subscription_id uuid not null,
  session_number smallint not null check (session_number between 1 and 300),
  release_on date not null,
  scheduled_for timestamptz,
  installment_number smallint not null check (installment_number between 1 and 24),
  status text not null default 'AVAILABLE' check (status in ('AVAILABLE', 'SCHEDULED', 'COMPLETED', 'CONSUMED', 'CANCELED')),
  appointment_id uuid,
  barber_id uuid,
  environment_id uuid,
  commission_mode public.commission_mode,
  commission_percentage_bps integer,
  commission_fixed_cents bigint,
  completed_at timestamptz,
  canceled_at timestamptz,
  created_at timestamptz not null default now(),
  unique (subscription_id, session_number),
  unique (id, organization_id),
  foreign key (subscription_id, organization_id)
    references public.customer_subscriptions(id, organization_id) on delete cascade,
  foreign key (appointment_id, organization_id)
    references public.appointments(id, organization_id),
  foreign key (barber_id, organization_id)
    references public.barbers(id, organization_id),
  foreign key (environment_id, organization_id)
    references public.agenda_environments(id, organization_id),
  check ((commission_mode is null and commission_percentage_bps is null and commission_fixed_cents is null)
      or (commission_mode = 'PERCENT' and commission_percentage_bps between 0 and 10000 and commission_fixed_cents is null)
      or (commission_mode = 'FIXED' and commission_fixed_cents >= 0 and commission_percentage_bps is null)),
  check ((status = 'SCHEDULED' and appointment_id is not null and scheduled_for is not null)
      or status <> 'SCHEDULED'),
  check ((status = 'COMPLETED' and completed_at is not null) or status <> 'COMPLETED')
);

create table public.subscription_bundle_fixed_slots (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  subscription_id uuid not null,
  slot_number smallint not null check (slot_number between 1 and 21),
  barber_id uuid not null,
  environment_id uuid not null,
  barber_name_snapshot text not null,
  environment_name_snapshot text not null,
  weekday smallint not null check (weekday between 0 and 6),
  local_time time not null,
  created_at timestamptz not null default now(),
  unique (subscription_id, slot_number),
  unique (subscription_id, weekday, local_time),
  foreign key (subscription_id, organization_id)
    references public.customer_subscriptions(id, organization_id) on delete cascade,
  foreign key (barber_id, organization_id)
    references public.barbers(id, organization_id),
  foreign key (environment_id, organization_id)
    references public.agenda_environments(id, organization_id)
);

create table public.subscription_bundle_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  subscription_id uuid not null,
  installment_id uuid not null,
  amount_cents bigint not null check (amount_cents > 0),
  method public.subscription_payment_method not null,
  financial_entry_id uuid,
  idempotency_key text not null,
  external_reference text,
  paid_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  unique (organization_id, idempotency_key),
  unique (installment_id),
  foreign key (subscription_id, organization_id)
    references public.customer_subscriptions(id, organization_id) on delete cascade,
  foreign key (installment_id, organization_id)
    references public.subscription_bundle_installments(id, organization_id),
  foreign key (financial_entry_id, organization_id)
    references public.financial_entries(id, organization_id)
);

alter table public.appointments
  add column subscription_bundle_session_id uuid;
alter table public.appointments
  add constraint appointments_subscription_bundle_session_fk
  foreign key (subscription_bundle_session_id, organization_id)
  references public.subscription_bundle_sessions(id, organization_id);
create index appointments_subscription_bundle_session_idx
  on public.appointments(organization_id, subscription_bundle_session_id)
  where subscription_bundle_session_id is not null;
alter table public.subscription_bundle_sessions
  add constraint subscription_bundle_sessions_appointment_fk
  foreign key (appointment_id, organization_id)
  references public.appointments(id, organization_id);

alter table public.financial_entries
  add column subscription_bundle_installment_id uuid;
alter table public.financial_entries
  add constraint financial_entries_bundle_installment_fk
  foreign key (subscription_bundle_installment_id, organization_id)
  references public.subscription_bundle_installments(id, organization_id);
alter table public.subscription_bundle_installments
  add constraint subscription_bundle_installments_financial_entry_fk
  foreign key (financial_entry_id, organization_id)
  references public.financial_entries(id, organization_id);
alter table public.financial_entries
  drop constraint if exists financial_entries_subscription_source_check;
alter table public.financial_entries
  drop constraint if exists financial_entries_project_source_check;
alter table public.financial_entries
  drop constraint if exists financial_entries_source_check;
alter table public.financial_entries
  add constraint financial_entries_subscription_source_check check (
    (source = 'APPOINTMENT' and appointment_id is not null and subscription_cycle_id is null and subscription_bundle_installment_id is null)
    or (source = 'SUBSCRIPTION' and appointment_id is null and ((subscription_cycle_id is not null and subscription_bundle_installment_id is null) or (subscription_cycle_id is null and subscription_bundle_installment_id is not null)))
    or (source = 'PROJECT' and project_installment_id is not null and appointment_id is null and subscription_cycle_id is null and subscription_bundle_installment_id is null)
    or (source = 'MANUAL' and appointment_id is null and subscription_cycle_id is null and subscription_bundle_installment_id is null)
  );

alter table public.commission_ledger add column subscription_bundle_session_id uuid;
alter table public.commission_ledger
  add constraint commission_ledger_bundle_session_fk
  foreign key (subscription_bundle_session_id, organization_id)
  references public.subscription_bundle_sessions(id, organization_id);
alter table public.commission_ledger
  drop constraint if exists commission_ledger_session_source_check;
alter table public.commission_ledger
  add constraint commission_ledger_session_source_check check (
    (subscription_session_id is null and subscription_bundle_session_id is null)
    or (kind = 'EARNED' and appointment_id is not null and appointment_item_id is null and project_internal_service_id is null
      and (subscription_session_id is null or subscription_bundle_session_id is null))
  );
create unique index commission_ledger_subscription_bundle_session_key
  on public.commission_ledger(organization_id, subscription_bundle_session_id)
  where kind = 'EARNED' and subscription_bundle_session_id is not null;

create index subscription_bundle_installments_due_idx
  on public.subscription_bundle_installments(organization_id, due_on, status);
create index subscription_bundle_sessions_customer_idx
  on public.subscription_bundle_sessions(organization_id, subscription_id, status, release_on);

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'subscription_bundle_contracts', 'subscription_bundle_installments',
    'subscription_bundle_sessions', 'subscription_bundle_fixed_slots',
    'subscription_bundle_payments'
  ] loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('alter table public.%I force row level security', v_table);
  end loop;
end $$;

create policy subscription_bundle_contract_participant_select
  on public.subscription_bundle_contracts for select to authenticated
  using (public.is_organization_owner(organization_id) or exists (
    select 1 from public.customer_subscriptions s where s.id = subscription_bundle_contracts.subscription_id
      and s.organization_id = subscription_bundle_contracts.organization_id
      and public.is_organization_customer(s.organization_id, s.customer_id)
  ));
create policy subscription_bundle_installment_participant_select
  on public.subscription_bundle_installments for select to authenticated
  using (public.is_organization_owner(organization_id) or exists (
    select 1 from public.customer_subscriptions s where s.id = subscription_bundle_installments.subscription_id
      and s.organization_id = subscription_bundle_installments.organization_id
      and public.is_organization_customer(s.organization_id, s.customer_id)
  ));
create policy subscription_bundle_session_participant_select
  on public.subscription_bundle_sessions for select to authenticated
  using (public.is_organization_owner(organization_id) or exists (
    select 1 from public.customer_subscriptions s where s.id = subscription_bundle_sessions.subscription_id
      and s.organization_id = subscription_bundle_sessions.organization_id
      and public.is_organization_customer(s.organization_id, s.customer_id)
  ));
create policy subscription_bundle_fixed_slot_participant_select
  on public.subscription_bundle_fixed_slots for select to authenticated
  using (public.is_organization_owner(organization_id) or exists (
    select 1 from public.customer_subscriptions s where s.id = subscription_bundle_fixed_slots.subscription_id
      and s.organization_id = subscription_bundle_fixed_slots.organization_id
      and public.is_organization_customer(s.organization_id, s.customer_id)
  ));
create policy subscription_bundle_payments_owner_select
  on public.subscription_bundle_payments for select to authenticated
  using (public.is_organization_owner(organization_id) or exists (
    select 1 from public.customer_subscriptions s where s.id = subscription_bundle_payments.subscription_id
      and s.organization_id = subscription_bundle_payments.organization_id
      and public.is_organization_customer(s.organization_id, s.customer_id)
  ));
grant select on public.subscription_bundle_contracts, public.subscription_bundle_installments,
  public.subscription_bundle_sessions, public.subscription_bundle_fixed_slots,
  public.subscription_bundle_payments to authenticated;

alter view public.commission_service_details rename to commission_service_details_before_bundle_v2;
create view public.commission_service_details with (security_invoker = true) as
select * from public.commission_service_details_before_bundle_v2
union all
select session.organization_id, appointment.id, null::uuid, appointment.customer_id,
  customer.full_name, appointment.barber_id, contract.service_id,
  'Sessão do plano · ' || plan.name, appointment.location_id,
  (lower(appointment.service_period) at time zone organization.timezone)::date,
  contract.price_per_session_cents, 'Recebimento do plano'::text,
  coalesce(ledger_totals.commission_cents, 0)::bigint,
  coalesce(paid_totals.paid_commission_cents, 0)::bigint,
  greatest(coalesce(ledger_totals.commission_cents, 0) - coalesce(paid_totals.paid_commission_cents, 0), 0)::bigint,
  (installment.paid_at at time zone organization.timezone)::date,
  null::uuid, null::uuid, null::uuid, false,
  'SUBSCRIPTION_BUNDLE_SESSION'::text, session.id
from public.subscription_bundle_sessions session
join public.customer_subscriptions subscription
  on subscription.id = session.subscription_id and subscription.organization_id = session.organization_id
join public.subscription_plans plan
  on plan.id = subscription.plan_id and plan.organization_id = subscription.organization_id
join public.subscription_bundle_contracts contract
  on contract.subscription_id = session.subscription_id and contract.organization_id = session.organization_id
join public.subscription_bundle_installments installment
  on installment.subscription_id = session.subscription_id
 and installment.organization_id = session.organization_id
 and installment.installment_number = session.installment_number
join public.appointments appointment
  on appointment.id = session.appointment_id and appointment.organization_id = session.organization_id
join public.customers customer
  on customer.id = appointment.customer_id and customer.organization_id = appointment.organization_id
join public.organizations organization on organization.id = session.organization_id
left join lateral (
  select sum(ledger.amount_cents)::bigint as commission_cents
  from public.commission_ledger ledger
  where ledger.organization_id = session.organization_id
    and ledger.subscription_bundle_session_id = session.id
) ledger_totals on true
left join lateral (
  select greatest(sum(settlement.amount_cents - coalesce(reversals.amount_cents, 0)), 0)::bigint as paid_commission_cents
  from public.commission_payout_items payout_item
  join public.commission_payout_settlements settlement
    on settlement.organization_id = payout_item.organization_id and settlement.payout_id = payout_item.payout_id
  left join (
    select organization_id, settlement_id, sum(amount_cents)::bigint as amount_cents
    from public.commission_payout_settlement_reversals group by organization_id, settlement_id
  ) reversals on reversals.organization_id = settlement.organization_id and reversals.settlement_id = settlement.id
  join public.commission_ledger ledger
    on ledger.organization_id = payout_item.organization_id and ledger.id = payout_item.ledger_entry_id
  where payout_item.organization_id = session.organization_id
    and ledger.subscription_bundle_session_id = session.id
) paid_totals on true
where session.status = 'COMPLETED' and appointment.status = 'COMPLETED'
  and installment.status = 'PAID' and coalesce(ledger_totals.commission_cents, 0) > 0;
grant select on public.commission_service_details to authenticated;

create or replace function public.save_subscription_bundle_plan(
  p_organization_id uuid,
  p_plan_id uuid,
  p_name text,
  p_description text,
  p_service_id uuid,
  p_scheduling_mode text,
  p_sessions_per_week smallint,
  p_session_duration_minutes smallint,
  p_total_sessions smallint,
  p_price_per_session_cents bigint,
  p_entry_cents bigint,
  p_payment_method text,
  p_installment_count smallint,
  p_discount_type text,
  p_discount_value bigint
)
returns public.subscription_plans
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_plan public.subscription_plans%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_version_number integer;
  v_total bigint;
  v_min_installment bigint;
  v_payment_method public.subscription_payment_method;
  v_service public.services%rowtype;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription plan denied';
  end if;
  if not public.organization_module_enabled(p_organization_id, 'subscription_plans') then
    raise exception using errcode = '42501', message = 'subscription module disabled';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 120
     or p_scheduling_mode not in ('FREE', 'FIXED')
     or p_sessions_per_week not between 1 and 21
     or p_session_duration_minutes not between 5 and 180
     or p_total_sessions not between 1 and 300
     or p_price_per_session_cents <= 0
     or p_entry_cents < 0
     or p_installment_count not between 1 and 24
     or p_discount_type not in ('NONE', 'FIXED', 'PERCENT')
     or p_discount_value < 0 then
    raise exception using errcode = '22023', message = 'invalid subscription bundle plan';
  end if;
  if p_discount_type = 'NONE' and p_discount_value <> 0
     or p_discount_type = 'PERCENT' and p_discount_value not between 1 and 9999
     or p_discount_type = 'FIXED' and p_discount_value <= 0 then
    raise exception using errcode = '22023', message = 'invalid subscription bundle discount';
  end if;
  v_total := p_price_per_session_cents * p_total_sessions;
  v_min_installment := floor(v_total::numeric / p_installment_count)::bigint;
  if v_min_installment < 1 then
    raise exception using errcode = '22023', message = 'subscription total must cover every installment';
  end if;
  if p_discount_type = 'FIXED' and p_discount_value >= v_min_installment then
    raise exception using errcode = '22023', message = 'installment discount exceeds installment value';
  end if;
  if p_discount_type = 'PERCENT'
     and round(v_min_installment::numeric * p_discount_value / 10000)::bigint >= v_min_installment then
    raise exception using errcode = '22023', message = 'installment discount results in a zero or negative amount';
  end if;
  if upper(p_payment_method) not in ('ONLINE', 'CARD', 'PIX', 'BOLETO', 'CASH', 'CRYPTO') then
    raise exception using errcode = '22023', message = 'invalid subscription bundle payment method';
  end if;
  v_payment_method := upper(p_payment_method)::public.subscription_payment_method;
  select * into strict v_service from public.services
   where id = p_service_id and organization_id = p_organization_id and active and accepts_subscription;

  if p_plan_id is null then
    insert into public.subscription_plans(organization_id, name, description, created_by)
    values (p_organization_id, btrim(p_name), nullif(btrim(p_description), ''), auth.uid())
    returning * into v_plan;
    v_version_number := 1;
  else
    select * into strict v_plan from public.subscription_plans
     where id = p_plan_id and organization_id = p_organization_id and archived_at is null
     for update;
    update public.subscription_plans set name = btrim(p_name),
      description = nullif(btrim(p_description), ''), updated_at = now()
     where id = v_plan.id returning * into v_plan;
    select coalesce(max(version), 0) + 1 into v_version_number
      from public.subscription_plan_versions where plan_id = v_plan.id;
  end if;

  insert into public.subscription_plan_versions(
    organization_id, plan_id, version, price_cents, billing_period, duration_months,
    sessions_per_cycle, cancellation_policy, session_cancellation_policy,
    contract_version, payment_method, model, bundle_scheduling_mode,
    bundle_service_id, bundle_sessions_per_week, bundle_session_duration_minutes,
    bundle_total_sessions, bundle_price_per_session_cents, bundle_entry_cents,
    bundle_installment_count, bundle_discount_type, bundle_discount_value, created_by
  ) values (
    p_organization_id, v_plan.id, v_version_number, v_total, 'MONTHLY', 1, 1,
    'Plano contratado por sessões.', 'Cancelamento de sessões conforme disponibilidade do plano.',
    'v1', v_payment_method, 'SESSION_BUNDLE_V1', p_scheduling_mode,
    v_service.id, p_sessions_per_week, p_session_duration_minutes, p_total_sessions,
    p_price_per_session_cents, p_entry_cents, p_installment_count,
    p_discount_type, p_discount_value, auth.uid()
  ) returning * into v_version;

  insert into public.subscription_plan_services(
    organization_id, plan_version_id, service_id, position, service_name_snapshot,
    list_price_cents_snapshot, duration_minutes_snapshot
  ) values (
    p_organization_id, v_version.id, v_service.id, 0, v_service.name,
    v_service.price_cents, p_session_duration_minutes
  );
  return v_plan;
end;
$$;
revoke all on function public.save_subscription_bundle_plan(uuid,uuid,text,text,uuid,text,smallint,smallint,smallint,bigint,bigint,text,smallint,text,bigint)
  from public, anon;
grant execute on function public.save_subscription_bundle_plan(uuid,uuid,text,text,uuid,text,smallint,smallint,smallint,bigint,bigint,text,smallint,text,bigint)
  to authenticated;

create or replace function public.subscription_bundle_weeks_in_month(p_month date)
returns integer language sql immutable parallel safe set search_path = pg_temp as $$
  with month_days as (
    select (date_trunc('month', p_month::timestamp)::date + gs.i)::date as day
    from generate_series(0, extract(day from (date_trunc('month', p_month::timestamp) + interval '1 month - 1 day'))::integer - 1) as gs(i)
  ), weeks as (
    select date_trunc('week', day::timestamp)::date as week_start, count(*) as days_in_month
    from month_days group by 1
  )
  select count(*)::integer from weeks where days_in_month >= 4;
$$;
revoke all on function public.subscription_bundle_weeks_in_month(date) from public, anon, authenticated;

create or replace function public.create_subscription_bundle_offer(
  p_organization_id uuid,
  p_customer_id uuid,
  p_plan_id uuid,
  p_first_session_date date,
  p_entry_due_on date,
  p_first_installment_due_on date,
  p_fixed_slots jsonb,
  p_idempotency_key text
)
returns public.customer_subscriptions
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_plan public.subscription_plans%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_service public.services%rowtype;
  v_sub public.customer_subscriptions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_slot jsonb;
  v_fixed_slots jsonb := coalesce(p_fixed_slots, '[]'::jsonb);
  v_contract_version text;
  v_weekday integer;
  v_local_time time;
  v_barber_id uuid;
  v_environment_id uuid;
  v_existing_subscription_id uuid;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription offer denied';
  end if;
  if not public.organization_module_enabled(p_organization_id, 'subscription_plans') then
    raise exception using errcode = '42501', message = 'subscription module disabled';
  end if;
  if char_length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 200
     or p_first_session_date is null or p_entry_due_on is null
     or p_first_installment_due_on is null then
    raise exception using errcode = '22023', message = 'subscription bundle contract dates or idempotency key are invalid';
  end if;
  select sub.id into v_existing_subscription_id
    from public.subscription_bundle_contracts contract
    join public.customer_subscriptions sub on sub.id = contract.subscription_id
      and sub.organization_id = contract.organization_id
   where contract.organization_id = p_organization_id
     and contract.idempotency_key = btrim(p_idempotency_key);
  if v_existing_subscription_id is not null then
    select sub.* into strict v_sub from public.customer_subscriptions sub
     where sub.id = v_existing_subscription_id and sub.organization_id = p_organization_id;
    if v_sub.customer_id = p_customer_id and v_sub.plan_id = p_plan_id then return v_sub; end if;
    raise exception using errcode = '23505', message = 'subscription bundle idempotency key was already used';
  end if;
  select s.* into strict v_plan from public.subscription_plans s
   where s.id = p_plan_id and s.organization_id = p_organization_id
     and s.active and s.archived_at is null;
  select v.* into strict v_version from public.subscription_plan_versions v
   where v.plan_id = p_plan_id and v.organization_id = p_organization_id
     and v.model = 'SESSION_BUNDLE_V1'
   order by v.version desc limit 1;
  select s.* into strict v_service from public.services s
   where s.id = v_version.bundle_service_id and s.organization_id = p_organization_id
     and s.active and s.accepts_subscription;
  if not exists (select 1 from public.customers c where c.id = p_customer_id
      and c.organization_id = p_organization_id and c.active and c.merged_into_customer_id is null) then
    raise exception using errcode = '22023', message = 'subscription customer is inactive';
  end if;
  if p_first_session_date < (select (now() at time zone o.timezone)::date from public.organizations o where o.id = p_organization_id)
     or p_entry_due_on < (select (now() at time zone o.timezone)::date from public.organizations o where o.id = p_organization_id)
     or p_first_installment_due_on < p_entry_due_on then
    raise exception using errcode = '22023', message = 'subscription bundle dates must be current or future and ordered';
  end if;
  if v_version.bundle_discount_type = 'FIXED'
     and v_version.bundle_discount_value >= floor(v_version.price_cents::numeric / v_version.bundle_installment_count)::bigint then
    raise exception using errcode = '22023', message = 'installment discount exceeds installment value';
  end if;
  if exists (select 1 from public.customer_subscriptions sub
      where sub.organization_id = p_organization_id and sub.customer_id = p_customer_id
        and sub.plan_id = p_plan_id and sub.status in ('REQUESTED', 'PENDING_PAYMENT', 'ACTIVE')) then
    raise exception using errcode = '23505', message = 'customer already has this plan';
  end if;
  if v_version.bundle_scheduling_mode = 'FIXED' then
    if jsonb_typeof(v_fixed_slots) <> 'array'
       or jsonb_array_length(v_fixed_slots) <> v_version.bundle_sessions_per_week then
      raise exception using errcode = '22023', message = 'fixed schedule must contain one slot for each weekly session';
    end if;
    if exists (
      select 1 from jsonb_array_elements(v_fixed_slots) slot(value)
      where nullif(slot.value->>'barber_id', '') is null or nullif(slot.value->>'environment_id', '') is null
         or nullif(slot.value->>'weekday', '') is null or (slot.value->>'weekday')::integer not between 0 and 6
         or nullif(slot.value->>'local_time', '') is null or (slot.value->>'local_time')::time is null
    ) or (select count(*) from (
      select (slot.value->>'weekday')::integer, (slot.value->>'local_time')::time
      from jsonb_array_elements(v_fixed_slots) slot(value)
      group by 1, 2 having count(*) > 1
    ) duplicates) > 0 then
      raise exception using errcode = '22023', message = 'fixed schedule slots are invalid or overlap';
    end if;
    if exists (
      select 1
        from jsonb_array_elements(v_fixed_slots) with ordinality as left_slot(value, ordinality)
        join jsonb_array_elements(v_fixed_slots) with ordinality as right_slot(value, ordinality)
          on left_slot.ordinality < right_slot.ordinality
         and (left_slot.value->>'weekday')::integer = (right_slot.value->>'weekday')::integer
         and abs(extract(epoch from ((left_slot.value->>'local_time')::time - (right_slot.value->>'local_time')::time)))
           < v_version.bundle_session_duration_minutes * 60
    ) then
      raise exception using errcode = '22023', message = 'fixed schedule sessions cannot overlap';
    end if;
    for v_slot in select value from jsonb_array_elements(v_fixed_slots)
    loop
      v_barber_id := (v_slot->>'barber_id')::uuid;
      v_environment_id := (v_slot->>'environment_id')::uuid;
      v_weekday := (v_slot->>'weekday')::integer;
      v_local_time := (v_slot->>'local_time')::time;
      if not exists (select 1 from public.barbers b where b.id = v_barber_id
          and b.organization_id = p_organization_id and b.active)
         or not exists (select 1 from public.agenda_environments e where e.id = v_environment_id
          and e.organization_id = p_organization_id and e.active)
         or not exists (select 1 from public.barber_services bs where bs.organization_id = p_organization_id
          and bs.barber_id = v_barber_id and bs.service_id = v_service.id and bs.active)
         or not exists (select 1 from public.barber_subscription_plans bp where bp.organization_id = p_organization_id
          and bp.barber_id = v_barber_id and bp.plan_id = p_plan_id and bp.active)
         or not exists (select 1 from public.commission_rules cr where cr.organization_id = p_organization_id
          and cr.barber_id = v_barber_id and cr.subscription_plan_id = p_plan_id
          and cr.active and cr.effective_period @> now()) then
        raise exception using errcode = '22023', message = 'fixed schedule professional, room or subscription commission is not configured';
      end if;
    end loop;
  elsif jsonb_typeof(v_fixed_slots) = 'array' and jsonb_array_length(v_fixed_slots) > 0 then
    raise exception using errcode = '22023', message = 'free subscription plans cannot include fixed schedule slots';
  end if;

  select version into v_contract_version from public.subscription_contract_versions
   where active order by created_at desc limit 1;
  if v_contract_version is null then
    raise exception using errcode = '55000', message = 'subscription contract version is not configured';
  end if;
  perform set_config('app.subscription_bundle_offer', '1', true);
  insert into public.customer_subscriptions(
    organization_id, customer_id, plan_id, plan_version_id, status, payment_method,
    upfront_payment, contract_version, first_due_date, created_by
  ) values (
    p_organization_id, p_customer_id, p_plan_id, v_version.id, 'REQUESTED',
    v_version.payment_method, false, v_contract_version, p_first_installment_due_on, auth.uid()
  ) returning * into v_sub;
  insert into public.subscription_bundle_contracts(
    organization_id, subscription_id, plan_version_id, scheduling_mode, service_id,
    sessions_per_week, session_duration_minutes, total_sessions, price_per_session_cents,
    total_price_cents, entry_cents, installment_count, discount_type, discount_value,
    entry_due_on, first_installment_due_on, first_session_date, idempotency_key
  ) values (
    p_organization_id, v_sub.id, v_version.id, v_version.bundle_scheduling_mode,
    v_service.id, v_version.bundle_sessions_per_week, v_version.bundle_session_duration_minutes,
    v_version.bundle_total_sessions, v_version.bundle_price_per_session_cents,
    v_version.price_cents, v_version.bundle_entry_cents, v_version.bundle_installment_count,
    v_version.bundle_discount_type, v_version.bundle_discount_value, p_entry_due_on,
    p_first_installment_due_on, p_first_session_date, btrim(p_idempotency_key)
  ) returning * into v_contract;
  if v_version.bundle_scheduling_mode = 'FIXED' then
    insert into public.subscription_bundle_fixed_slots(
      organization_id, subscription_id, slot_number, barber_id, environment_id,
      barber_name_snapshot, environment_name_snapshot, weekday, local_time
    )
    select p_organization_id, v_sub.id, row_number() over (order by slot.ordinality)::smallint,
      barber.id, environment.id, barber.display_name, environment.name,
      (slot.value->>'weekday')::smallint, (slot.value->>'local_time')::time
    from jsonb_array_elements(v_fixed_slots) with ordinality slot
    join public.barbers barber on barber.id = (slot.value->>'barber_id')::uuid
      and barber.organization_id = p_organization_id
    join public.agenda_environments environment on environment.id = (slot.value->>'environment_id')::uuid
      and environment.organization_id = p_organization_id;
  end if;
  return v_sub;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription plan, service, customer or contract not found';
end;
$$;
revoke all on function public.create_subscription_bundle_offer(uuid,uuid,uuid,date,date,date,jsonb,text) from public, anon;
grant execute on function public.create_subscription_bundle_offer(uuid,uuid,uuid,date,date,date,jsonb,text) to authenticated;

create or replace function public.subscription_bundle_commission_snapshot(
  p_organization_id uuid, p_plan_id uuid, p_barber_id uuid, p_at timestamptz
)
returns table(mode public.commission_mode, percentage_bps integer, fixed_cents bigint)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  return query
  select rule.mode, rule.percentage_bps, rule.fixed_cents
    from public.commission_rules rule
   where rule.organization_id = p_organization_id and rule.barber_id = p_barber_id
     and rule.subscription_plan_id = p_plan_id and rule.active and rule.effective_period @> p_at
   order by lower(rule.effective_period) desc limit 1;
end;
$$;
revoke all on function public.subscription_bundle_commission_snapshot(uuid,uuid,uuid,timestamptz)
  from public, anon, authenticated;

create or replace function public.create_subscription_bundle_appointment(
  p_organization_id uuid,
  p_customer_id uuid,
  p_subscription_id uuid,
  p_session_id uuid,
  p_barber_id uuid,
  p_environment_id uuid,
  p_starts_at timestamptz,
  p_actor_id uuid,
  p_source public.booking_source
)
returns uuid
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_org public.organizations%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_service public.services%rowtype;
  v_barber public.barbers%rowtype;
  v_period tstzrange;
  v_occupied integer;
  v_appointment_id uuid;
  v_commission_mode public.commission_mode;
  v_commission_percentage_bps integer;
  v_commission_fixed_cents bigint;
  v_session_number smallint;
  v_resolved_environment_id uuid;
begin
  select * into strict v_org from public.organizations where id = p_organization_id;
  select version.* into strict v_version
    from public.customer_subscriptions sub
    join public.subscription_plan_versions version on version.id = sub.plan_version_id and version.organization_id = sub.organization_id
   where sub.id = p_subscription_id and sub.organization_id = p_organization_id;
  select * into strict v_service from public.services
   where id = v_version.bundle_service_id and organization_id = p_organization_id and active;
  select * into strict v_barber from public.barbers
   where id = p_barber_id and organization_id = p_organization_id and active;
  if not exists (select 1 from public.barber_services bs where bs.organization_id = p_organization_id
      and bs.barber_id = p_barber_id and bs.service_id = v_service.id and bs.active)
     or not exists (select 1 from public.barber_subscription_plans bp where bp.organization_id = p_organization_id
      and bp.barber_id = p_barber_id and bp.plan_id = v_version.plan_id and bp.active) then
    raise exception using errcode = '22023', message = 'professional is not configured for this subscription service and plan';
  end if;
  select snapshot.mode, snapshot.percentage_bps, snapshot.fixed_cents
    into v_commission_mode, v_commission_percentage_bps, v_commission_fixed_cents
    from public.subscription_bundle_commission_snapshot(
      p_organization_id, v_version.plan_id, p_barber_id, p_starts_at
    ) snapshot;
  if v_commission_mode is null then
    raise exception using errcode = '22023', message = 'professional subscription commission is not configured';
  end if;
  if extract(second from p_starts_at at time zone v_org.timezone) <> 0
     or mod(extract(minute from p_starts_at at time zone v_org.timezone)::integer, v_org.slot_interval_minutes) <> 0 then
    raise exception using errcode = '22023', message = 'start time is not aligned to the organization slot interval';
  end if;
  v_occupied := ceil(v_version.bundle_session_duration_minutes::numeric / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes;
  v_period := tstzrange(p_starts_at, p_starts_at + make_interval(mins => v_occupied), '[)');
  v_resolved_environment_id := public.resolve_appointment_environment(
    p_organization_id, p_barber_id, v_barber.location_id, v_period, p_environment_id
  );
  if public.organization_date_blocked(p_organization_id, v_period)
     or not public.is_barber_available(p_organization_id, p_barber_id, v_period)
     or v_resolved_environment_id is null
     or exists (select 1 from public.appointments appointment
       where appointment.organization_id = p_organization_id and appointment.customer_id = p_customer_id
         and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
         and appointment.service_period && v_period) then
    raise exception using errcode = '23P01', message = 'requested subscription time is no longer available';
  end if;
  select session_number into strict v_session_number from public.subscription_bundle_sessions
   where id = p_session_id and organization_id = p_organization_id and subscription_id = p_subscription_id
   for update;
  perform set_config('app.agenda_environment_id', v_resolved_environment_id::text, true);
  insert into public.appointments(
    organization_id, location_id, customer_id, barber_id, status, source, service_period,
    payment_mode, currency, total_cents_snapshot, list_total_cents_snapshot,
    deposit_bps_snapshot, deposit_required_cents_snapshot, cancellation_lead_minutes_snapshot,
    notes, created_by, subscription_bundle_session_id
  ) values (
    p_organization_id, v_barber.location_id, p_customer_id, p_barber_id, 'CONFIRMED', p_source,
    v_period, 'SUBSCRIPTION', v_org.currency, 0, 0, v_org.deposit_bps, 0,
    v_org.cancellation_lead_minutes,
    'Sessão de plano de assinatura · nº ' || v_session_number,
    p_actor_id, p_session_id
  ) returning id into v_appointment_id;
  insert into public.appointment_items(
    organization_id, appointment_id, selection_key, source, service_id, service_name_snapshot,
    quantity, charged_price_cents_snapshot, list_price_cents_snapshot,
    duration_minutes_snapshot, commission_mode_snapshot, commission_fixed_cents_snapshot, position
  ) values (
    p_organization_id, v_appointment_id, v_service.id, 'SERVICE', v_service.id,
    v_service.name, 1, 0, v_service.price_cents,
    v_version.bundle_session_duration_minutes, 'FIXED', 0, 0
  );
  update public.subscription_bundle_sessions
     set appointment_id = v_appointment_id, barber_id = p_barber_id,
         environment_id = v_resolved_environment_id, scheduled_for = p_starts_at, status = 'SCHEDULED',
         commission_mode = v_commission_mode,
         commission_percentage_bps = v_commission_percentage_bps,
         commission_fixed_cents = v_commission_fixed_cents
   where id = p_session_id and organization_id = p_organization_id;
  insert into public.appointment_status_events(
    organization_id, appointment_id, to_status, reason, actor_user_id, metadata
  ) values (
    p_organization_id, v_appointment_id, 'CONFIRMED', 'subscription_bundle_session_booking', p_actor_id,
    jsonb_build_object('subscription_id', p_subscription_id, 'subscription_bundle_session_id', p_session_id)
  );
  return v_appointment_id;
end;
$$;
revoke all on function public.create_subscription_bundle_appointment(uuid,uuid,uuid,uuid,uuid,uuid,timestamptz,uuid,public.booking_source)
  from public, anon, authenticated, service_role;

create or replace function public.prevent_new_customer_subscription_enrollment()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_model text;
begin
  select version.model into v_model from public.subscription_plan_versions version
   join public.subscription_plans plan on plan.id = version.plan_id and plan.organization_id = version.organization_id
   where version.id = new.plan_version_id and version.organization_id = new.organization_id
     and plan.id = new.plan_id and plan.active and plan.archived_at is null;
  if v_model = 'SESSION_BUNDLE_V1'
     and current_setting('app.subscription_bundle_offer', true) = '1'
     and public.organization_module_enabled(new.organization_id, 'subscription_plans') then
    return new;
  end if;
  raise exception using errcode = '55000', message = 'subscription_enrollments_paused',
    detail = 'Only configured session bundle offers can be created.';
end;
$$;
revoke all on function public.prevent_new_customer_subscription_enrollment() from public, anon, authenticated, service_role;

drop trigger if exists customer_subscriptions_pause_new_enrollments on public.customer_subscriptions;
create trigger customer_subscriptions_pause_new_enrollments
  before insert on public.customer_subscriptions
  for each row execute function public.prevent_new_customer_subscription_enrollment();

create or replace function public.prevent_legacy_activation_for_bundle()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_model text;
begin
  if new.status = 'ACTIVE' and old.status is distinct from new.status then
    select model into v_model from public.subscription_plan_versions
     where id = new.plan_version_id and organization_id = new.organization_id;
    if v_model = 'SESSION_BUNDLE_V1'
       and current_setting('app.subscription_bundle_accept', true) is distinct from '1' then
      raise exception using errcode = '55000', message = 'bundle offers activate only when accepted by the customer';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.prevent_legacy_activation_for_bundle() from public, anon, authenticated, service_role;
drop trigger if exists customer_subscription_v2_activation_guard on public.customer_subscriptions;
create trigger customer_subscription_v2_activation_guard
  before update of status on public.customer_subscriptions
  for each row execute function public.prevent_legacy_activation_for_bundle();

-- Preserve the legacy subscription booking path while reading scheduling data
-- from the version that owns it (subscription_plans has no scheduling_mode).
create or replace function public.book_subscription_session_guarded(
  p_organization_id uuid, p_customer_id uuid, p_subscription_session_id uuid,
  p_barber_id uuid, p_starts_at timestamptz, p_overdue_reason text default null
) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_subscription_id uuid;
  v_plan_id uuid;
  v_scheduling_mode text;
  v_previous_status public.subscription_session_status;
  v_overdue boolean;
  v_today date;
begin
  select session.subscription_id, subscription.plan_id, version.scheduling_mode
    into strict v_subscription_id, v_plan_id, v_scheduling_mode
  from public.customer_subscription_sessions session
  join public.customer_subscriptions subscription
    on subscription.id = session.subscription_id and subscription.organization_id = session.organization_id
  join public.subscription_plan_versions version
    on version.id = subscription.plan_version_id and version.organization_id = subscription.organization_id
  join public.subscription_plans plan
    on plan.id = version.plan_id and plan.organization_id = version.organization_id
  where session.id = p_subscription_session_id and session.organization_id = p_organization_id
    and subscription.customer_id = p_customer_id
  for update of session, subscription;

  if not exists (
    select 1 from public.barber_subscription_plans assignment
    where assignment.organization_id = p_organization_id and assignment.barber_id = p_barber_id
      and assignment.plan_id = v_plan_id and assignment.active
  ) then
    raise exception using errcode = '22023', message = 'professional is not configured for this subscription plan';
  end if;

  select (now() at time zone organization.timezone)::date into v_today
  from public.organizations organization where organization.id = p_organization_id;
  select exists (
    select 1 from public.customer_subscription_cycles cycle
    join public.customer_subscriptions subscription
      on subscription.id = cycle.subscription_id and subscription.organization_id = cycle.organization_id
    where subscription.organization_id = p_organization_id and subscription.customer_id = p_customer_id
      and cycle.due_on < v_today and cycle.status in ('OPEN', 'OVERDUE')
  ) into v_overdue;

  if v_overdue then
    if p_overdue_reason is null then
      raise exception using errcode = '22023', message = 'subscription_overdue_installment';
    end if;
    if not public.is_organization_owner(p_organization_id) then
      raise exception using errcode = '42501', message = 'manager overdue override required';
    end if;
    if char_length(btrim(p_overdue_reason)) not between 5 and 1000 then
      raise exception using errcode = '22023', message = 'overdue override reason required';
    end if;
  end if;

  if v_scheduling_mode = 'FREE' then
    select previous.status into v_previous_status from (
      select session.id, lag(session.status) over (order by cycle.cycle_number, session.session_number) as status
      from public.customer_subscription_sessions session
      join public.customer_subscription_cycles cycle
        on cycle.id = session.cycle_id and cycle.organization_id = session.organization_id
      where session.organization_id = p_organization_id and session.subscription_id = v_subscription_id
    ) previous where previous.id = p_subscription_session_id;
    if v_previous_status is not null and v_previous_status not in ('COMPLETED', 'CONSUMED') then
      raise exception using errcode = '22023', message = 'previous_subscription_session_not_finished';
    end if;
  end if;

  if v_overdue then
    insert into public.subscription_overdue_booking_overrides(
      organization_id, customer_id, subscription_session_id, actor_user_id, reason
    ) values (p_organization_id, p_customer_id, p_subscription_session_id, auth.uid(), btrim(p_overdue_reason));
  end if;
  return public.book_customer_subscription_session_before_catalog_commissions(
    p_organization_id, p_customer_id, p_subscription_session_id, p_barber_id, p_starts_at
  );
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription session not found';
end;
$$;
revoke all on function public.book_subscription_session_guarded(uuid,uuid,uuid,uuid,timestamptz,text)
  from public, anon, authenticated, service_role;

create or replace function public.ensure_subscription_bundle_session_commission(p_session_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_session public.subscription_bundle_sessions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_installment public.subscription_bundle_installments%rowtype;
  v_appointment public.appointments%rowtype;
  v_amount bigint;
begin
  select * into v_session from public.subscription_bundle_sessions
   where id = p_session_id for update;
  if v_session.id is null or v_session.status <> 'COMPLETED'
     or v_session.appointment_id is null or v_session.commission_mode is null then return; end if;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_session.subscription_id and organization_id = v_session.organization_id;
  select * into strict v_installment from public.subscription_bundle_installments
   where subscription_id = v_session.subscription_id and organization_id = v_session.organization_id
     and installment_number = v_session.installment_number;
  if v_installment.status <> 'PAID' then return; end if;
  select * into strict v_appointment from public.appointments
   where id = v_session.appointment_id and organization_id = v_session.organization_id;
  if v_appointment.status <> 'COMPLETED' then return; end if;
  v_amount := case v_session.commission_mode
    when 'PERCENT' then round(v_contract.price_per_session_cents::numeric * v_session.commission_percentage_bps / 10000)::bigint
    when 'FIXED' then v_session.commission_fixed_cents
    else 0 end;
  if v_amount <= 0 then return; end if;
  insert into public.commission_ledger(
    organization_id, barber_id, appointment_id, subscription_bundle_session_id,
    kind, amount_cents, idempotency_key, earned_at, created_by
  ) values (
    v_session.organization_id, v_appointment.barber_id, v_appointment.id,
    v_session.id, 'EARNED', v_amount,
    'subscription-bundle-session-earned:' || v_session.id, now(), auth.uid()
  ) on conflict (organization_id, idempotency_key) do nothing;
exception when no_data_found then return;
end;
$$;
revoke all on function public.ensure_subscription_bundle_session_commission(uuid)
  from public, anon, authenticated, service_role;

create or replace function public.subscription_bundle_session_appointment_sync()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.subscription_bundle_session_id is null then return new; end if;
  if new.status = 'COMPLETED' then
    update public.subscription_bundle_sessions
       set status = 'COMPLETED', completed_at = coalesce(completed_at, now()),
           scheduled_for = lower(new.service_period)
     where id = new.subscription_bundle_session_id and organization_id = new.organization_id;
  elsif new.status = 'CANCELED' then
    update public.subscription_bundle_sessions session
       set status = case
             when coalesce(new.cancellation_outcome::text, 'AFTER_DEADLINE') = 'ON_TIME'
               then 'AVAILABLE'
             else 'CONSUMED' end,
           appointment_id = case when coalesce(new.cancellation_outcome::text, 'AFTER_DEADLINE') = 'ON_TIME' then null else appointment_id end,
           scheduled_for = case when coalesce(new.cancellation_outcome::text, 'AFTER_DEADLINE') = 'ON_TIME' then null else scheduled_for end,
           barber_id = case when coalesce(new.cancellation_outcome::text, 'AFTER_DEADLINE') = 'ON_TIME' then null else barber_id end,
           environment_id = case when coalesce(new.cancellation_outcome::text, 'AFTER_DEADLINE') = 'ON_TIME' then null else environment_id end,
           canceled_at = now()
     where id = new.subscription_bundle_session_id and organization_id = new.organization_id
       and session.status <> 'COMPLETED';
  elsif new.status in ('CONFIRMED', 'HELD', 'PENDING_PAYMENT') then
    update public.subscription_bundle_sessions
       set status = 'SCHEDULED', scheduled_for = lower(new.service_period)
     where id = new.subscription_bundle_session_id and organization_id = new.organization_id
       and status not in ('COMPLETED', 'CONSUMED');
  end if;
  return new;
end;
$$;
revoke all on function public.subscription_bundle_session_appointment_sync() from public, anon, authenticated, service_role;
drop trigger if exists subscription_bundle_session_appointment_sync on public.appointments;
create trigger subscription_bundle_session_appointment_sync
  after update of status, service_period, cancellation_outcome on public.appointments
  for each row execute function public.subscription_bundle_session_appointment_sync();

create or replace function public.subscription_bundle_session_commission_after_completion()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'COMPLETED' and old.status is distinct from new.status then
    perform public.ensure_subscription_bundle_session_commission(new.id);
  end if;
  return new;
end;
$$;
revoke all on function public.subscription_bundle_session_commission_after_completion() from public, anon, authenticated, service_role;
create trigger subscription_bundle_session_commission_after_completion
  after update on public.subscription_bundle_sessions
  for each row execute function public.subscription_bundle_session_commission_after_completion();

create or replace function public.subscription_bundle_installment_commission_after_payment()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_session record;
begin
  if new.status = 'PAID' and old.status is distinct from new.status then
    for v_session in select id from public.subscription_bundle_sessions
      where organization_id = new.organization_id and subscription_id = new.subscription_id
        and installment_number = new.installment_number and status = 'COMPLETED'
    loop perform public.ensure_subscription_bundle_session_commission(v_session.id); end loop;
  end if;
  return new;
end;
$$;
revoke all on function public.subscription_bundle_installment_commission_after_payment() from public, anon, authenticated, service_role;
create trigger subscription_bundle_installment_commission_after_payment
  after update on public.subscription_bundle_installments
  for each row execute function public.subscription_bundle_installment_commission_after_payment();

alter function public.accept_customer_subscription_offer(uuid, uuid)
  rename to accept_customer_subscription_offer_before_bundle_v2;
revoke all on function public.accept_customer_subscription_offer_before_bundle_v2(uuid, uuid)
  from public, anon, authenticated;

create or replace function public.accept_customer_subscription_offer(
  p_organization_id uuid, p_subscription_id uuid
)
returns public.customer_subscriptions
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_entry public.subscription_bundle_installments%rowtype;
  v_contract_version text;
  v_discount bigint;
  v_base bigint;
  v_due_date date;
  v_due_month date;
  v_today date;
  v_installment smallint;
  v_session_number integer := 0;
  v_month date;
  v_month_capacity integer;
  v_remaining integer;
  v_session_offset integer;
  v_slot public.subscription_bundle_fixed_slots%rowtype;
  v_candidate record;
  v_local_date date;
  v_local_start timestamp;
  v_starts_at timestamptz;
  v_period tstzrange;
  v_occupied integer;
  v_org public.organizations%rowtype;
  v_version_end date;
begin
  select * into strict v_sub from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id for update;
  if not public.is_organization_customer(p_organization_id, v_sub.customer_id) then
    raise exception using errcode = '42501', message = 'subscription offer acceptance denied';
  end if;
  select * into strict v_version from public.subscription_plan_versions
   where id = v_sub.plan_version_id and organization_id = p_organization_id;
  if v_version.model <> 'SESSION_BUNDLE_V1' then
    return public.accept_customer_subscription_offer_before_bundle_v2(p_organization_id, p_subscription_id);
  end if;
  if v_sub.status = 'ACTIVE' and v_sub.contract_accepted_at is not null then return v_sub; end if;
  if v_sub.status <> 'REQUESTED' or v_sub.contract_accepted_at is not null then
    raise exception using errcode = '22023', message = 'subscription bundle offer is not awaiting acceptance';
  end if;
  if not public.organization_module_enabled(p_organization_id, 'subscription_plans') then
    raise exception using errcode = '42501', message = 'subscription module disabled';
  end if;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_sub.id and organization_id = p_organization_id for update;
  select * into strict v_org from public.organizations where id = p_organization_id;
  v_today := (now() at time zone v_org.timezone)::date;
  if v_contract.first_session_date < v_today or v_contract.entry_due_on < v_today then
    raise exception using errcode = '22023', message = 'subscription offer dates have expired; ask the manager to update the offer';
  end if;

  perform set_config('app.subscription_bundle_accept', '1', true);
  update public.customer_subscriptions
     set status = 'ACTIVE', contract_accepted_at = now(), contract_accepted_by = auth.uid(),
         start_date = v_contract.first_session_date, end_date = v_contract.first_session_date,
         first_due_date = v_contract.first_installment_due_on,
         due_day = extract(day from v_contract.first_installment_due_on)::smallint, updated_at = now()
   where id = v_sub.id and organization_id = p_organization_id returning * into v_sub;
  update public.subscription_bundle_contracts set accepted_at = now()
   where id = v_contract.id and organization_id = p_organization_id returning * into v_contract;
  insert into public.subscription_contract_acceptances(
    organization_id, subscription_id, contract_version, accepted_by, acceptance_source, metadata
  ) values (
    p_organization_id, v_sub.id, v_sub.contract_version, auth.uid(), 'CLIENT',
    jsonb_build_object('model', 'SESSION_BUNDLE_V1', 'accepted_at', now())
  ) on conflict (subscription_id, contract_version) do nothing;
  update public.customer_in_app_notifications set read_at = coalesce(read_at, now())
   where organization_id = p_organization_id and customer_id = v_sub.customer_id and subscription_id = v_sub.id;

  if v_contract.entry_cents > 0 then
    insert into public.subscription_bundle_installments(
      organization_id, subscription_id, installment_number, kind, due_on, amount_cents, payment_method
    ) values (p_organization_id, v_sub.id, 0, 'ENTRY', v_contract.entry_due_on,
      v_contract.entry_cents, v_sub.payment_method);
  end if;
  for v_installment in 1..v_contract.installment_count loop
    v_base := floor(v_contract.total_price_cents::numeric / v_contract.installment_count)::bigint;
    if v_installment = v_contract.installment_count then
      v_base := v_contract.total_price_cents - (v_base * (v_contract.installment_count - 1));
    end if;
    v_discount := case v_contract.discount_type
      when 'FIXED' then v_contract.discount_value
      when 'PERCENT' then round(v_base::numeric * v_contract.discount_value / 10000)::bigint
      else 0 end;
    if v_discount >= v_base then
      raise exception using errcode = '22023', message = 'installment discount results in a zero or negative amount';
    end if;
    v_due_month := (date_trunc('month', v_contract.first_installment_due_on::timestamp)
      + make_interval(months => v_installment - 1))::date;
    v_due_date := make_date(extract(year from v_due_month)::integer, extract(month from v_due_month)::integer,
      least(extract(day from v_contract.first_installment_due_on)::integer,
        extract(day from (v_due_month + interval '1 month - 1 day'))::integer));
    insert into public.subscription_bundle_installments(
      organization_id, subscription_id, installment_number, kind, due_on, amount_cents, payment_method
    ) values (p_organization_id, v_sub.id, v_installment, 'INSTALLMENT', v_due_date,
      v_base - v_discount, v_sub.payment_method);
  end loop;

  if v_contract.scheduling_mode = 'FREE' then
    v_month := date_trunc('month', v_contract.first_session_date::timestamp)::date;
    v_remaining := v_contract.total_sessions;
    while v_remaining > 0 loop
      v_month_capacity := greatest(public.subscription_bundle_weeks_in_month(v_month), 1) * v_contract.sessions_per_week;
      for v_session_offset in 1..least(v_remaining, v_month_capacity) loop
        v_session_number := v_session_number + 1;
        v_installment := least(v_contract.installment_count,
          greatest(1, ((extract(year from v_month) - extract(year from date_trunc('month', v_contract.first_session_date::timestamp)::date))::integer * 12
            + extract(month from v_month) - extract(month from date_trunc('month', v_contract.first_session_date::timestamp)::date) + 1))::smallint);
        insert into public.subscription_bundle_sessions(
          organization_id, subscription_id, session_number, release_on, installment_number
        ) values (p_organization_id, v_sub.id, v_session_number,
          v_month, v_installment);
      end loop;
      v_remaining := v_remaining - least(v_remaining, v_month_capacity);
      v_month := (v_month + interval '1 month')::date;
    end loop;
    v_version_end := (v_contract.first_session_date
      + make_interval(days => ceil(v_contract.total_sessions::numeric / v_contract.sessions_per_week)::integer * 7))::date;
  else
    insert into public.subscription_bundle_sessions(
      organization_id, subscription_id, session_number, release_on, installment_number
    )
    select p_organization_id, v_sub.id, n, v_contract.first_session_date, 1
      from generate_series(1, v_contract.total_sessions) n;
    v_occupied := ceil(v_contract.session_duration_minutes::numeric / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes;
    v_session_number := 0;
    for v_candidate in
      select dates.day_value::date as local_date, slot.*
        from generate_series(v_contract.first_session_date, v_contract.first_session_date + 4000, interval '1 day') dates(day_value)
        join public.subscription_bundle_fixed_slots slot on slot.organization_id = p_organization_id
         and slot.subscription_id = v_sub.id
         and slot.weekday = extract(dow from dates.day_value)::smallint
       order by dates.day_value::date, slot.local_time, slot.slot_number
    loop
      exit when v_session_number >= v_contract.total_sessions;
      v_local_date := v_candidate.local_date::date;
      v_local_start := v_local_date + v_candidate.local_time;
      v_starts_at := v_local_start at time zone v_org.timezone;
      v_period := tstzrange(v_starts_at, v_starts_at + make_interval(mins => v_occupied), '[)');
      if public.organization_date_blocked(p_organization_id, v_period) then continue; end if;
      v_session_number := v_session_number + 1;
      v_installment := least(v_contract.installment_count,
        greatest(1, ((extract(year from v_local_date) - extract(year from v_contract.first_session_date))::integer * 12
          + extract(month from v_local_date) - extract(month from v_contract.first_session_date) + 1))::smallint);
      update public.subscription_bundle_sessions
         set release_on = v_local_date, installment_number = v_installment,
             barber_id = v_candidate.barber_id, environment_id = v_candidate.environment_id
       where organization_id = p_organization_id and subscription_id = v_sub.id
         and session_number = v_session_number;
      perform public.create_subscription_bundle_appointment(
        p_organization_id, v_sub.customer_id, v_sub.id,
        (select id from public.subscription_bundle_sessions where organization_id = p_organization_id
           and subscription_id = v_sub.id and session_number = v_session_number),
        v_candidate.barber_id, v_candidate.environment_id, v_starts_at, auth.uid(), 'MANAGER'
      );
      v_version_end := v_local_date;
    end loop;
    if v_session_number < v_contract.total_sessions then
      raise exception using errcode = '22023', message = 'fixed schedule could not generate all subscription sessions';
    end if;
  end if;
  update public.customer_subscriptions set end_date = v_version_end, updated_at = now()
   where id = v_sub.id and organization_id = p_organization_id returning * into v_sub;
  insert into public.subscription_events(
    organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata
  ) values (
    p_organization_id, v_sub.id, 'BUNDLE_ACCEPTED', auth.uid(),
    'bundle-accepted:' || v_sub.id, jsonb_build_object('model', 'SESSION_BUNDLE_V1')
  ) on conflict (organization_id, idempotency_key) do nothing;
  return v_sub;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle offer not found';
end;
$$;
revoke all on function public.accept_customer_subscription_offer(uuid, uuid) from public, anon;
grant execute on function public.accept_customer_subscription_offer(uuid, uuid) to authenticated;

create or replace function public.get_customer_subscription_bundle_booking_context(
  p_organization_id uuid, p_customer_id uuid, p_session_id uuid
)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_session public.subscription_bundle_sessions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_service public.services%rowtype;
  v_today date;
  v_services jsonb;
  v_barbers jsonb;
begin
  if auth.uid() is null or not public.is_organization_customer(p_organization_id, p_customer_id, auth.uid()) then
    raise exception using errcode = '42501', message = 'customer booking denied';
  end if;
  select * into strict v_session from public.subscription_bundle_sessions
   where id = p_session_id and organization_id = p_organization_id;
  select * into strict v_sub from public.customer_subscriptions
   where id = v_session.subscription_id and organization_id = p_organization_id;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_sub.id and organization_id = p_organization_id;
  select * into strict v_version from public.subscription_plan_versions
   where id = v_sub.plan_version_id and organization_id = p_organization_id;
  select (now() at time zone org.timezone)::date into strict v_today
    from public.organizations org where org.id = p_organization_id;
  if v_sub.customer_id <> p_customer_id or v_sub.status <> 'ACTIVE'
     or v_contract.scheduling_mode <> 'FREE' or v_session.status <> 'AVAILABLE'
     or v_session.release_on > v_today or v_contract.first_session_date > v_today
     or exists (select 1 from public.subscription_bundle_installments installment
       where installment.organization_id = p_organization_id and installment.subscription_id = v_sub.id
         and installment.due_on < v_today and installment.status in ('OPEN', 'OVERDUE'))
     then
    raise exception using errcode = '22023', message = 'subscription bundle session is unavailable or has overdue installments';
  end if;
  select * into strict v_service from public.services
   where id = v_contract.service_id and organization_id = p_organization_id and active;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', v_service.id, 'name', v_service.name, 'description', v_service.description,
    'price_cents', v_contract.price_per_session_cents,
    'duration_minutes', v_contract.session_duration_minutes
  )), '[]'::jsonb) into v_services;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', barber.id, 'name', barber.display_name, 'bio', barber.bio,
    'avatar_url', barber.avatar_url, 'service_ids', jsonb_build_array(v_service.id),
    'subscription_plan_ids', jsonb_build_array(v_sub.plan_id)
  ) order by barber.display_name), '[]'::jsonb) into v_barbers
  from public.barbers barber
  join public.barber_services barber_service on barber_service.organization_id = p_organization_id
    and barber_service.barber_id = barber.id and barber_service.service_id = v_service.id and barber_service.active
  join public.barber_subscription_plans assignment on assignment.organization_id = p_organization_id
    and assignment.barber_id = barber.id and assignment.plan_id = v_sub.plan_id and assignment.active
  where barber.organization_id = p_organization_id and barber.active
    and exists (select 1 from public.commission_rules rule where rule.organization_id = p_organization_id
      and rule.barber_id = barber.id and rule.subscription_plan_id = v_sub.plan_id
      and rule.active and rule.effective_period @> now());
  if jsonb_array_length(v_barbers) = 0 then
    raise exception using errcode = '22023', message = 'no professional is configured for this subscription service and plan';
  end if;
  return jsonb_build_object('plan_id', v_sub.plan_id, 'services', v_services, 'barbers', v_barbers);
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle session not found';
end;
$$;
revoke all on function public.get_customer_subscription_bundle_booking_context(uuid,uuid,uuid) from public, anon;
grant execute on function public.get_customer_subscription_bundle_booking_context(uuid,uuid,uuid) to authenticated;

create or replace function public.get_customer_subscription_bundle_slots(
  p_organization_id uuid,
  p_customer_id uuid,
  p_session_id uuid,
  p_barber_id uuid,
  p_local_date date
)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_org public.organizations%rowtype;
  v_sub public.customer_subscriptions%rowtype;
  v_session public.subscription_bundle_sessions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_barber public.barbers%rowtype;
  v_source record;
  v_local_start timestamp;
  v_start timestamptz;
  v_period tstzrange;
  v_occupied integer;
  v_slots jsonb := '[]'::jsonb;
  v_seen_starts timestamptz[] := array[]::timestamptz[];
  v_today date;
begin
  if auth.uid() is null or not public.is_organization_customer(p_organization_id, p_customer_id, auth.uid()) then
    raise exception using errcode = '42501', message = 'customer booking denied';
  end if;
  select * into strict v_org from public.organizations where id = p_organization_id;
  select * into strict v_session from public.subscription_bundle_sessions
   where id = p_session_id and organization_id = p_organization_id;
  select * into strict v_sub from public.customer_subscriptions
   where id = v_session.subscription_id and organization_id = p_organization_id;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_sub.id and organization_id = p_organization_id;
  select * into strict v_version from public.subscription_plan_versions
   where id = v_sub.plan_version_id and organization_id = p_organization_id;
  select * into strict v_barber from public.barbers
   where id = p_barber_id and organization_id = p_organization_id and active;
  v_today := (now() at time zone v_org.timezone)::date;
  if v_sub.customer_id <> p_customer_id or v_sub.status <> 'ACTIVE'
     or v_contract.scheduling_mode <> 'FREE' or v_session.status <> 'AVAILABLE'
     or v_session.release_on > v_today or v_contract.first_session_date > v_today
     or exists (select 1 from public.subscription_bundle_installments installment
       where installment.organization_id = p_organization_id and installment.subscription_id = v_sub.id
         and installment.due_on < v_today and installment.status in ('OPEN', 'OVERDUE'))
     or date_trunc('month', p_local_date::timestamp)::date <> date_trunc('month', v_today::timestamp)::date
     or p_local_date < v_today
     or p_local_date < v_contract.first_session_date
     or not public.organization_accepts_new_bookings(p_organization_id) then
    raise exception using errcode = '22023', message = 'subscription bundle booking date is not available';
  end if;
  if not exists (select 1 from public.barber_services bs where bs.organization_id = p_organization_id
      and bs.barber_id = p_barber_id and bs.service_id = v_contract.service_id and bs.active)
     or not exists (select 1 from public.barber_subscription_plans bp where bp.organization_id = p_organization_id
      and bp.barber_id = p_barber_id and bp.plan_id = v_sub.plan_id and bp.active)
     or not exists (select 1 from public.commission_rules cr where cr.organization_id = p_organization_id
      and cr.barber_id = p_barber_id and cr.subscription_plan_id = v_sub.plan_id
      and cr.active and cr.effective_period @> now()) then
    raise exception using errcode = '22023', message = 'professional is not configured for this subscription';
  end if;
  v_occupied := ceil(v_contract.session_duration_minutes::numeric / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes;
  for v_source in
    select sources.local_start, sources.local_limit
      from (
        select p_local_date + interval_data.starts_at as local_start,
               p_local_date + interval_data.ends_at as local_limit
          from public.work_intervals interval_data
         where interval_data.organization_id = p_organization_id and interval_data.barber_id = p_barber_id
           and interval_data.active and interval_data.weekday = extract(dow from p_local_date)::smallint
        union all
        select timezone(v_org.timezone,
                 greatest(lower(exception.service_period), p_local_date::timestamp at time zone v_org.timezone)) as local_start,
               timezone(v_org.timezone,
                 least(upper(exception.service_period), (p_local_date + 1)::timestamp at time zone v_org.timezone)) as local_limit
          from public.availability_exceptions exception
         where exception.organization_id = p_organization_id and exception.barber_id = p_barber_id
           and exception.kind = 'AVAILABLE_OVERRIDE'
           and exception.service_period && tstzrange(p_local_date::timestamp at time zone v_org.timezone,
             (p_local_date + 1)::timestamp at time zone v_org.timezone, '[)')
      ) sources where sources.local_start < sources.local_limit
      order by sources.local_start, sources.local_limit
  loop
    v_local_start := date_trunc('day', v_source.local_start) + make_interval(mins =>
      ceil(extract(epoch from (v_source.local_start - date_trunc('day', v_source.local_start))) / 60 / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes);
    while v_local_start + make_interval(mins => v_occupied) <= v_source.local_limit loop
      v_start := v_local_start at time zone v_org.timezone;
      v_period := tstzrange(v_start, v_start + make_interval(mins => v_occupied), '[)');
      if v_start > now() and not (v_start = any(v_seen_starts))
         and not public.organization_date_blocked(p_organization_id, v_period)
         and public.is_barber_available(p_organization_id, p_barber_id, v_period)
         and public.resolve_appointment_environment(p_organization_id, p_barber_id, v_barber.location_id, v_period, null) is not null
         and not exists (select 1 from public.appointments appointment where appointment.organization_id = p_organization_id
           and appointment.barber_id = p_barber_id and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
           and appointment.service_period && v_period) then
        v_slots := v_slots || jsonb_build_array(jsonb_build_object(
          'starts_at', v_start, 'ends_at', upper(v_period)
        ));
        v_seen_starts := array_append(v_seen_starts, v_start);
      end if;
      v_local_start := v_local_start + make_interval(mins => v_org.slot_interval_minutes);
    end loop;
  end loop;
  return jsonb_build_object('duration_minutes', v_contract.session_duration_minutes,
    'occupied_minutes', v_occupied, 'total_cents', 0, 'slots', v_slots);
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle session or professional not found';
end;
$$;
revoke all on function public.get_customer_subscription_bundle_slots(uuid,uuid,uuid,uuid,date) from public, anon;
grant execute on function public.get_customer_subscription_bundle_slots(uuid,uuid,uuid,uuid,date) to authenticated;

create or replace function public.book_customer_subscription_bundle_session(
  p_organization_id uuid,
  p_customer_id uuid,
  p_session_id uuid,
  p_barber_id uuid,
  p_starts_at timestamptz
)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_session public.subscription_bundle_sessions%rowtype;
  v_sub public.customer_subscriptions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_org public.organizations%rowtype;
  v_local_date date;
  v_week_start date;
  v_week_count integer;
  v_today date;
  v_appointment_id uuid;
begin
  if not public.is_organization_customer(p_organization_id, p_customer_id) then
    raise exception using errcode = '42501', message = 'customer booking denied';
  end if;
  select * into strict v_session from public.subscription_bundle_sessions
   where id = p_session_id and organization_id = p_organization_id for update;
  select * into strict v_sub from public.customer_subscriptions
   where id = v_session.subscription_id and organization_id = p_organization_id for update;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_sub.id and organization_id = p_organization_id;
  select * into strict v_org from public.organizations where id = p_organization_id;
  v_today := (now() at time zone v_org.timezone)::date;
  v_local_date := (p_starts_at at time zone v_org.timezone)::date;
  v_week_start := date_trunc('week', v_local_date::timestamp)::date;
  if v_sub.customer_id <> p_customer_id or v_sub.status <> 'ACTIVE'
     or v_contract.scheduling_mode <> 'FREE' or v_session.status <> 'AVAILABLE'
     or v_session.release_on > v_today or v_contract.first_session_date > v_today
     or date_trunc('month', v_local_date::timestamp)::date <> date_trunc('month', v_today::timestamp)::date
     or v_local_date < v_contract.first_session_date or p_starts_at <= now()
     or not public.organization_accepts_new_bookings(p_organization_id) then
    raise exception using errcode = '22023', message = 'subscription bundle session is not available this month';
  end if;
  if exists (select 1 from public.subscription_bundle_installments installment
      where installment.organization_id = p_organization_id and installment.subscription_id = v_sub.id
        and installment.due_on < v_today and installment.status in ('OPEN', 'OVERDUE')) then
    raise exception using errcode = '22023', message = 'subscription_overdue_installment';
  end if;
  select count(*) into v_week_count from public.subscription_bundle_sessions session
   where session.organization_id = p_organization_id and session.subscription_id = v_sub.id
     and session.status in ('SCHEDULED', 'COMPLETED') and session.scheduled_for is not null
     and (session.scheduled_for at time zone v_org.timezone)::date >= v_week_start
     and (session.scheduled_for at time zone v_org.timezone)::date < v_week_start + 7;
  if v_week_count >= v_contract.sessions_per_week then
    raise exception using errcode = '22023', message = 'subscription_weekly_booking_limit';
  end if;
  v_appointment_id := public.create_subscription_bundle_appointment(
    p_organization_id, p_customer_id, v_sub.id, v_session.id, p_barber_id,
    null, p_starts_at, auth.uid(), 'CUSTOMER'
  );
  return jsonb_build_object('appointment_id', v_appointment_id,
    'subscription_bundle_session_id', v_session.id, 'session_number', v_session.session_number);
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle session not found';
end;
$$;
revoke all on function public.book_customer_subscription_bundle_session(uuid,uuid,uuid,uuid,timestamptz) from public, anon;
grant execute on function public.book_customer_subscription_bundle_session(uuid,uuid,uuid,uuid,timestamptz) to authenticated;

create or replace function public.cancel_customer_subscription_bundle_session(
  p_organization_id uuid,
  p_customer_id uuid,
  p_session_id uuid,
  p_reason text default 'Cancelada pelo cliente'
)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_session public.subscription_bundle_sessions%rowtype;
  v_sub public.customer_subscriptions%rowtype;
  v_appointment public.appointments%rowtype;
begin
  if not public.is_organization_customer(p_organization_id, p_customer_id) then
    raise exception using errcode = '42501', message = 'session cancellation denied';
  end if;
  select * into strict v_session from public.subscription_bundle_sessions
   where id = p_session_id and organization_id = p_organization_id for update;
  select * into strict v_sub from public.customer_subscriptions
   where id = v_session.subscription_id and organization_id = p_organization_id for update;
  if v_sub.customer_id <> p_customer_id or v_sub.status <> 'ACTIVE'
     or v_session.status <> 'SCHEDULED' or v_session.appointment_id is null then
    raise exception using errcode = '22023', message = 'subscription bundle session is not scheduled';
  end if;
  select * into strict v_appointment from public.appointments
   where id = v_session.appointment_id and organization_id = p_organization_id for update;
  perform public.cancel_appointment(v_appointment.id, left(coalesce(p_reason, 'Cancelada pelo cliente'), 500), true);
  return jsonb_build_object('session_id', v_session.id,
    'status', (select session.status from public.subscription_bundle_sessions session where session.id = v_session.id));
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle session not found';
end;
$$;
revoke all on function public.cancel_customer_subscription_bundle_session(uuid,uuid,uuid,text) from public, anon;
grant execute on function public.cancel_customer_subscription_bundle_session(uuid,uuid,uuid,text) to authenticated;

create or replace function public.record_subscription_bundle_payment(
  p_organization_id uuid,
  p_installment_id uuid,
  p_amount_cents bigint,
  p_chart_account_id uuid,
  p_financial_account_id uuid default null,
  p_idempotency_key text default null,
  p_external_reference text default null,
  p_paid_on date default current_date
)
returns public.subscription_bundle_payments
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_installment public.subscription_bundle_installments%rowtype;
  v_sub public.customer_subscriptions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_payment public.subscription_bundle_payments%rowtype;
  v_entry uuid;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription bundle payment denied';
  end if;
  if char_length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 200 then
    raise exception using errcode = '22023', message = 'payment idempotency key is required';
  end if;
  select * into v_payment from public.subscription_bundle_payments
   where organization_id = p_organization_id and idempotency_key = p_idempotency_key;
  if v_payment.id is not null then
    if v_payment.installment_id = p_installment_id and v_payment.amount_cents = p_amount_cents then
      return v_payment;
    end if;
    raise exception using errcode = '23505', message = 'subscription bundle payment idempotency key was already used';
  end if;
  select * into strict v_installment from public.subscription_bundle_installments
   where id = p_installment_id and organization_id = p_organization_id for update;
  select * into strict v_sub from public.customer_subscriptions
   where id = v_installment.subscription_id and organization_id = p_organization_id for update;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_sub.id and organization_id = p_organization_id;
  if v_installment.status = 'PAID' then
    select * into strict v_payment from public.subscription_bundle_payments
     where installment_id = v_installment.id and organization_id = p_organization_id;
    return v_payment;
  end if;
  if v_sub.status not in ('ACTIVE', 'CANCELED', 'EXPIRED')
     or p_amount_cents <> v_installment.amount_cents or p_amount_cents <= 0 then
    raise exception using errcode = '22023', message = 'subscription bundle payment amount or status is invalid';
  end if;
  if not exists (select 1 from public.chart_of_accounts account where account.id = p_chart_account_id
      and account.organization_id = p_organization_id and account.active and account.kind = 'REVENUE')
     or (p_financial_account_id is not null and not exists (
       select 1 from public.financial_accounts account where account.id = p_financial_account_id
         and account.organization_id = p_organization_id and account.active
     )) then
    raise exception using errcode = '22023', message = 'subscription bundle payment account is inactive';
  end if;
  insert into public.financial_entries(
    organization_id, kind, source, description, issue_date, competence_date, due_date,
    total_cents, currency, chart_account_id, preferred_financial_account_id,
    counterparty_kind, customer_id, subscription_bundle_installment_id, created_by
  ) values (
    p_organization_id, 'REVENUE', 'SUBSCRIPTION',
    case when v_installment.kind = 'ENTRY' then 'Entrada do plano de assinatura · ' || v_sub.id
      else 'Parcela ' || v_installment.installment_number || ' do plano de assinatura · ' || v_sub.id end,
    coalesce(p_paid_on, current_date), coalesce(p_paid_on, current_date), v_installment.due_on,
    v_installment.amount_cents, 'BRL', p_chart_account_id, p_financial_account_id,
    'CUSTOMER', v_sub.customer_id, v_installment.id, auth.uid()
  ) returning id into v_entry;
  insert into public.subscription_bundle_payments(
    organization_id, subscription_id, installment_id, amount_cents, method,
    financial_entry_id, idempotency_key, external_reference, paid_at, created_by
  ) values (
    p_organization_id, v_sub.id, v_installment.id, v_installment.amount_cents,
    v_installment.payment_method, v_entry, btrim(p_idempotency_key),
    nullif(btrim(coalesce(p_external_reference, '')), ''),
    (coalesce(p_paid_on, current_date)::timestamp at time zone (select timezone from public.organizations where id = p_organization_id)),
    auth.uid()
  ) returning * into v_payment;
  update public.subscription_bundle_installments
     set status = 'PAID', paid_at = v_payment.paid_at, financial_entry_id = v_entry
   where id = v_installment.id and organization_id = p_organization_id;
  return v_payment;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle installment or account not found';
end;
$$;
revoke all on function public.record_subscription_bundle_payment(uuid,uuid,bigint,uuid,uuid,text,text,date) from public, anon;
grant execute on function public.record_subscription_bundle_payment(uuid,uuid,bigint,uuid,uuid,text,text,date) to authenticated;

create or replace function public.pay_commission(
  p_organization_id uuid, p_barber_id uuid, p_period_start date, p_period_end date,
  p_appointment_item_ids uuid[], p_launch_on date, p_due_on date, p_financial_account_id uuid,
  p_payment_method public.financial_payment_method, p_document_number text, p_tags text,
  p_reference text, p_idempotency_key text
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_payout public.commission_payouts%rowtype;
  v_settlement_id uuid;
  v_ledger public.commission_ledger%rowtype;
  v_selected_ids uuid[];
  v_selected_count integer;
  v_amount bigint := 0;
begin
  perform public.require_financial_owner(p_organization_id, 'commission payout');
  if p_period_start > p_period_end or p_launch_on is null or p_due_on is null
     or nullif(btrim(p_document_number), '') is null or nullif(btrim(p_idempotency_key), '') is null then
    raise exception using errcode = '22023', message = 'valid period, dates, document number and idempotency key are required';
  end if;
  select array_agg(distinct selected_id order by selected_id) into v_selected_ids
    from unnest(coalesce(p_appointment_item_ids, '{}'::uuid[])) selected_id where selected_id is not null;
  if coalesce(cardinality(v_selected_ids), 0) = 0 then
    raise exception using errcode = '22023', message = 'at least one commission must be selected';
  end if;
  perform 1 from public.barbers where organization_id = p_organization_id and id = p_barber_id and active for update;
  if not found then raise exception using errcode = 'P0002', message = 'active barber not found'; end if;
  if not exists (select 1 from public.financial_accounts
      where organization_id = p_organization_id and id = p_financial_account_id and active) then
    raise exception using errcode = '22023', message = 'active financial account is required';
  end if;
  select settlement.id into v_settlement_id from public.commission_payout_settlements settlement
   where settlement.organization_id = p_organization_id and settlement.idempotency_key = p_idempotency_key;
  if v_settlement_id is not null then return v_settlement_id; end if;
  select count(*)::integer into v_selected_count from public.commission_service_details detail
   where detail.organization_id = p_organization_id and detail.barber_id = p_barber_id
     and detail.service_date between p_period_start and p_period_end
     and coalesce(detail.appointment_item_id, detail.internal_service_id) = any(v_selected_ids)
     and detail.payable_commission_cents > 0;
  if v_selected_count <> cardinality(v_selected_ids) then
    raise exception using errcode = '22023', message = 'selected commission is not open in the requested period';
  end if;
  if exists (
    select 1 from public.commission_payout_items payout_item
    join public.commission_payouts payout on payout.organization_id = payout_item.organization_id
      and payout.id = payout_item.payout_id and payout.status = 'OPEN'
    join public.commission_ledger ledger on ledger.organization_id = payout_item.organization_id
      and ledger.id = payout_item.ledger_entry_id
    where payout_item.organization_id = p_organization_id and payout.barber_id = p_barber_id
      and coalesce(ledger.appointment_item_id, ledger.project_internal_service_id,
        ledger.subscription_session_id, ledger.subscription_bundle_session_id) = any(v_selected_ids)
  ) then
    raise exception using errcode = '22023', message = 'selected commission is already reserved for payment';
  end if;
  insert into public.commission_payouts(organization_id, barber_id, period_start, period_end, amount_cents)
    values (p_organization_id, p_barber_id, p_period_start, p_period_end, 0) returning * into v_payout;
  for v_ledger in
    select ledger.* from public.commission_ledger ledger
    join public.commission_service_details detail on detail.organization_id = ledger.organization_id and (
      (ledger.project_internal_service_id is not null and detail.internal_service_id = ledger.project_internal_service_id)
      or (ledger.subscription_session_id is not null and detail.source_type = 'SUBSCRIPTION_SESSION'
        and detail.internal_service_id = ledger.subscription_session_id)
      or (ledger.subscription_bundle_session_id is not null and detail.source_type = 'SUBSCRIPTION_BUNDLE_SESSION'
        and detail.internal_service_id = ledger.subscription_bundle_session_id)
      or (ledger.project_internal_service_id is null and ledger.subscription_session_id is null
        and ledger.subscription_bundle_session_id is null and detail.appointment_id = ledger.appointment_id
        and detail.appointment_item_id = ledger.appointment_item_id)
    )
    where ledger.organization_id = p_organization_id and ledger.barber_id = p_barber_id
      and coalesce(ledger.appointment_item_id, ledger.project_internal_service_id,
        ledger.subscription_session_id, ledger.subscription_bundle_session_id) = any(v_selected_ids)
      and detail.service_date between p_period_start and p_period_end
    order by coalesce(ledger.appointment_item_id, ledger.project_internal_service_id,
      ledger.subscription_session_id, ledger.subscription_bundle_session_id), ledger.created_at, ledger.id
    for update of ledger
  loop
    insert into public.commission_payout_items(organization_id, payout_id, ledger_entry_id)
      values (p_organization_id, v_payout.id, v_ledger.id);
    v_amount := v_amount + v_ledger.amount_cents;
  end loop;
  if v_amount <= 0 then raise exception using errcode = '22023', message = 'no positive unpaid commission in selection'; end if;
  update public.commission_payouts set amount_cents = v_amount
   where organization_id = p_organization_id and id = v_payout.id;
  insert into public.commission_payout_settlements(
    organization_id, payout_id, financial_account_id, amount_cents, paid_on, launch_on, due_on,
    document_number, tags, payment_method, reference, idempotency_key, created_by
  ) values (
    p_organization_id, v_payout.id, p_financial_account_id, v_amount, current_date,
    p_launch_on, p_due_on, nullif(btrim(p_document_number), ''), nullif(btrim(p_tags), ''),
    p_payment_method, nullif(btrim(p_reference), ''), p_idempotency_key, auth.uid()
  ) returning id into v_settlement_id;
  update public.commission_payouts set status = 'PAID', paid_at = now(), marked_paid_by = auth.uid()
   where organization_id = p_organization_id and id = v_payout.id;
  return v_settlement_id;
exception when unique_violation then
  select settlement.id into v_settlement_id from public.commission_payout_settlements settlement
   where settlement.organization_id = p_organization_id and settlement.idempotency_key = p_idempotency_key;
  if v_settlement_id is not null then return v_settlement_id; end if;
  raise;
end;
$$;
revoke all on function public.pay_commission(uuid,uuid,date,date,uuid[],date,date,uuid,public.financial_payment_method,text,text,text,text)
  from public, anon, authenticated, service_role;
grant execute on function public.pay_commission(uuid,uuid,date,date,uuid[],date,date,uuid,public.financial_payment_method,text,text,text,text)
  to authenticated;

create or replace function public.pause_subscription_whatsapp_job_insert()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status in ('PENDING', 'RETRY') and (
    new.payload ->> 'message_kind' = 'SUBSCRIPTION_CREATED_CLIENT'
    or new.payload ->> 'payment_mode' = 'SUBSCRIPTION'
    or (new.appointment_id is not null and exists (
      select 1 from public.appointments appointment where appointment.id = new.appointment_id
        and appointment.organization_id = new.organization_id
        and (appointment.subscription_session_id is not null or appointment.subscription_bundle_session_id is not null)
    ))
  ) then
    new.status := 'SKIPPED';
    new.last_error_code := 'SUBSCRIPTION_WHATSAPP_PAUSED';
    new.locked_at := null;
    new.locked_by := null;
    new.lock_expires_at := null;
    new.lease_token := null;
    new.updated_at := now();
  end if;
  return new;
end;
$$;
revoke all on function public.pause_subscription_whatsapp_job_insert() from public, anon, authenticated;

create or replace function public.whatsapp_v2_subscription_job_allowed(
  p_job_id uuid,
  p_worker_id text,
  p_lease_token uuid default null
)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_job public.whatsapp_automation_jobs%rowtype;
  v_subscription_job boolean;
begin
  perform public.require_service_role();
  select * into v_job from public.whatsapp_automation_jobs where id = p_job_id for update;
  if not found or v_job.status <> 'PROCESSING'
     or v_job.locked_by is distinct from p_worker_id
     or (p_lease_token is not null and v_job.lease_token is distinct from p_lease_token) then
    return false;
  end if;
  v_subscription_job := v_job.payload ->> 'message_kind' = 'SUBSCRIPTION_CREATED_CLIENT'
    or (v_job.appointment_id is not null and exists (
      select 1 from public.appointments appointment
       where appointment.id = v_job.appointment_id and appointment.organization_id = v_job.organization_id
         and (appointment.subscription_session_id is not null or appointment.subscription_bundle_session_id is not null)
    ))
    or v_job.payload ->> 'payment_mode' = 'SUBSCRIPTION';
  if v_subscription_job then
    if v_job.send_started_at is null then
      update public.whatsapp_automation_jobs
         set status = 'SKIPPED', last_error_code = 'SUBSCRIPTION_WHATSAPP_PAUSED',
             locked_at = null, locked_by = null, lock_expires_at = null,
             lease_token = null, updated_at = now()
       where id = v_job.id;
    end if;
    return false;
  end if;
  return true;
end;
$$;
revoke all on function public.whatsapp_v2_subscription_job_allowed(uuid,text,uuid)
  from public, anon, authenticated;
grant execute on function public.whatsapp_v2_subscription_job_allowed(uuid,text,uuid)
  to service_role;

-- Keep the subscription module disconnected from WhatsApp while V2 is being rebuilt.
-- These guards are keyed only to bundle-linked appointments and do not affect normal bookings.
create or replace function public.pause_bundle_subscription_whatsapp_outbox()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.appointment_id is not null and exists (
    select 1 from public.appointments appointment
     where appointment.id = new.appointment_id and appointment.organization_id = new.organization_id
       and appointment.subscription_bundle_session_id is not null
  ) then
    new.status := 'CANCELED';
    new.last_error := 'SUBSCRIPTION_WHATSAPP_PAUSED';
    new.claimed_at := null;
    new.claimed_by := null;
    new.lease_expires_at := null;
    new.updated_at := now();
  end if;
  return new;
end;
$$;
revoke all on function public.pause_bundle_subscription_whatsapp_outbox() from public, anon, authenticated;
drop trigger if exists subscription_bundle_whatsapp_outbox_paused on public.notification_outbox;
create trigger subscription_bundle_whatsapp_outbox_paused
  before insert or update on public.notification_outbox
  for each row execute function public.pause_bundle_subscription_whatsapp_outbox();
update public.notification_outbox outbox
   set status = 'CANCELED', last_error = 'SUBSCRIPTION_WHATSAPP_PAUSED',
       claimed_at = null, claimed_by = null, lease_expires_at = null, updated_at = now()
 where outbox.status in ('PENDING', 'FAILED', 'PROCESSING', 'SENDING')
   and exists (select 1 from public.appointments appointment
     where appointment.id = outbox.appointment_id and appointment.organization_id = outbox.organization_id
       and appointment.subscription_bundle_session_id is not null);

create or replace function public.pause_bundle_subscription_whatsapp_confirmation()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from public.appointments appointment
      where appointment.id = new.appointment_id and appointment.organization_id = new.organization_id
        and appointment.subscription_bundle_session_id is not null) then
    new.status := 'EXPIRED';
    new.updated_at := now();
  end if;
  return new;
end;
$$;
revoke all on function public.pause_bundle_subscription_whatsapp_confirmation() from public, anon, authenticated;
drop trigger if exists subscription_bundle_whatsapp_confirmation_paused on public.whatsapp_confirmation_requests_v2;
create trigger subscription_bundle_whatsapp_confirmation_paused
  before insert or update on public.whatsapp_confirmation_requests_v2
  for each row execute function public.pause_bundle_subscription_whatsapp_confirmation();
update public.whatsapp_confirmation_requests_v2 request
   set status = 'EXPIRED', updated_at = now()
 where request.status = 'PENDING'
   and exists (select 1 from public.appointments appointment
     where appointment.id = request.appointment_id and appointment.organization_id = request.organization_id
       and appointment.subscription_bundle_session_id is not null);

create or replace function public.pause_bundle_subscription_whatsapp_action_token()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from public.appointments appointment
      where appointment.id = new.appointment_id and appointment.organization_id = new.organization_id
        and appointment.subscription_bundle_session_id is not null) then
    new.consumed_at := coalesce(new.consumed_at, now());
  end if;
  return new;
end;
$$;
revoke all on function public.pause_bundle_subscription_whatsapp_action_token() from public, anon, authenticated;
drop trigger if exists subscription_bundle_whatsapp_action_token_paused on public.customer_action_tokens;
create trigger subscription_bundle_whatsapp_action_token_paused
  before insert or update on public.customer_action_tokens
  for each row execute function public.pause_bundle_subscription_whatsapp_action_token();
update public.customer_action_tokens token
   set consumed_at = coalesce(token.consumed_at, now())
 where token.consumed_at is null and token.expires_at > now()
   and exists (select 1 from public.appointments appointment
     where appointment.id = token.appointment_id and appointment.organization_id = token.organization_id
       and appointment.subscription_bundle_session_id is not null);
