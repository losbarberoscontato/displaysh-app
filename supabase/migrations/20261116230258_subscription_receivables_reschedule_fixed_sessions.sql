-- Create subscription receivables on provisional activation as well as after
-- customer acceptance. Upfront plans have one aggregate receivable attached to
-- their first cycle.
create or replace function public.create_subscription_cycle_receivable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subscription public.customer_subscriptions%rowtype;
  v_plan_version public.subscription_plan_versions%rowtype;
  v_chart_account_id uuid;
  v_financial_entry_id uuid;
  v_cycle_id uuid := new.id;
  v_amount_cents bigint := new.amount_cents;
  v_due_on date := new.due_on;
  v_expected_cycles integer;
  v_created_cycles integer;
begin
  if new.status not in ('OPEN', 'OVERDUE') or new.financial_entry_id is not null then
    return new;
  end if;

  select *
    into v_subscription
    from public.customer_subscriptions
   where id = new.subscription_id
     and organization_id = new.organization_id;
  if not found
     or v_subscription.status not in ('ACTIVE', 'PENDING_PAYMENT')
     or (v_subscription.contract_accepted_at is null
       and v_subscription.manager_activated_provisionally_at is null) then
    return new;
  end if;

  select *
    into strict v_plan_version
    from public.subscription_plan_versions
   where id = v_subscription.plan_version_id
     and organization_id = new.organization_id;

  if v_subscription.upfront_payment then
    v_expected_cycles := case
      when v_plan_version.billing_period = 'BIWEEKLY' then v_plan_version.duration_months * 2
      else v_plan_version.duration_months
    end;
    select count(*)::integer
      into v_created_cycles
      from public.customer_subscription_cycles cycle
     where cycle.organization_id = new.organization_id
       and cycle.subscription_id = new.subscription_id;
    if v_created_cycles < v_expected_cycles then
      return new;
    end if;

    select cycle.id, cycle.due_on
      into v_cycle_id, v_due_on
      from public.customer_subscription_cycles cycle
     where cycle.organization_id = new.organization_id
       and cycle.subscription_id = new.subscription_id
     order by cycle.cycle_number
     limit 1;
    if v_cycle_id is null then
      return new;
    end if;
    if exists (
      select 1
        from public.customer_subscription_cycles cycle
       where cycle.id = v_cycle_id
         and cycle.organization_id = new.organization_id
         and cycle.financial_entry_id is not null
    ) then
      return new;
    end if;
    select coalesce(sum(cycle.amount_cents), 0)::bigint
      into v_amount_cents
      from public.customer_subscription_cycles cycle
     where cycle.organization_id = new.organization_id
       and cycle.subscription_id = new.subscription_id
       and cycle.status in ('OPEN', 'OVERDUE');
  end if;

  select account.id
    into v_chart_account_id
    from public.chart_of_accounts account
   where account.organization_id = new.organization_id
     and account.kind = 'REVENUE'
     and account.active
   order by account.created_at, account.id
   limit 1;
  if v_chart_account_id is null then
    raise exception using errcode = '22023', message = 'active revenue chart account is required to create a subscription receivable';
  end if;

  insert into public.financial_entries(
    organization_id, kind, source, description, issue_date, competence_date, due_date, total_cents,
    currency, chart_account_id, counterparty_kind, customer_id, subscription_cycle_id
  ) values (
    new.organization_id, 'REVENUE', 'SUBSCRIPTION',
    public.subscription_financial_entry_description(v_cycle_id),
    least(current_date, v_due_on), least(current_date, v_due_on), v_due_on, v_amount_cents,
    'BRL', v_chart_account_id, 'CUSTOMER', v_subscription.customer_id, v_cycle_id
  )
  on conflict (organization_id, subscription_cycle_id)
    where source = 'SUBSCRIPTION' and subscription_cycle_id is not null and canceled_at is null
  do nothing
  returning id into v_financial_entry_id;

  if v_financial_entry_id is null then
    select entry.id
      into v_financial_entry_id
      from public.financial_entries entry
     where entry.organization_id = new.organization_id
       and entry.subscription_cycle_id = v_cycle_id
       and entry.source = 'SUBSCRIPTION'
       and entry.canceled_at is null
     order by entry.created_at desc
     limit 1;
  end if;
  if v_financial_entry_id is not null then
    update public.customer_subscription_cycles
       set financial_entry_id = v_financial_entry_id
     where id = v_cycle_id
       and organization_id = new.organization_id
       and financial_entry_id is distinct from v_financial_entry_id;
  end if;
  return new;
end;
$$;

revoke all on function public.create_subscription_cycle_receivable()
  from public, anon, authenticated;

-- Repair open cycles created by the previous provisional-activation release.
-- Skip organizations without a revenue account so this migration remains safe;
-- future activation reports the configuration error normally.
update public.customer_subscription_cycles cycle
   set status = cycle.status
  from public.customer_subscriptions subscription
 where subscription.id = cycle.subscription_id
   and subscription.organization_id = cycle.organization_id
   and subscription.status in ('ACTIVE', 'PENDING_PAYMENT')
   and (subscription.contract_accepted_at is not null
     or subscription.manager_activated_provisionally_at is not null)
   and cycle.status in ('OPEN', 'OVERDUE')
   and cycle.financial_entry_id is null
   and exists (
     select 1 from public.chart_of_accounts account
      where account.organization_id = cycle.organization_id
        and account.kind = 'REVENUE' and account.active
   );

-- A provisional activation may be received by the manager. If the client later
-- declines, the settlement remains in the ledger for manual adjustment.
create or replace function public.guard_provisional_subscription_payment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contract_accepted_at timestamptz;
  v_provisionally_activated_at timestamptz;
  v_subscription_status public.subscription_enrollment_status;
begin
  select subscription.contract_accepted_at,
         subscription.manager_activated_provisionally_at,
         subscription.status
    into v_contract_accepted_at, v_provisionally_activated_at, v_subscription_status
    from public.customer_subscriptions subscription
   where subscription.id = new.subscription_id
     and subscription.organization_id = new.organization_id
   for update;
  if v_contract_accepted_at is null
     and not (
       v_subscription_status = 'ACTIVE'
       and v_provisionally_activated_at is not null
       and public.is_organization_owner(new.organization_id)
     ) then
    raise exception using errcode = '22023', message = 'client acceptance or manager provisional activation is required before payment';
  end if;
  return new;
end;
$$;

revoke all on function public.guard_provisional_subscription_payment()
  from public, anon, authenticated;

-- New accepted offers generate open receivables, including upfront plans. The
-- receivable trigger consolidates upfront cycles after the final cycle exists.
create or replace function public.accept_customer_subscription_offer_before_provisional_activation(
  p_organization_id uuid,
  p_subscription_id uuid
)
returns public.customer_subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_plan public.subscription_plan_versions%rowtype;
  v_cycle public.customer_subscription_cycles%rowtype;
  v_timezone text;
  v_start_date date;
  v_cycle_count integer;
  v_start date;
  v_end date;
  v_due date;
  i integer;
  j integer;
begin
  select * into strict v_sub
    from public.customer_subscriptions
   where id = p_subscription_id
     and organization_id = p_organization_id
   for update;
  if not public.is_organization_customer(p_organization_id, v_sub.customer_id) then
    raise exception using errcode = '42501', message = 'subscription offer acceptance denied';
  end if;
  if v_sub.status = 'ACTIVE' and v_sub.contract_accepted_by = auth.uid() then
    return v_sub;
  end if;
  if v_sub.status <> 'REQUESTED' or v_sub.contract_accepted_at is not null then
    raise exception using errcode = '22023', message = 'subscription offer is not awaiting acceptance';
  end if;

  select * into strict v_plan
    from public.subscription_plan_versions
   where id = v_sub.plan_version_id
     and organization_id = p_organization_id;
  select timezone into strict v_timezone
    from public.organizations
   where id = p_organization_id;
  v_start_date := (now() at time zone v_timezone)::date;
  v_cycle_count := case
    when v_plan.billing_period = 'BIWEEKLY' then v_plan.duration_months * 2
    else v_plan.duration_months
  end;

  update public.customer_subscriptions
     set status = 'ACTIVE',
         contract_accepted_at = now(),
         contract_accepted_by = auth.uid(),
         start_date = v_start_date,
         end_date = case
           when v_plan.billing_period = 'BIWEEKLY' then v_start_date + (v_cycle_count * 15 - 1)
           else (v_start_date + (v_plan.duration_months || ' months')::interval - interval '1 day')::date
         end,
         first_due_date = v_start_date,
         due_day = extract(day from v_start_date)::smallint,
         updated_at = now()
   where id = v_sub.id
     and organization_id = p_organization_id
  returning * into v_sub;

  insert into public.subscription_contract_acceptances(
    organization_id, subscription_id, contract_version, accepted_by, acceptance_source
  ) values (
    p_organization_id, v_sub.id, v_sub.contract_version, auth.uid(), 'CLIENT_OFFER'
  ) on conflict (subscription_id, contract_version) do nothing;

  for i in 1..v_cycle_count loop
    v_start := case
      when v_plan.billing_period = 'BIWEEKLY' then v_start_date + ((i - 1) * 15)
      else (v_start_date + ((i - 1) || ' months')::interval)::date
    end;
    v_end := case
      when v_plan.billing_period = 'BIWEEKLY' then v_start + 14
      else (v_start + interval '1 month' - interval '1 day')::date
    end;
    v_due := case
      when i = 1 then v_start_date
      when v_plan.billing_period = 'BIWEEKLY' then v_start_date + ((i - 1) * 15)
      else make_date(
        extract(year from v_start)::int,
        extract(month from v_start)::int,
        least(v_sub.due_day, extract(day from (date_trunc('month', v_start) + interval '1 month - 1 day'))::int)
      )
    end;
    insert into public.customer_subscription_cycles(
      organization_id, subscription_id, cycle_number, starts_on, ends_on, due_on, amount_cents, status
    ) values (
      p_organization_id, v_sub.id, i, v_start, v_end, v_due,
      v_plan.price_cents, 'OPEN'::public.subscription_cycle_status
    ) returning * into v_cycle;

    for j in 1..v_plan.sessions_per_cycle loop
      insert into public.customer_subscription_sessions(
        organization_id, subscription_id, cycle_id, session_number, available_until
      ) values (
        p_organization_id, v_sub.id, v_cycle.id, j, v_end
      );
    end loop;
  end loop;

  insert into public.subscription_events(
    organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata
  ) values (
    p_organization_id, v_sub.id, 'ACTIVATED', auth.uid(),
    'client-offer-activated:' || v_sub.id,
    jsonb_build_object('acceptance_source', 'CLIENT_OFFER')
  ) on conflict (organization_id, idempotency_key) do nothing;
  update public.customer_in_app_notifications
     set read_at = coalesce(read_at, now())
   where organization_id = p_organization_id
     and customer_id = v_sub.customer_id
     and subscription_id = v_sub.id;
  return v_sub;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription, plan or organization not found';
end;
$$;

revoke all on function public.accept_customer_subscription_offer_before_provisional_activation(uuid, uuid)
  from public, anon, authenticated, service_role;

-- Acknowledging a provisional plan must not mark unpaid upfront cycles as paid.
create or replace function public.accept_customer_subscription_offer(
  p_organization_id uuid,
  p_subscription_id uuid
)
returns public.customer_subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_customer_name text;
  v_plan_name text;
  v_owner uuid;
begin
  select * into strict v_sub
    from public.customer_subscriptions
   where id = p_subscription_id
     and organization_id = p_organization_id
   for update;
  if not public.is_organization_customer(p_organization_id, v_sub.customer_id) then
    raise exception using errcode = '42501', message = 'subscription offer acceptance denied';
  end if;
  if v_sub.status = 'ACTIVE' and v_sub.contract_accepted_by = auth.uid() then
    return v_sub;
  end if;

  if v_sub.status = 'ACTIVE'
     and v_sub.manager_activated_provisionally_at is not null
     and v_sub.contract_accepted_at is null then
    update public.customer_subscriptions
       set contract_accepted_at = now(), contract_accepted_by = auth.uid(), updated_at = now()
     where id = v_sub.id and organization_id = p_organization_id
    returning * into v_sub;
    insert into public.subscription_contract_acceptances(
      organization_id, subscription_id, contract_version, accepted_by, acceptance_source
    ) values (
      p_organization_id, v_sub.id, v_sub.contract_version, auth.uid(), 'CLIENT'
    ) on conflict (subscription_id, contract_version) do nothing;
    update public.customer_subscription_cycles
       set status = status
     where organization_id = p_organization_id
       and subscription_id = v_sub.id
       and status in ('OPEN', 'OVERDUE');
    insert into public.subscription_events(
      organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata
    ) values (
      p_organization_id, v_sub.id, 'CLIENT_ACCEPTED_AFTER_PROVISIONAL_ACTIVATION', auth.uid(),
      'client-accepted-provisional:' || v_sub.id,
      jsonb_build_object('acceptance_source', 'CLIENT')
    ) on conflict (organization_id, idempotency_key) do nothing;
    update public.customer_in_app_notifications
       set read_at = coalesce(read_at, now())
     where organization_id = p_organization_id
       and customer_id = v_sub.customer_id
       and subscription_id = v_sub.id;
    select customer.full_name, plan.name
      into v_customer_name, v_plan_name
      from public.customers customer
      join public.subscription_plans plan
        on plan.id = v_sub.plan_id and plan.organization_id = p_organization_id
     where customer.id = v_sub.customer_id and customer.organization_id = p_organization_id;
    for v_owner in
      select membership.user_id
        from public.organization_memberships membership
       where membership.organization_id = p_organization_id
         and membership.active and membership.role = 'OWNER'
    loop
      insert into public.manager_notifications(
        organization_id, recipient_user_id, customer_id, subscription_id,
        kind, title, body, href
      ) values (
        p_organization_id, v_owner, v_sub.customer_id, v_sub.id,
        'SUBSCRIPTION_OFFER_ACCEPTED', 'Plano aceito pelo cliente',
        coalesce(v_customer_name, 'O cliente') || ' aceitou o plano ' || coalesce(v_plan_name, 'de assinatura') || '.',
        '/gestor/clientes?cliente=' || v_sub.customer_id::text || '&aba=agendamentos'
      ) on conflict do nothing;
    end loop;
    return v_sub;
  end if;
  return public.accept_customer_subscription_offer_before_provisional_activation(
    p_organization_id, p_subscription_id
  );
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription, customer or plan not found';
end;
$$;

revoke all on function public.accept_customer_subscription_offer(uuid, uuid)
  from public, anon;
grant execute on function public.accept_customer_subscription_offer(uuid, uuid)
  to authenticated;

-- A declined provisional offer closes only unpaid receivables. Settlements
-- already recorded remain available for manual adjustment.
create or replace function public.cancel_declined_provisional_subscription_receivables()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status is distinct from new.status
     and new.status = 'DECLINED'
     and new.manager_activated_provisionally_at is not null
     and new.contract_accepted_at is null then
    update public.financial_entries entry
       set canceled_at = now(),
           cancellation_reason = 'Oferta de assinatura recusada pelo cliente'
     where entry.organization_id = new.organization_id
       and entry.source = 'SUBSCRIPTION'
       and entry.canceled_at is null
       and entry.subscription_cycle_id in (
         select cycle.id
           from public.customer_subscription_cycles cycle
          where cycle.organization_id = new.organization_id
            and cycle.subscription_id = new.id
            and cycle.status = 'CANCELED'
       )
       and not exists (
         select 1
           from public.financial_settlements settlement
          where settlement.organization_id = new.organization_id
            and settlement.entry_id = entry.id
       );
  end if;
  return new;
end;
$$;

revoke all on function public.cancel_declined_provisional_subscription_receivables()
  from public, anon, authenticated;
drop trigger if exists customer_subscriptions_cancel_declined_receivables on public.customer_subscriptions;
create trigger customer_subscriptions_cancel_declined_receivables
  after update of status on public.customer_subscriptions
  for each row execute function public.cancel_declined_provisional_subscription_receivables();

-- Fixed-plan appointments always carry a 24-hour customer reschedule window.
create or replace function public.set_fixed_subscription_reschedule_window()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_scheduling_mode text;
begin
  if new.subscription_session_id is null then
    return new;
  end if;
  select plan_version.scheduling_mode::text
    into v_scheduling_mode
    from public.customer_subscription_sessions session
    join public.customer_subscriptions subscription
      on subscription.id = session.subscription_id
     and subscription.organization_id = session.organization_id
    join public.subscription_plan_versions plan_version
      on plan_version.id = subscription.plan_version_id
     and plan_version.organization_id = subscription.organization_id
   where session.id = new.subscription_session_id
     and session.organization_id = new.organization_id;
  if v_scheduling_mode = 'FIXED' then
    new.cancellation_lead_minutes_snapshot := 1440;
  end if;
  return new;
end;
$$;

revoke all on function public.set_fixed_subscription_reschedule_window()
  from public, anon, authenticated;
drop trigger if exists appointments_fixed_subscription_reschedule_window on public.appointments;
create trigger appointments_fixed_subscription_reschedule_window
  before insert or update of subscription_session_id on public.appointments
  for each row execute function public.set_fixed_subscription_reschedule_window();

update public.appointments appointment
   set cancellation_lead_minutes_snapshot = 1440
  from public.customer_subscription_sessions session
  join public.customer_subscriptions subscription
    on subscription.id = session.subscription_id
   and subscription.organization_id = session.organization_id
  join public.subscription_plan_versions plan_version
    on plan_version.id = subscription.plan_version_id
   and plan_version.organization_id = subscription.organization_id
 where appointment.organization_id = session.organization_id
   and appointment.subscription_session_id = session.id
   and appointment.status = 'CONFIRMED'
   and lower(appointment.service_period) > now()
   and plan_version.scheduling_mode = 'FIXED'
   and appointment.cancellation_lead_minutes_snapshot is distinct from 1440;

create or replace function public.reschedule_fixed_customer_subscription_session(
  p_organization_id uuid,
  p_subscription_session_id uuid,
  p_new_starts_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session public.customer_subscription_sessions%rowtype;
  v_subscription public.customer_subscriptions%rowtype;
  v_plan_version public.subscription_plan_versions%rowtype;
  v_appointment public.appointments%rowtype;
  v_organization public.organizations%rowtype;
  v_is_owner boolean;
  v_is_customer boolean;
  v_local_start timestamp;
  v_duration integer;
  v_occupied integer;
  v_new_period tstzrange;
  v_session_subscription_id uuid;
  v_session_appointment_id uuid;
begin
  if not public.organization_module_enabled(p_organization_id, 'subscription_plans') then
    raise exception using errcode = '42501', message = 'subscription module disabled';
  end if;

  select session.subscription_id, session.appointment_id
    into v_session_subscription_id, v_session_appointment_id
    from public.customer_subscription_sessions session
   where session.id = p_subscription_session_id
     and session.organization_id = p_organization_id;
  if not found or v_session_appointment_id is null then
    raise exception using errcode = 'P0002', message = 'subscription session or appointment not found';
  end if;
  select *
    into strict v_subscription
    from public.customer_subscriptions subscription
   where subscription.id = v_session_subscription_id
     and subscription.organization_id = p_organization_id
   for update;
  -- Match the decline path lock order: subscription, appointment, then session.
  select *
    into strict v_appointment
    from public.appointments appointment
   where appointment.id = v_session_appointment_id
     and appointment.organization_id = p_organization_id
   for update;
  select *
    into strict v_session
    from public.customer_subscription_sessions session
   where session.id = p_subscription_session_id
     and session.organization_id = p_organization_id
   for update;
  if v_session.subscription_id is distinct from v_subscription.id
     or v_session.appointment_id is distinct from v_appointment.id then
    raise exception using errcode = '40001', message = 'subscription session changed; reload and try again';
  end if;
  v_is_owner := public.is_organization_owner(p_organization_id);
  v_is_customer := public.is_organization_customer(p_organization_id, v_subscription.customer_id);
  if not (v_is_owner or v_is_customer) then
    raise exception using errcode = '42501', message = 'subscription session reschedule denied';
  end if;
  if v_subscription.status <> 'ACTIVE' then
    raise exception using errcode = '22023', message = 'subscription is not active';
  end if;
  if v_is_customer and v_subscription.contract_accepted_at is null then
    raise exception using errcode = '42501', message = 'customer must accept the subscription before rescheduling';
  end if;
  select *
    into strict v_plan_version
    from public.subscription_plan_versions plan_version
   where plan_version.id = v_subscription.plan_version_id
     and plan_version.organization_id = p_organization_id;
  if v_plan_version.scheduling_mode <> 'FIXED' then
    raise exception using errcode = '22023', message = 'only fixed-plan sessions can be rescheduled here';
  end if;
  if v_session.status <> 'SCHEDULED' or v_session.appointment_id is null then
    raise exception using errcode = '22023', message = 'subscription session is not scheduled';
  end if;
  if v_appointment.subscription_session_id is distinct from v_session.id
     or v_appointment.status <> 'CONFIRMED' then
    raise exception using errcode = '22023', message = 'subscription appointment cannot be rescheduled';
  end if;
  if lower(v_appointment.service_period) <= now() then
    raise exception using errcode = '22023', message = 'only future subscription appointments can be rescheduled';
  end if;
  if not public.organization_accepts_new_bookings(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization is not accepting reschedules';
  end if;
  if p_new_starts_at <= now() then
    raise exception using errcode = '22023', message = 'appointment start must be in the future';
  end if;
  if v_is_customer and now() > lower(v_appointment.service_period) - interval '24 hours' then
    raise exception using errcode = '22023', message = 'customer reschedule deadline passed';
  end if;

  select *
    into strict v_organization
    from public.organizations organization
   where organization.id = p_organization_id;
  v_local_start := p_new_starts_at at time zone v_organization.timezone;
  if extract(second from v_local_start) <> 0
     or mod(extract(minute from v_local_start)::integer, v_organization.slot_interval_minutes) <> 0 then
    raise exception using errcode = '22023', message = 'start time is not aligned to slot interval';
  end if;
  select coalesce(sum(coalesce(item.duration_minutes_snapshot, 0) * coalesce(item.quantity, 1)), 0)::integer
    into v_duration
    from public.appointment_items item
   where item.appointment_id = v_appointment.id
     and item.organization_id = p_organization_id;
  if v_duration <= 0 then
    raise exception using errcode = '22023', message = 'subscription appointment duration is unavailable';
  end if;
  v_occupied := ceil(v_duration::numeric / v_organization.slot_interval_minutes)::integer
    * v_organization.slot_interval_minutes;
  v_new_period := tstzrange(
    p_new_starts_at,
    p_new_starts_at + make_interval(mins => v_occupied),
    '[)'
  );
  if not public.is_barber_available(p_organization_id, v_appointment.barber_id, v_new_period) then
    raise exception using errcode = '22023', message = 'requested slot is outside the professional schedule';
  end if;

  update public.appointments
     set service_period = v_new_period,
         payment_mode = 'SUBSCRIPTION',
         total_cents_snapshot = 0,
         list_total_cents_snapshot = 0,
         deposit_required_cents_snapshot = 0,
         amount_waived_cents = 0,
         cancellation_lead_minutes_snapshot = 1440,
         version = version + 1
   where id = v_appointment.id
     and organization_id = p_organization_id;

  insert into public.appointment_status_events(
    organization_id, appointment_id, from_status, to_status, reason, actor_user_id, metadata
  ) values (
    p_organization_id, v_appointment.id, 'CONFIRMED', 'CONFIRMED',
    'subscription_session_rescheduled', auth.uid(),
    jsonb_build_object(
      'subscription_session_id', v_session.id,
      'old_period', v_appointment.service_period,
      'new_period', v_new_period,
      'customer_reschedule_window_hours', 24
    )
  );

  return jsonb_build_object(
    'appointment_id', v_appointment.id,
    'subscription_session_id', v_session.id,
    'service_period', v_new_period,
    'status', 'CONFIRMED'
  );
exception
  when exclusion_violation then
    raise exception using errcode = '23P01', message = 'new slot is no longer available; original appointment preserved';
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization, subscription session or appointment not found';
end;
$$;

revoke all on function public.reschedule_fixed_customer_subscription_session(uuid, uuid, timestamptz)
  from public, anon;
grant execute on function public.reschedule_fixed_customer_subscription_session(uuid, uuid, timestamptz)
  to authenticated;
