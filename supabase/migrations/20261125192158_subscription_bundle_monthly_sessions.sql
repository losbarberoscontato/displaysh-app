-- Add a monthly session allowance for free-scheduling bundle plans.
-- A NULL allowance preserves the weekly behavior of existing contracts.
alter table public.subscription_plan_versions
  add column bundle_sessions_per_month smallint,
  add constraint subscription_plan_versions_bundle_sessions_per_month_check
    check (
      bundle_sessions_per_month is null
      or (model = 'SESSION_BUNDLE_V1'
        and bundle_scheduling_mode = 'FREE'
        and bundle_sessions_per_month between 1 and 300
        and bundle_sessions_per_month <= bundle_total_sessions)
    );

-- Move free plan versions to a fixed monthly allowance; contract rows remain
-- NULL so existing contracts keep their original weekly limit.
update public.subscription_plan_versions
   set bundle_sessions_per_month = bundle_sessions_per_week * 4
 where model = 'SESSION_BUNDLE_V1'
   and bundle_scheduling_mode = 'FREE'
   and bundle_sessions_per_month is null;

create or replace function public.set_subscription_plan_monthly_limit()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.model = 'SESSION_BUNDLE_V1'
     and new.bundle_scheduling_mode = 'FREE'
     and new.bundle_sessions_per_month is null then
    new.bundle_sessions_per_month := new.bundle_sessions_per_week * 4;
  end if;
  return new;
end;
$$;
revoke all on function public.set_subscription_plan_monthly_limit() from public, anon, authenticated, service_role;
create trigger subscription_plan_versions_set_monthly_limit
  before insert on public.subscription_plan_versions
  for each row execute function public.set_subscription_plan_monthly_limit();

alter table public.subscription_bundle_contracts
  add column sessions_per_month smallint,
  add constraint subscription_bundle_contracts_sessions_per_month_check
    check (
      sessions_per_month is null
      or (scheduling_mode = 'FREE'
        and sessions_per_month between 1 and 300
        and sessions_per_month <= total_sessions)
    );

create or replace function public.set_subscription_bundle_monthly_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sessions_per_month smallint;
begin
  select plan_version.bundle_sessions_per_month into v_sessions_per_month
    from public.subscription_plan_versions plan_version
   where plan_version.id = new.plan_version_id and plan_version.organization_id = new.organization_id;
  if v_sessions_per_month is not null and new.scheduling_mode <> 'FREE' then
    raise exception using errcode = '22023', message = 'monthly sessions require free scheduling';
  end if;
  new.sessions_per_month := v_sessions_per_month;
  return new;
end;
$$;
revoke all on function public.set_subscription_bundle_monthly_limit() from public, anon, authenticated, service_role;
create trigger subscription_bundle_contracts_set_monthly_limit
  before insert on public.subscription_bundle_contracts
  for each row execute function public.set_subscription_bundle_monthly_limit();
create or replace function public.save_subscription_bundle_plan_monthly(
  p_organization_id uuid,
  p_plan_id uuid,
  p_name text,
  p_description text,
  p_service_id uuid,
  p_scheduling_mode text,
  p_sessions_per_period smallint,
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
  v_contract_duration_months smallint;
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
     or p_sessions_per_period is null
     or (p_scheduling_mode = 'FREE' and p_sessions_per_period not between 1 and 300)
     or (p_scheduling_mode = 'FIXED' and p_sessions_per_period not between 1 and 21)
     or p_session_duration_minutes not between 5 and 180
     or p_total_sessions is null or p_total_sessions not between 1 and 300
     or p_price_per_session_cents <= 0
     or p_entry_cents < 0
     or p_installment_count not between 1 and 24
     or p_discount_type not in ('NONE', 'FIXED', 'PERCENT')
     or p_discount_value < 0 then
    raise exception using errcode = '22023', message = 'invalid subscription bundle plan';
  end if;
  if p_scheduling_mode = 'FREE' then
    if p_total_sessions % p_sessions_per_period <> 0 then
      raise exception using errcode = '22023', message = 'total sessions must match monthly sessions and contract duration';
    end if;
    v_contract_duration_months := (p_total_sessions / p_sessions_per_period)::smallint;
  else
    if p_total_sessions % (p_sessions_per_period * 4) <> 0 then
      raise exception using errcode = '22023', message = 'total sessions must match weekly sessions and contract duration';
    end if;
    v_contract_duration_months := (p_total_sessions / (p_sessions_per_period * 4))::smallint;
  end if;
  if v_contract_duration_months not between 1 and 24 then
    raise exception using errcode = '22023', message = 'subscription bundle contract duration must be between 1 and 24 months';
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
    bundle_service_id, bundle_sessions_per_week, bundle_sessions_per_month, bundle_session_duration_minutes,
    bundle_total_sessions, bundle_price_per_session_cents, bundle_entry_cents,
    bundle_installment_count, bundle_discount_type, bundle_discount_value, created_by
  ) values (
    p_organization_id, v_plan.id, v_version_number, v_total, 'MONTHLY', v_contract_duration_months, 1,
    'Plano contratado por sessões.', 'Cancelamento de sessões conforme disponibilidade do plano.',
    'v1', v_payment_method, 'SESSION_BUNDLE_V1', p_scheduling_mode,
    v_service.id, case when p_scheduling_mode = 'FREE' then 1 else p_sessions_per_period end,
    case when p_scheduling_mode = 'FREE' then p_sessions_per_period else null end,
    p_session_duration_minutes, p_total_sessions,
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
revoke all on function public.save_subscription_bundle_plan_monthly(uuid,uuid,text,text,uuid,text,smallint,smallint,smallint,bigint,bigint,text,smallint,text,bigint)
  from public, anon;
grant execute on function public.save_subscription_bundle_plan_monthly(uuid,uuid,text,text,uuid,text,smallint,smallint,smallint,bigint,bigint,text,smallint,text,bigint)
  to authenticated;
create or replace function public.provision_subscription_bundle_contract(
  p_organization_id uuid, p_subscription_id uuid, p_actor_id uuid
)
returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_org public.organizations%rowtype;
  v_installment smallint;
  v_month date;
  v_month_capacity integer;
  v_remaining integer;
  v_offset integer;
  v_session_number integer := 0;
  v_session_id uuid;
  v_slot public.subscription_bundle_fixed_slots%rowtype;
  v_candidate record;
  v_local_date date;
  v_local_start timestamp;
  v_starts_at timestamptz;
  v_period tstzrange;
  v_occupied integer;
  v_version_end date;
  v_base bigint;
  v_discount bigint;
  v_due_month date;
  v_due_date date;
begin
  select * into strict v_sub from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id for update;
  if v_sub.status not in ('ACTIVE', 'PENDING_PAYMENT')
     or (v_sub.contract_accepted_at is null and v_sub.manager_activated_provisionally_at is null) then
    raise exception using errcode = '22023', message = 'bundle must be accepted or provisionally activated before provisioning';
  end if;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_sub.id and organization_id = p_organization_id for update;
  select * into strict v_org from public.organizations where id = p_organization_id;

  if v_contract.entry_cents > 0 then
    insert into public.subscription_bundle_installments(
      organization_id, subscription_id, installment_number, kind, due_on, amount_cents, payment_method
    ) values (p_organization_id, v_sub.id, 0, 'ENTRY', v_contract.entry_due_on,
      v_contract.entry_cents, v_sub.payment_method)
    on conflict (subscription_id, installment_number) do nothing;
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
      v_base - v_discount, v_sub.payment_method)
    on conflict (subscription_id, installment_number) do nothing;
  end loop;
  update public.subscription_bundle_installments installment
     set status = installment.status
   where installment.organization_id = p_organization_id
     and installment.subscription_id = v_sub.id
     and installment.status in ('OPEN', 'OVERDUE')
     and installment.financial_entry_id is null;

  if v_contract.scheduling_mode = 'FREE' then
    v_month := date_trunc('month', v_contract.first_session_date::timestamp)::date;
    v_remaining := v_contract.total_sessions;
    while v_remaining > 0 loop
      v_month_capacity := case when v_contract.sessions_per_month is not null
        then v_contract.sessions_per_month
        else greatest(public.subscription_bundle_weeks_in_month(v_month), 1) * v_contract.sessions_per_week
      end;
      for v_offset in 1..least(v_remaining, v_month_capacity) loop
        v_session_number := v_session_number + 1;
        v_installment := least(v_contract.installment_count,
          greatest(1, ((extract(year from v_month) - extract(year from date_trunc('month', v_contract.first_session_date::timestamp)::date))::integer * 12
            + extract(month from v_month) - extract(month from date_trunc('month', v_contract.first_session_date::timestamp)::date) + 1))::smallint);
        insert into public.subscription_bundle_sessions(
          organization_id, subscription_id, session_number, release_on, installment_number
        ) values (p_organization_id, v_sub.id, v_session_number, v_month, v_installment)
        on conflict (subscription_id, session_number) do nothing;
      end loop;
      v_remaining := v_remaining - least(v_remaining, v_month_capacity);
      v_month := (v_month + interval '1 month')::date;
    end loop;
    if v_contract.sessions_per_month is not null then
      v_version_end := (v_contract.first_session_date
        + make_interval(months => ceil(v_contract.total_sessions::numeric / v_contract.sessions_per_month)::integer)
        - interval '1 day')::date;
    else
      v_version_end := (v_contract.first_session_date
        + make_interval(days => ceil(v_contract.total_sessions::numeric / v_contract.sessions_per_week)::integer * 7))::date;
    end if;
  else
    insert into public.subscription_bundle_sessions(
      organization_id, subscription_id, session_number, release_on, installment_number
    ) select p_organization_id, v_sub.id, n, v_contract.first_session_date, 1
      from generate_series(1, v_contract.total_sessions) n
      on conflict (subscription_id, session_number) do nothing;
    if exists (select 1 from public.subscription_bundle_sessions session
       where session.organization_id = p_organization_id and session.subscription_id = v_sub.id
         and session.status = 'SCHEDULED') then
      if (select count(*) from public.subscription_bundle_sessions session
           where session.organization_id = p_organization_id and session.subscription_id = v_sub.id
             and session.status = 'SCHEDULED') < v_contract.total_sessions then
        raise exception using errcode = '22023', message = 'partially provisioned fixed schedule requires manager review';
      end if;
      select max((session.scheduled_for at time zone v_org.timezone)::date)
        into v_version_end from public.subscription_bundle_sessions session
       where session.organization_id = p_organization_id and session.subscription_id = v_sub.id;
    else
      v_occupied := ceil(v_contract.session_duration_minutes::numeric / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes;
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
        select session.id into strict v_session_id from public.subscription_bundle_sessions session
         where session.organization_id = p_organization_id and session.subscription_id = v_sub.id
           and session.session_number = v_session_number for update;
        update public.subscription_bundle_sessions set release_on = v_local_date,
          installment_number = v_installment, barber_id = v_candidate.barber_id,
          environment_id = v_candidate.environment_id
         where id = v_session_id and organization_id = p_organization_id;
        perform public.create_subscription_bundle_appointment(
          p_organization_id, v_sub.customer_id, v_sub.id, v_session_id,
          v_candidate.barber_id, v_candidate.environment_id, v_starts_at, p_actor_id, 'MANAGER'
        );
        v_version_end := v_local_date;
      end loop;
      if v_session_number < v_contract.total_sessions then
        raise exception using errcode = '22023', message = 'fixed schedule could not generate all subscription sessions';
      end if;
    end if;
  end if;

  update public.customer_subscriptions set end_date = v_version_end, updated_at = now()
   where id = v_sub.id and organization_id = p_organization_id;
end;
$$;
revoke all on function public.provision_subscription_bundle_contract(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
create or replace function public.book_customer_subscription_bundle_session(
  p_organization_id uuid,
  p_customer_id uuid,
  p_session_id uuid,
  p_barber_id uuid,
  p_starts_at timestamptz
)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_session public.subscription_bundle_sessions%rowtype;
  v_sub public.customer_subscriptions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_org public.organizations%rowtype;
  v_local_date date;
  v_week_start date;
  v_week_count integer;
  v_month_count integer;
  v_month_start date;
  v_today date;
  v_appointment_id uuid;
begin
  if not public.is_organization_customer(p_organization_id, p_customer_id) then
    raise exception using errcode = '42501', message = 'customer booking denied';
  end if;
  select * into strict v_session from public.subscription_bundle_sessions
   where id = p_session_id and organization_id = p_organization_id and deleted_at is null for update;
  select * into strict v_sub from public.customer_subscriptions
   where id = v_session.subscription_id and organization_id = p_organization_id for update;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_sub.id and organization_id = p_organization_id;
  select * into strict v_org from public.organizations where id = p_organization_id;
  v_today := (now() at time zone v_org.timezone)::date;
  v_local_date := (p_starts_at at time zone v_org.timezone)::date;
  v_week_start := date_trunc('week', v_local_date::timestamp)::date;
  v_month_start := date_trunc('month', v_local_date::timestamp)::date;
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
  if v_contract.sessions_per_month is not null then
    select count(*) into v_month_count from public.subscription_bundle_sessions session
     where session.organization_id = p_organization_id and session.subscription_id = v_sub.id
       and session.deleted_at is null and session.status in ('SCHEDULED', 'COMPLETED') and session.scheduled_for is not null
       and (session.scheduled_for at time zone v_org.timezone)::date >= v_month_start
       and (session.scheduled_for at time zone v_org.timezone)::date < (v_month_start + interval '1 month')::date;
    if v_month_count >= v_contract.sessions_per_month then
      raise exception using errcode = '22023', message = 'subscription_monthly_booking_limit';
    end if;
  else
    select count(*) into v_week_count from public.subscription_bundle_sessions session
     where session.organization_id = p_organization_id and session.subscription_id = v_sub.id
       and session.deleted_at is null and session.status in ('SCHEDULED', 'COMPLETED') and session.scheduled_for is not null
       and (session.scheduled_for at time zone v_org.timezone)::date >= v_week_start
       and (session.scheduled_for at time zone v_org.timezone)::date < v_week_start + 7;
    if v_week_count >= v_contract.sessions_per_week then
      raise exception using errcode = '22023', message = 'subscription_weekly_booking_limit';
    end if;
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
