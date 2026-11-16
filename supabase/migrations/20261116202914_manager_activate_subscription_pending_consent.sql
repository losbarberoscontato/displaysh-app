-- Operational activation is separate from customer acceptance of the contract.
alter table public.customer_subscriptions
  add column if not exists manager_activated_provisionally_at timestamptz,
  add column if not exists manager_activated_provisionally_by uuid references auth.users(id) on delete set null;

create or replace function public.manager_activate_customer_subscription_without_acceptance(
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
  v_timezone text;
  v_start_date date;
  v_cycle_count integer;
  v_start date;
  v_end date;
  v_due date;
  v_cycle public.customer_subscription_cycles%rowtype;
  i integer;
  j integer;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription provisional activation denied';
  end if;

  select *
    into strict v_sub
    from public.customer_subscriptions
   where id = p_subscription_id
     and organization_id = p_organization_id
   for update;

  if v_sub.status = 'ACTIVE'
     and v_sub.manager_activated_provisionally_at is not null
     and v_sub.contract_accepted_at is null then
    return v_sub;
  end if;

  if v_sub.status <> 'REQUESTED'
     or v_sub.contract_accepted_at is not null
     or v_sub.created_by is null
     or not exists (
       select 1
         from public.organization_memberships membership
        where membership.organization_id = p_organization_id
          and membership.user_id = v_sub.created_by
          and membership.active
          and membership.role = 'OWNER'
     ) then
    raise exception using errcode = '22023', message = 'subscription offer is not eligible for provisional activation';
  end if;

  if exists (
    select 1
      from public.customer_subscription_cycles cycle
     where cycle.organization_id = p_organization_id
       and cycle.subscription_id = v_sub.id
  ) then
    raise exception using errcode = '22023', message = 'subscription already has cycles';
  end if;

  select plan_version.*
    into strict v_plan
    from public.subscription_plan_versions plan_version
   where plan_version.id = v_sub.plan_version_id
     and plan_version.organization_id = p_organization_id;
  select organization.timezone
    into strict v_timezone
    from public.organizations organization
   where organization.id = p_organization_id;

  v_start_date := (now() at time zone v_timezone)::date;
  v_cycle_count := case
    when v_plan.billing_period = 'BIWEEKLY' then v_plan.duration_months * 2
    else v_plan.duration_months
  end;

  update public.customer_subscriptions
     set status = 'ACTIVE',
         start_date = v_start_date,
         end_date = case
           when v_plan.billing_period = 'BIWEEKLY'
             then v_start_date + (v_cycle_count * 15 - 1)
           else (v_start_date + (v_plan.duration_months || ' months')::interval - interval '1 day')::date
         end,
         first_due_date = v_start_date,
         due_day = extract(day from v_start_date)::smallint,
         manager_activated_provisionally_at = now(),
         manager_activated_provisionally_by = auth.uid(),
         updated_at = now()
   where id = v_sub.id
     and organization_id = p_organization_id
  returning * into v_sub;

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
      p_organization_id, v_sub.id, i, v_start, v_end, v_due, v_plan.price_cents, 'OPEN'
    ) returning * into v_cycle;

    for j in 1..v_plan.sessions_per_cycle loop
      insert into public.customer_subscription_sessions(
        organization_id, subscription_id, cycle_id, session_number, available_until
      ) values (
        p_organization_id, v_sub.id, v_cycle.id, j, v_end
      );
    end loop;
  end loop;

  if v_plan.scheduling_mode = 'FIXED' then
    perform public.schedule_fixed_subscription_sessions(p_organization_id, v_sub.id);
  end if;

  insert into public.subscription_events(
    organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata
  ) values (
    p_organization_id,
    v_sub.id,
    'MANAGER_ACTIVATED_PENDING_CONSENT',
    auth.uid(),
    'manager-provisional-activation:' || v_sub.id,
    jsonb_build_object('contract_accepted', false, 'source', 'MANAGER')
  ) on conflict (organization_id, idempotency_key) do nothing;

  return v_sub;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription or plan not found';
end;
$$;

revoke all on function public.manager_activate_customer_subscription_without_acceptance(uuid, uuid)
  from public, anon;
grant execute on function public.manager_activate_customer_subscription_without_acceptance(uuid, uuid)
  to authenticated;

-- Do not create receivables until the customer has actually accepted the contract.
create or replace function public.create_subscription_cycle_receivable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subscription public.customer_subscriptions%rowtype;
  v_chart_account_id uuid;
  v_financial_entry_id uuid;
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
     or v_subscription.contract_accepted_at is null
     or v_subscription.upfront_payment then
    return new;
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
    raise exception using errcode = '22023', message = 'active revenue chart account is required to accept a subscription';
  end if;

  insert into public.financial_entries(
    organization_id, kind, source, description, issue_date, competence_date, due_date, total_cents,
    currency, chart_account_id, counterparty_kind, customer_id, subscription_cycle_id
  ) values (
    new.organization_id, 'REVENUE', 'SUBSCRIPTION',
    format('Assinatura contratada · Parcela %s · Contrato nº %s', new.cycle_number, v_subscription.contract_number),
    least(current_date, new.due_on), least(current_date, new.due_on), new.due_on, new.amount_cents,
    'BRL', v_chart_account_id, 'CUSTOMER', v_subscription.customer_id, new.id
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
       and entry.subscription_cycle_id = new.id
       and entry.source = 'SUBSCRIPTION'
       and entry.canceled_at is null
     order by entry.created_at desc
     limit 1;
  end if;
  if v_financial_entry_id is not null then
    update public.customer_subscription_cycles
       set financial_entry_id = v_financial_entry_id
     where id = new.id
       and organization_id = new.organization_id
       and financial_entry_id is distinct from v_financial_entry_id;
  end if;
  return new;
end;
$$;

revoke all on function public.create_subscription_cycle_receivable()
  from public, anon, authenticated;

create or replace function public.guard_provisional_subscription_payment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contract_accepted_at timestamptz;
begin
  select subscription.contract_accepted_at
    into v_contract_accepted_at
    from public.customer_subscriptions subscription
   where subscription.id = new.subscription_id
     and subscription.organization_id = new.organization_id
   for update;
  if v_contract_accepted_at is null then
    raise exception using errcode = '22023', message = 'customer must accept the subscription contract before payment';
  end if;
  return new;
end;
$$;

revoke all on function public.guard_provisional_subscription_payment()
  from public, anon, authenticated;
drop trigger if exists subscription_payment_requires_customer_acceptance on public.subscription_payments;
create trigger subscription_payment_requires_customer_acceptance
  before insert on public.subscription_payments
  for each row execute function public.guard_provisional_subscription_payment();

-- Managers may reserve sessions during provisional activation; customers cannot book them.
create or replace function public.guard_provisional_subscription_booking()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subscription public.customer_subscriptions%rowtype;
begin
  if new.status <> 'SCHEDULED' then
    return new;
  end if;
  select subscription.*
    into v_subscription
    from public.customer_subscriptions subscription
   where subscription.id = new.subscription_id
     and subscription.organization_id = new.organization_id;
  if v_subscription.manager_activated_provisionally_at is not null
     and v_subscription.contract_accepted_at is null
     and not public.is_organization_owner(new.organization_id) then
    raise exception using errcode = '42501', message = 'customer must accept the subscription contract before booking';
  end if;
  return new;
end;
$$;

revoke all on function public.guard_provisional_subscription_booking()
  from public, anon, authenticated;
drop trigger if exists provisional_subscription_booking_guard on public.customer_subscription_sessions;
create trigger provisional_subscription_booking_guard
  before insert or update of status on public.customer_subscription_sessions
  for each row execute function public.guard_provisional_subscription_booking();

-- Reuse the established acceptance flow for regular offers. A provisional offer
-- already has its cycles, so acceptance only records consent and opens billing.
alter function public.accept_customer_subscription_offer(uuid, uuid)
  rename to accept_customer_subscription_offer_before_provisional_activation;
revoke all on function public.accept_customer_subscription_offer_before_provisional_activation(uuid, uuid)
  from public, anon, authenticated, service_role;

create function public.accept_customer_subscription_offer(
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
  select *
    into strict v_sub
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
       set contract_accepted_at = now(),
           contract_accepted_by = auth.uid(),
           updated_at = now()
     where id = v_sub.id
       and organization_id = p_organization_id
    returning * into v_sub;

    insert into public.subscription_contract_acceptances(
      organization_id, subscription_id, contract_version, accepted_by, acceptance_source
    ) values (
      p_organization_id, v_sub.id, v_sub.contract_version, auth.uid(), 'CLIENT'
    ) on conflict (subscription_id, contract_version) do nothing;

    if v_sub.upfront_payment then
      update public.customer_subscription_cycles
         set status = 'PAID',
             paid_at = coalesce(paid_at, now())
       where organization_id = p_organization_id
         and subscription_id = v_sub.id
         and status in ('OPEN', 'OVERDUE');
    else
      update public.customer_subscription_cycles
         set status = status
       where organization_id = p_organization_id
         and subscription_id = v_sub.id
         and status in ('OPEN', 'OVERDUE');
    end if;

    insert into public.subscription_events(
      organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata
    ) values (
      p_organization_id,
      v_sub.id,
      'CLIENT_ACCEPTED_AFTER_PROVISIONAL_ACTIVATION',
      auth.uid(),
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
        on plan.id = v_sub.plan_id
       and plan.organization_id = p_organization_id
     where customer.id = v_sub.customer_id
       and customer.organization_id = p_organization_id;

    for v_owner in
      select membership.user_id
        from public.organization_memberships membership
       where membership.organization_id = p_organization_id
         and membership.active
         and membership.role = 'OWNER'
    loop
      insert into public.manager_notifications(
        organization_id, recipient_user_id, customer_id, subscription_id,
        kind, title, body, href
      ) values (
        p_organization_id,
        v_owner,
        v_sub.customer_id,
        v_sub.id,
        'SUBSCRIPTION_OFFER_ACCEPTED',
        'Plano aceito pelo cliente',
        coalesce(v_customer_name, 'O cliente') || ' aceitou o plano ' || coalesce(v_plan_name, 'de assinatura') || '.',
        '/gestor/clientes?cliente=' || v_sub.customer_id::text || '&aba=agendamentos'
      ) on conflict do nothing;
    end loop;

    return v_sub;
  end if;

  return public.accept_customer_subscription_offer_before_provisional_activation(
    p_organization_id, p_subscription_id
  );
end;
$$;

revoke all on function public.accept_customer_subscription_offer(uuid, uuid)
  from public, anon;
grant execute on function public.accept_customer_subscription_offer(uuid, uuid)
  to authenticated;

create or replace function public.decline_customer_subscription_offer(
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
  v_customer public.customers%rowtype;
  v_plan public.subscription_plans%rowtype;
  v_owner uuid;
  v_appointment_id uuid;
  v_today date;
  v_provisional boolean := false;
  v_canceled_appointments integer := 0;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'authenticated client required';
  end if;

  select *
    into strict v_sub
    from public.customer_subscriptions
   where id = p_subscription_id
     and organization_id = p_organization_id
   for update;

  if not public.is_organization_customer(p_organization_id, v_sub.customer_id) then
    raise exception using errcode = '42501', message = 'subscription offer decline denied';
  end if;
  if v_sub.status = 'DECLINED' and v_sub.declined_by = auth.uid() then
    return v_sub;
  end if;

  if v_sub.contract_accepted_at is not null
     or v_sub.created_by is null
     or v_sub.created_by = auth.uid()
     or not exists (
       select 1
         from public.organization_memberships membership
        where membership.organization_id = p_organization_id
          and membership.user_id = v_sub.created_by
          and membership.active
          and membership.role = 'OWNER'
     ) then
    raise exception using errcode = '22023', message = 'subscription offer is not awaiting customer decision';
  end if;

  v_provisional := v_sub.status = 'ACTIVE'
    and v_sub.manager_activated_provisionally_at is not null;
  if not v_provisional and v_sub.status <> 'REQUESTED' then
    raise exception using errcode = '22023', message = 'subscription offer is not awaiting customer decision';
  end if;

  if v_provisional then
    select (now() at time zone organization.timezone)::date
      into strict v_today
      from public.organizations organization
     where organization.id = p_organization_id;

    for v_appointment_id in
      select appointment.id
        from public.customer_subscription_sessions session
        join public.appointments appointment
          on appointment.id = session.appointment_id
         and appointment.organization_id = session.organization_id
       where session.organization_id = p_organization_id
         and session.subscription_id = v_sub.id
         and session.status = 'SCHEDULED'
         and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED')
         and lower(appointment.service_period) > now()
       order by lower(appointment.service_period), appointment.id
       for update of appointment
    loop
      perform public.cancel_appointment(
        v_appointment_id,
        'subscription_offer_declined',
        true
      );
      v_canceled_appointments := v_canceled_appointments + 1;
    end loop;

    update public.customer_subscription_sessions session
       set status = 'CANCELED',
           canceled_at = coalesce(session.canceled_at, now())
     where session.organization_id = p_organization_id
       and session.subscription_id = v_sub.id
       and (
         (session.status = 'AVAILABLE' and session.available_until >= v_today)
         or (
           session.status = 'SCHEDULED'
           and exists (
             select 1
               from public.appointments appointment
              where appointment.id = session.appointment_id
                and appointment.organization_id = p_organization_id
                and appointment.status = 'CANCELED'
                and lower(appointment.service_period) > now()
           )
         )
       );

    update public.customer_subscription_cycles cycle
       set status = 'CANCELED',
           canceled_at = coalesce(cycle.canceled_at, now())
     where cycle.organization_id = p_organization_id
       and cycle.subscription_id = v_sub.id
       and cycle.status in ('OPEN', 'OVERDUE');
  end if;

  update public.customer_subscriptions
     set status = 'DECLINED',
         declined_at = now(),
         declined_by = auth.uid(),
         updated_at = now()
   where id = v_sub.id
     and organization_id = p_organization_id
  returning * into v_sub;

  insert into public.subscription_events(
    organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata
  ) values (
    p_organization_id,
    v_sub.id,
    'DECLINED',
    auth.uid(),
    'declined-client:' || v_sub.id,
    jsonb_build_object(
      'source', 'CLIENT_APP',
      'after_provisional_activation', v_provisional,
      'canceled_future_appointments', v_canceled_appointments
    )
  ) on conflict (organization_id, idempotency_key) do nothing;

  update public.customer_in_app_notifications
     set read_at = coalesce(read_at, now())
   where organization_id = p_organization_id
     and customer_id = v_sub.customer_id
     and subscription_id = v_sub.id;

  select *
    into v_customer
    from public.customers
   where id = v_sub.customer_id
     and organization_id = p_organization_id;
  select *
    into v_plan
    from public.subscription_plans
   where id = v_sub.plan_id
     and organization_id = p_organization_id;

  for v_owner in
    select membership.user_id
      from public.organization_memberships membership
     where membership.organization_id = p_organization_id
       and membership.active
       and membership.role = 'OWNER'
  loop
    insert into public.manager_notifications(
      organization_id, recipient_user_id, customer_id, subscription_id,
      kind, title, body, href
    ) values (
      p_organization_id,
      v_owner,
      v_sub.customer_id,
      v_sub.id,
      'SUBSCRIPTION_OFFER_DECLINED',
      'Plano recusado pelo cliente',
      v_customer.full_name || ' recusou o plano ' || v_plan.name || '.',
      '/gestor/clientes?cliente=' || v_sub.customer_id::text || '&aba=assinaturas'
    ) on conflict do nothing;
  end loop;

  return v_sub;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription or customer not found';
end;
$$;

revoke all on function public.decline_customer_subscription_offer(uuid, uuid)
  from public, anon;
grant execute on function public.decline_customer_subscription_offer(uuid, uuid)
  to authenticated;
