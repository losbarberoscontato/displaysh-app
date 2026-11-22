-- Provision subscription bundle sessions and receivables on either client
-- acceptance or manager activation, and keep bundle finance idempotent.

create unique index if not exists financial_entries_subscription_bundle_installment_active_uidx
  on public.financial_entries (organization_id, subscription_bundle_installment_id)
  where source = 'SUBSCRIPTION'
    and subscription_bundle_installment_id is not null
    and canceled_at is null;

create or replace function public.create_subscription_bundle_installment_receivable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_chart_account_id uuid;
  v_entry_id uuid;
begin
  if new.status not in ('OPEN', 'OVERDUE') or new.financial_entry_id is not null then
    return new;
  end if;

  select * into v_sub
    from public.customer_subscriptions
   where id = new.subscription_id and organization_id = new.organization_id;
  if not found or v_sub.status not in ('ACTIVE', 'PENDING_PAYMENT')
     or (v_sub.contract_accepted_at is null and v_sub.manager_activated_provisionally_at is null) then
    return new;
  end if;

  select account.id into v_chart_account_id
    from public.chart_of_accounts account
   where account.organization_id = new.organization_id
     and account.kind = 'REVENUE' and account.active
   order by account.created_at, account.id limit 1;
  if v_chart_account_id is null then
    raise exception using errcode = '22023',
      message = 'active revenue chart account is required to create a subscription receivable';
  end if;

  insert into public.financial_entries(
    organization_id, kind, source, description, issue_date, competence_date,
    due_date, total_cents, currency, chart_account_id, counterparty_kind,
    customer_id, subscription_bundle_installment_id
  ) values (
    new.organization_id, 'REVENUE', 'SUBSCRIPTION',
    case when new.kind = 'ENTRY' then 'Entrada do plano de assinatura · ' || v_sub.id
      else 'Parcela ' || new.installment_number || ' do plano de assinatura · ' || v_sub.id end,
    least(current_date, new.due_on), least(current_date, new.due_on), new.due_on,
    new.amount_cents, 'BRL', v_chart_account_id, 'CUSTOMER', v_sub.customer_id, new.id
  ) on conflict (organization_id, subscription_bundle_installment_id)
      where source = 'SUBSCRIPTION' and subscription_bundle_installment_id is not null and canceled_at is null
    do nothing
    returning id into v_entry_id;

  if v_entry_id is null then
    select entry.id into v_entry_id
      from public.financial_entries entry
     where entry.organization_id = new.organization_id
       and entry.subscription_bundle_installment_id = new.id
       and entry.source = 'SUBSCRIPTION' and entry.canceled_at is null
     order by entry.created_at desc limit 1;
  end if;
  if v_entry_id is not null then
    update public.subscription_bundle_installments
       set financial_entry_id = v_entry_id
     where id = new.id and organization_id = new.organization_id
       and financial_entry_id is distinct from v_entry_id;
  end if;
  return new;
end;
$$;
revoke all on function public.create_subscription_bundle_installment_receivable()
  from public, anon, authenticated, service_role;
drop trigger if exists subscription_bundle_installment_receivable on public.subscription_bundle_installments;
create trigger subscription_bundle_installment_receivable
  after insert or update of status on public.subscription_bundle_installments
  for each row execute function public.create_subscription_bundle_installment_receivable();

create or replace function public.cancel_subscription_bundle_installment_receivable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'CANCELED' and old.status <> 'CANCELED'
     and new.financial_entry_id is not null then
    if exists (select 1 from public.financial_settlements settlement
      where settlement.organization_id = new.organization_id
        and settlement.entry_id = new.financial_entry_id) then
      raise exception using errcode = '22023', message = 'settled subscription receivable cannot be canceled';
    end if;
    update public.financial_entries set canceled_at = now(),
      cancellation_reason = 'subscription_bundle_installment_canceled'
     where id = new.financial_entry_id and organization_id = new.organization_id and canceled_at is null;
  end if;
  return new;
end;
$$;
revoke all on function public.cancel_subscription_bundle_installment_receivable()
  from public, anon, authenticated, service_role;
drop trigger if exists subscription_bundle_installment_cancel_receivable on public.subscription_bundle_installments;
create trigger subscription_bundle_installment_cancel_receivable
  after update of status on public.subscription_bundle_installments
  for each row execute function public.cancel_subscription_bundle_installment_receivable();

-- Keep the contract installment status synchronized when Contas a receber is
-- settled outside the subscription control modal.
create or replace function public.sync_subscription_bundle_installment_from_settlement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entry public.financial_entries%rowtype;
  v_installment public.subscription_bundle_installments%rowtype;
  v_net_settled bigint;
  v_paid_on date;
  v_timezone text;
  v_today date;
begin
  select * into v_entry
    from public.financial_entries entry
   where entry.id = new.entry_id and entry.organization_id = new.organization_id
     and entry.source = 'SUBSCRIPTION' and entry.subscription_bundle_installment_id is not null
   for update;
  if not found then return new; end if;

  select * into v_installment
    from public.subscription_bundle_installments installment
   where installment.id = v_entry.subscription_bundle_installment_id
     and installment.organization_id = v_entry.organization_id
   for update;
  if not found then return new; end if;

  select coalesce(sum(case when settlement.kind = 'SETTLEMENT' then settlement.amount_cents
      else -settlement.amount_cents end), 0)::bigint
    into v_net_settled
    from public.financial_settlements settlement
   where settlement.organization_id = v_entry.organization_id and settlement.entry_id = v_entry.id;

  if v_net_settled >= v_entry.total_cents and v_entry.canceled_at is null then
    select max(settlement.settled_on) into v_paid_on
      from public.financial_settlements settlement
     where settlement.organization_id = v_entry.organization_id and settlement.entry_id = v_entry.id
       and settlement.kind = 'SETTLEMENT';
    select organization.timezone into strict v_timezone
      from public.organizations organization where organization.id = v_entry.organization_id;
    update public.subscription_bundle_installments
       set status = 'PAID',
           paid_at = coalesce(v_installment.paid_at, v_paid_on::timestamp at time zone v_timezone)
     where id = v_installment.id and organization_id = v_installment.organization_id
       and v_installment.status <> 'CANCELED';
  elsif v_installment.status = 'PAID' then
    select organization.timezone into strict v_timezone
      from public.organizations organization where organization.id = v_entry.organization_id;
    v_today := (now() at time zone v_timezone)::date;
    update public.subscription_bundle_installments
       set status = case when due_on < v_today then 'OVERDUE' else 'OPEN' end,
           paid_at = null
     where id = v_installment.id and organization_id = v_installment.organization_id;
  end if;
  return new;
end;
$$;
revoke all on function public.sync_subscription_bundle_installment_from_settlement()
  from public, anon, authenticated, service_role;
drop trigger if exists subscription_bundle_installment_settlement_sync on public.financial_settlements;
create trigger subscription_bundle_installment_settlement_sync
  after insert on public.financial_settlements
  for each row execute function public.sync_subscription_bundle_installment_from_settlement();

-- Repair open bundle installments that were created before receivable linking existed.
update public.subscription_bundle_installments installment
   set status = installment.status
  from public.customer_subscriptions subscription
 where subscription.id = installment.subscription_id
   and subscription.organization_id = installment.organization_id
   and subscription.status in ('ACTIVE', 'PENDING_PAYMENT')
   and (subscription.contract_accepted_at is not null
     or subscription.manager_activated_provisionally_at is not null)
   and installment.status in ('OPEN', 'OVERDUE')
   and installment.financial_entry_id is null
   and exists (select 1 from public.chart_of_accounts account
     where account.organization_id = installment.organization_id
       and account.kind = 'REVENUE' and account.active);

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
      v_month_capacity := greatest(public.subscription_bundle_weeks_in_month(v_month), 1) * v_contract.sessions_per_week;
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
    v_version_end := (v_contract.first_session_date
      + make_interval(days => ceil(v_contract.total_sessions::numeric / v_contract.sessions_per_week)::integer * 7))::date;
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

alter function public.manager_activate_customer_subscription_without_acceptance(uuid, uuid)
  rename to manager_activate_subscription_before_bundle_control;
revoke all on function public.manager_activate_subscription_before_bundle_control(uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function public.manager_activate_customer_subscription_without_acceptance(
  p_organization_id uuid, p_subscription_id uuid
)
returns public.customer_subscriptions
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_today date;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription provisional activation denied';
  end if;
  select * into strict v_sub from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id for update;
  select * into strict v_version from public.subscription_plan_versions
   where id = v_sub.plan_version_id and organization_id = p_organization_id;
  if v_version.model <> 'SESSION_BUNDLE_V1' then
    return public.manager_activate_subscription_before_bundle_control(p_organization_id, p_subscription_id);
  end if;
  if v_sub.status = 'ACTIVE' and v_sub.manager_activated_provisionally_at is not null
     and v_sub.contract_accepted_at is null then
    perform public.provision_subscription_bundle_contract(p_organization_id, v_sub.id, auth.uid());
    return v_sub;
  end if;
  if v_sub.status <> 'REQUESTED' or v_sub.contract_accepted_at is not null
     or v_sub.created_by is null
     or not exists (select 1 from public.organization_memberships membership
       where membership.organization_id = p_organization_id and membership.user_id = v_sub.created_by
         and membership.active and membership.role = 'OWNER') then
    raise exception using errcode = '22023', message = 'subscription offer is not eligible for provisional activation';
  end if;
  if not public.organization_module_enabled(p_organization_id, 'subscription_plans') then
    raise exception using errcode = '42501', message = 'subscription module disabled';
  end if;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_sub.id and organization_id = p_organization_id for update;
  select (now() at time zone organization.timezone)::date into strict v_today
    from public.organizations organization where organization.id = p_organization_id;
  if v_contract.first_session_date < v_today or v_contract.first_installment_due_on < v_today
     or (v_contract.entry_cents > 0 and v_contract.entry_due_on < v_today) then
    raise exception using errcode = '22023', message = 'subscription offer dates have expired; update the offer before activation';
  end if;
  update public.customer_subscriptions set status = 'ACTIVE', start_date = v_contract.first_session_date,
    first_due_date = v_contract.first_installment_due_on,
    due_day = extract(day from v_contract.first_installment_due_on)::smallint,
    manager_activated_provisionally_at = now(), manager_activated_provisionally_by = auth.uid(), updated_at = now()
   where id = v_sub.id and organization_id = p_organization_id returning * into v_sub;
  perform public.provision_subscription_bundle_contract(p_organization_id, v_sub.id, auth.uid());
  insert into public.subscription_events(
    organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata
  ) values (p_organization_id, v_sub.id, 'MANAGER_ACTIVATED_PENDING_CONSENT', auth.uid(),
    'manager-provisional-activation:' || v_sub.id,
    jsonb_build_object('contract_accepted', false, 'source', 'MANAGER', 'model', 'SESSION_BUNDLE_V1'))
  on conflict (organization_id, idempotency_key) do nothing;
  return v_sub;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription or plan not found';
end;
$$;
revoke all on function public.manager_activate_customer_subscription_without_acceptance(uuid, uuid)
  from public, anon;
grant execute on function public.manager_activate_customer_subscription_without_acceptance(uuid, uuid)
  to authenticated;

alter function public.accept_customer_subscription_offer(uuid, uuid)
  rename to accept_customer_subscription_offer_before_bundle_control;
revoke all on function public.accept_customer_subscription_offer_before_bundle_control(uuid, uuid)
  from public, anon, authenticated;

create or replace function public.accept_customer_subscription_offer(
  p_organization_id uuid, p_subscription_id uuid
)
returns public.customer_subscriptions
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_today date;
  v_was_provisional boolean;
begin
  select * into strict v_sub from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id for update;
  if not public.is_organization_customer(p_organization_id, v_sub.customer_id) then
    raise exception using errcode = '42501', message = 'subscription offer acceptance denied';
  end if;
  select * into strict v_version from public.subscription_plan_versions
   where id = v_sub.plan_version_id and organization_id = p_organization_id;
  if v_version.model <> 'SESSION_BUNDLE_V1' then
    return public.accept_customer_subscription_offer_before_bundle_control(p_organization_id, p_subscription_id);
  end if;
  if v_sub.status = 'ACTIVE' and v_sub.contract_accepted_at is not null then
    perform public.provision_subscription_bundle_contract(p_organization_id, v_sub.id, auth.uid());
    return v_sub;
  end if;
  v_was_provisional := v_sub.status = 'ACTIVE'
    and v_sub.manager_activated_provisionally_at is not null
    and v_sub.contract_accepted_at is null;
  if not v_was_provisional and (v_sub.status <> 'REQUESTED' or v_sub.contract_accepted_at is not null) then
    raise exception using errcode = '22023', message = 'subscription bundle offer is not awaiting acceptance';
  end if;
  if not public.organization_module_enabled(p_organization_id, 'subscription_plans') then
    raise exception using errcode = '42501', message = 'subscription module disabled';
  end if;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_sub.id and organization_id = p_organization_id for update;
  select (now() at time zone organization.timezone)::date into strict v_today
    from public.organizations organization where organization.id = p_organization_id;
  if not v_was_provisional and (v_contract.first_session_date < v_today or v_contract.first_installment_due_on < v_today
     or (v_contract.entry_cents > 0 and v_contract.entry_due_on < v_today)) then
    raise exception using errcode = '22023', message = 'subscription offer dates have expired; ask the manager to update the offer';
  end if;
  perform set_config('app.subscription_bundle_accept', '1', true);
  update public.customer_subscriptions set status = 'ACTIVE', contract_accepted_at = now(),
    contract_accepted_by = auth.uid(), start_date = v_contract.first_session_date,
    first_due_date = v_contract.first_installment_due_on,
    due_day = extract(day from v_contract.first_installment_due_on)::smallint, updated_at = now()
   where id = v_sub.id and organization_id = p_organization_id returning * into v_sub;
  update public.subscription_bundle_contracts set accepted_at = now()
   where id = v_contract.id and organization_id = p_organization_id;
  insert into public.subscription_contract_acceptances(
    organization_id, subscription_id, contract_version, accepted_by, acceptance_source, metadata
  ) values (p_organization_id, v_sub.id, v_sub.contract_version, auth.uid(), 'CLIENT',
    jsonb_build_object('model', 'SESSION_BUNDLE_V1', 'accepted_at', now()))
  on conflict (subscription_id, contract_version) do nothing;
  update public.customer_in_app_notifications set read_at = coalesce(read_at, now())
   where organization_id = p_organization_id and customer_id = v_sub.customer_id
     and subscription_id = v_sub.id;
  perform public.provision_subscription_bundle_contract(p_organization_id, v_sub.id, auth.uid());
  insert into public.subscription_events(
    organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata
  ) values (p_organization_id, v_sub.id, 'BUNDLE_ACCEPTED', auth.uid(),
    'bundle-accepted:' || v_sub.id,
    jsonb_build_object('model', 'SESSION_BUNDLE_V1', 'after_provisional_activation', v_was_provisional))
  on conflict (organization_id, idempotency_key) do nothing;
  return v_sub;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle offer not found';
end;
$$;
revoke all on function public.accept_customer_subscription_offer(uuid, uuid) from public, anon;
grant execute on function public.accept_customer_subscription_offer(uuid, uuid) to authenticated;

create or replace function public.record_subscription_bundle_payment(
  p_organization_id uuid, p_installment_id uuid, p_amount_cents bigint,
  p_chart_account_id uuid, p_financial_account_id uuid default null,
  p_idempotency_key text default null, p_external_reference text default null,
  p_paid_on date default current_date
)
returns public.subscription_bundle_payments
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_installment public.subscription_bundle_installments%rowtype;
  v_sub public.customer_subscriptions%rowtype;
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
  if char_length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 200 then
    raise exception using errcode = '22023', message = 'payment idempotency key is required';
  end if;
  select * into v_payment from public.subscription_bundle_payments
   where organization_id = p_organization_id and idempotency_key = p_idempotency_key;
  if found then
    if v_payment.installment_id = p_installment_id then return v_payment; end if;
    raise exception using errcode = '23505', message = 'subscription bundle payment idempotency key was already used';
  end if;
  select * into strict v_sub from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id for update;
  select installment.financial_entry_id into v_entry_id
    from public.subscription_bundle_installments installment
   where installment.id = p_installment_id and installment.subscription_id = v_sub.id
     and installment.organization_id = p_organization_id;
  if not found or v_entry_id is null then
    raise exception using errcode = '22023', message = 'subscription receivable has not been generated';
  end if;
  perform 1 from public.financial_entries entry
   where entry.id = v_entry_id and entry.organization_id = p_organization_id
     and entry.source = 'SUBSCRIPTION' and entry.canceled_at is null for update;
  if not found then raise exception using errcode = '22023', message = 'active subscription receivable has not been generated'; end if;
  select * into strict v_installment from public.subscription_bundle_installments
   where id = p_installment_id and subscription_id = v_sub.id
     and organization_id = p_organization_id for update;
  if v_installment.status = 'PAID' then
    select * into v_payment from public.subscription_bundle_payments
     where installment_id = v_installment.id and organization_id = p_organization_id;
    if found then return v_payment; end if;
    raise exception using errcode = '22023', message = 'subscription installment is already settled in Finance';
  end if;
  if v_installment.status not in ('OPEN', 'OVERDUE') or v_sub.status not in ('ACTIVE', 'CANCELED', 'EXPIRED') then
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
    select 1 from public.chart_of_accounts account where account.id = p_chart_account_id
      and account.organization_id = p_organization_id and account.active and account.kind = 'REVENUE'
  ) or p_financial_account_id is null or not exists (
    select 1 from public.financial_accounts account where account.id = p_financial_account_id
      and account.organization_id = p_organization_id and account.active
  ) then
    raise exception using errcode = '22023', message = 'subscription bundle payment account is inactive';
  end if;
  v_financial_method := case v_installment.payment_method::text
    when 'PIX' then 'PIX'::public.financial_payment_method
    when 'CARD' then 'CARD'::public.financial_payment_method
    when 'BOLETO' then 'BOLETO'::public.financial_payment_method
    when 'CASH' then 'CASH'::public.financial_payment_method
    else 'OTHER'::public.financial_payment_method end;
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
  ) values (p_organization_id, v_sub.id, v_installment.id, v_installment.amount_cents,
    v_installment.payment_method, v_entry_id, btrim(p_idempotency_key),
    nullif(btrim(coalesce(p_external_reference, '')), ''), v_paid_at, auth.uid())
  on conflict (installment_id) do nothing
  returning * into v_payment;
  if not found then
    select * into strict v_payment from public.subscription_bundle_payments
     where installment_id = v_installment.id and organization_id = p_organization_id;
  end if;
  update public.subscription_bundle_installments set status = 'PAID', paid_at = v_paid_at
   where id = v_installment.id and organization_id = p_organization_id;
  return v_payment;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle installment or account not found';
end;
$$;
revoke all on function public.record_subscription_bundle_payment(uuid,uuid,bigint,uuid,uuid,text,text,date) from public, anon;
grant execute on function public.record_subscription_bundle_payment(uuid,uuid,bigint,uuid,uuid,text,text,date) to authenticated;

create or replace function public.update_subscription_bundle_installment(
  p_organization_id uuid, p_subscription_id uuid, p_installment_id uuid,
  p_amount_cents bigint, p_due_on date
)
returns public.subscription_bundle_installments
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_row public.subscription_bundle_installments%rowtype; v_entry_id uuid;
begin
  if not public.is_organization_owner(p_organization_id) then raise exception using errcode = '42501', message = 'subscription installment update denied'; end if;
  if p_amount_cents <= 0 or p_due_on is null then raise exception using errcode = '22023', message = 'positive installment amount and due date are required'; end if;
  select installment.financial_entry_id into v_entry_id from public.subscription_bundle_installments installment
   where installment.id = p_installment_id and installment.subscription_id = p_subscription_id and installment.organization_id = p_organization_id;
  if not found or v_entry_id is null then raise exception using errcode = '22023', message = 'active subscription receivable has not been generated'; end if;
  perform 1 from public.financial_entries entry where entry.id = v_entry_id
   and entry.organization_id = p_organization_id and entry.canceled_at is null for update;
  if not found then raise exception using errcode = '22023', message = 'active subscription receivable has not been generated'; end if;
  select * into strict v_row from public.subscription_bundle_installments
   where id = p_installment_id and subscription_id = p_subscription_id and organization_id = p_organization_id for update;
  if v_row.financial_entry_id is distinct from v_entry_id then raise exception using errcode = '40001', message = 'subscription installment changed during update; retry'; end if;
  if v_row.status not in ('OPEN', 'OVERDUE') then raise exception using errcode = '22023', message = 'only open installments can be edited'; end if;
  if exists (select 1 from public.subscription_bundle_payments payment where payment.installment_id = v_row.id)
     or (v_row.financial_entry_id is not null and exists (select 1 from public.financial_settlements settlement where settlement.entry_id = v_row.financial_entry_id)) then
    raise exception using errcode = '22023', message = 'settled installment cannot be edited';
  end if;
  if v_row.financial_entry_id is null or not exists (select 1 from public.financial_entries entry
    where entry.id = v_row.financial_entry_id and entry.organization_id = p_organization_id and entry.canceled_at is null) then
    raise exception using errcode = '22023', message = 'active subscription receivable has not been generated';
  end if;
  update public.financial_entries set total_cents = p_amount_cents, due_date = p_due_on
   where id = v_row.financial_entry_id and organization_id = p_organization_id and canceled_at is null;
  update public.subscription_bundle_installments set amount_cents = p_amount_cents, due_on = p_due_on
   where id = v_row.id and organization_id = p_organization_id returning * into v_row;
  insert into public.subscription_events(organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata)
  values (p_organization_id, p_subscription_id, 'BUNDLE_INSTALLMENT_UPDATED', auth.uid(),
    'bundle-installment-updated:' || v_row.id || ':' || gen_random_uuid(),
    jsonb_build_object('installment_id', v_row.id, 'amount_cents', p_amount_cents, 'due_on', p_due_on));
  return v_row;
exception when no_data_found then raise exception using errcode = 'P0002', message = 'subscription installment not found';
end;
$$;
revoke all on function public.update_subscription_bundle_installment(uuid,uuid,uuid,bigint,date) from public, anon;
grant execute on function public.update_subscription_bundle_installment(uuid,uuid,uuid,bigint,date) to authenticated;

create or replace function public.cancel_subscription_bundle_installment(
  p_organization_id uuid, p_subscription_id uuid, p_installment_id uuid
)
returns public.subscription_bundle_installments
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_row public.subscription_bundle_installments%rowtype;
        v_entry_id uuid;
begin
  if not public.is_organization_owner(p_organization_id) then raise exception using errcode = '42501', message = 'subscription installment cancellation denied'; end if;
  select installment.financial_entry_id into v_entry_id from public.subscription_bundle_installments installment
   where installment.id = p_installment_id and installment.subscription_id = p_subscription_id and installment.organization_id = p_organization_id;
  if not found or v_entry_id is null then raise exception using errcode = '22023', message = 'subscription receivable has not been generated'; end if;
  perform 1 from public.financial_entries entry where entry.id = v_entry_id
   and entry.organization_id = p_organization_id and entry.canceled_at is null for update;
  if not found then raise exception using errcode = '22023', message = 'active subscription receivable has not been generated'; end if;
  select * into strict v_row from public.subscription_bundle_installments
   where id = p_installment_id and subscription_id = p_subscription_id and organization_id = p_organization_id for update;
  if v_row.financial_entry_id is distinct from v_entry_id then raise exception using errcode = '40001', message = 'subscription installment changed during cancellation; retry'; end if;
  if v_row.status not in ('OPEN', 'OVERDUE') then raise exception using errcode = '22023', message = 'only open installments can be canceled'; end if;
  if exists (select 1 from public.subscription_bundle_payments payment where payment.installment_id = v_row.id)
     or (v_row.financial_entry_id is not null and exists (select 1 from public.financial_settlements settlement where settlement.entry_id = v_row.financial_entry_id)) then
    raise exception using errcode = '22023', message = 'settled installment cannot be canceled';
  end if;
  update public.subscription_bundle_installments set status = 'CANCELED'
   where id = v_row.id and organization_id = p_organization_id returning * into v_row;
  insert into public.subscription_events(organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata)
  values (p_organization_id, p_subscription_id, 'BUNDLE_INSTALLMENT_CANCELED', auth.uid(),
    'bundle-installment-canceled:' || v_row.id,
    jsonb_build_object('installment_id', v_row.id, 'amount_cents', v_row.amount_cents, 'due_on', v_row.due_on))
  on conflict (organization_id, idempotency_key) do nothing;
  return v_row;
exception when no_data_found then raise exception using errcode = 'P0002', message = 'subscription installment not found';
end;
$$;
revoke all on function public.cancel_subscription_bundle_installment(uuid,uuid,uuid) from public, anon;
grant execute on function public.cancel_subscription_bundle_installment(uuid,uuid,uuid) to authenticated;

create or replace function public.update_open_subscription_cycle(
  p_organization_id uuid, p_subscription_id uuid, p_cycle_id uuid,
  p_amount_cents bigint, p_due_on date
)
returns public.customer_subscription_cycles
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cycle public.customer_subscription_cycles%rowtype;
begin
  if not public.is_organization_owner(p_organization_id) then raise exception using errcode = '42501', message = 'subscription cycle update denied'; end if;
  if p_amount_cents <= 0 or p_due_on is null then raise exception using errcode = '22023', message = 'positive cycle amount and due date are required'; end if;
  select * into strict v_cycle from public.customer_subscription_cycles
   where id = p_cycle_id and subscription_id = p_subscription_id and organization_id = p_organization_id for update;
  if v_cycle.status not in ('OPEN', 'OVERDUE') then raise exception using errcode = '22023', message = 'only open subscription cycles can be edited'; end if;
  if exists (select 1 from public.subscription_payments payment where payment.cycle_id = v_cycle.id)
     or (v_cycle.financial_entry_id is not null and exists (select 1 from public.financial_settlements settlement where settlement.entry_id = v_cycle.financial_entry_id)) then
    raise exception using errcode = '22023', message = 'settled subscription cycle cannot be edited';
  end if;
  if v_cycle.financial_entry_id is null or not exists (select 1 from public.financial_entries entry
    where entry.id = v_cycle.financial_entry_id and entry.organization_id = p_organization_id and entry.canceled_at is null) then
    raise exception using errcode = '22023', message = 'active subscription receivable has not been generated';
  end if;
  update public.financial_entries set total_cents = p_amount_cents, due_date = p_due_on
   where id = v_cycle.financial_entry_id and organization_id = p_organization_id and canceled_at is null;
  update public.customer_subscription_cycles set amount_cents = p_amount_cents, due_on = p_due_on
   where id = v_cycle.id and organization_id = p_organization_id returning * into v_cycle;
  insert into public.subscription_events(organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata)
  values (p_organization_id, p_subscription_id, 'SUBSCRIPTION_CYCLE_UPDATED', auth.uid(),
    'subscription-cycle-updated:' || v_cycle.id || ':' || gen_random_uuid(),
    jsonb_build_object('cycle_id', v_cycle.id, 'amount_cents', p_amount_cents, 'due_on', p_due_on));
  return v_cycle;
exception when no_data_found then raise exception using errcode = 'P0002', message = 'subscription cycle not found';
end;
$$;
revoke all on function public.update_open_subscription_cycle(uuid,uuid,uuid,bigint,date) from public, anon;
grant execute on function public.update_open_subscription_cycle(uuid,uuid,uuid,bigint,date) to authenticated;

alter function public.decline_customer_subscription_offer(uuid, uuid)
  rename to decline_customer_subscription_offer_before_bundle_control;
revoke all on function public.decline_customer_subscription_offer_before_bundle_control(uuid, uuid)
  from public, anon, authenticated;

create or replace function public.decline_customer_subscription_offer(
  p_organization_id uuid, p_subscription_id uuid
)
returns public.customer_subscriptions
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_customer public.customers%rowtype;
  v_plan public.subscription_plans%rowtype;
  v_owner uuid;
  v_appointment_id uuid;
  v_provisional boolean;
  v_canceled_uncompleted_appointments integer := 0;
  v_installment record;
begin
  select * into strict v_sub from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id for update;
  select * into strict v_version from public.subscription_plan_versions
   where id = v_sub.plan_version_id and organization_id = p_organization_id;
  if v_version.model <> 'SESSION_BUNDLE_V1' then
    v_sub := public.decline_customer_subscription_offer_before_bundle_control(p_organization_id, p_subscription_id);
    return v_sub;
  end if;
  if not public.is_organization_customer(p_organization_id, v_sub.customer_id) then
    raise exception using errcode = '42501', message = 'subscription offer decline denied';
  end if;
  if v_sub.status = 'DECLINED' and v_sub.declined_by = auth.uid() then return v_sub; end if;
  if v_sub.contract_accepted_at is not null or v_sub.created_by is null
     or v_sub.created_by = auth.uid() or not exists (
       select 1 from public.organization_memberships membership
        where membership.organization_id = p_organization_id and membership.user_id = v_sub.created_by
          and membership.active and membership.role = 'OWNER') then
    raise exception using errcode = '22023', message = 'subscription offer is not awaiting customer decision';
  end if;
  v_provisional := v_sub.status = 'ACTIVE' and v_sub.manager_activated_provisionally_at is not null;
  if not v_provisional and v_sub.status <> 'REQUESTED' then
    raise exception using errcode = '22023', message = 'subscription offer is not awaiting customer decision';
  end if;
  if v_provisional then
    for v_appointment_id in
      select appointment.id from public.subscription_bundle_sessions session
      join public.appointments appointment on appointment.id = session.appointment_id
        and appointment.organization_id = session.organization_id
      where session.organization_id = p_organization_id and session.subscription_id = v_sub.id
        and session.status = 'SCHEDULED' and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED')
      order by lower(appointment.service_period), appointment.id for update of appointment
    loop
      perform public.cancel_appointment(v_appointment_id, 'subscription_offer_declined', true);
      v_canceled_uncompleted_appointments := v_canceled_uncompleted_appointments + 1;
    end loop;
    update public.subscription_bundle_sessions session set status = 'CANCELED', canceled_at = coalesce(session.canceled_at, now())
     where session.organization_id = p_organization_id and session.subscription_id = v_sub.id
       and session.status in ('AVAILABLE', 'SCHEDULED')
       and (session.status = 'AVAILABLE' or exists (
         select 1 from public.appointments appointment where appointment.id = session.appointment_id
           and appointment.organization_id = p_organization_id and appointment.status = 'CANCELED'
           ));
    for v_installment in select installment.id, installment.financial_entry_id from public.subscription_bundle_installments installment
      where installment.organization_id = p_organization_id and installment.subscription_id = v_sub.id
        and installment.status in ('OPEN', 'OVERDUE')
    loop
      if v_installment.financial_entry_id is not null then
        perform 1 from public.financial_entries entry where entry.id = v_installment.financial_entry_id
          and entry.organization_id = p_organization_id for update;
      end if;
      perform 1 from public.subscription_bundle_installments installment
       where installment.id = v_installment.id and installment.organization_id = p_organization_id
         and installment.subscription_id = v_sub.id and installment.status in ('OPEN', 'OVERDUE') for update;
      if not found
         or exists (select 1 from public.subscription_bundle_payments payment where payment.installment_id = v_installment.id)
         or (v_installment.financial_entry_id is not null and exists (
           select 1 from public.financial_settlements settlement where settlement.entry_id = v_installment.financial_entry_id)) then
        continue;
      end if;
      update public.subscription_bundle_installments set status = 'CANCELED'
       where id = v_installment.id and organization_id = p_organization_id;
    end loop;
  end if;
  update public.customer_subscriptions set status = 'DECLINED', declined_at = now(), declined_by = auth.uid(), updated_at = now()
   where id = v_sub.id and organization_id = p_organization_id returning * into v_sub;
  insert into public.subscription_events(organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata)
  values (p_organization_id, v_sub.id, 'DECLINED', auth.uid(), 'declined-client:' || v_sub.id,
    jsonb_build_object('source', 'CLIENT_APP', 'after_provisional_activation', v_provisional,
      'canceled_uncompleted_appointments', v_canceled_uncompleted_appointments, 'model', 'SESSION_BUNDLE_V1'))
  on conflict (organization_id, idempotency_key) do nothing;
  update public.customer_in_app_notifications set read_at = coalesce(read_at, now())
   where organization_id = p_organization_id and customer_id = v_sub.customer_id and subscription_id = v_sub.id;
  select * into v_customer from public.customers where id = v_sub.customer_id and organization_id = p_organization_id;
  select * into v_plan from public.subscription_plans where id = v_sub.plan_id and organization_id = p_organization_id;
  for v_owner in select membership.user_id from public.organization_memberships membership
    where membership.organization_id = p_organization_id and membership.active and membership.role = 'OWNER'
  loop
    insert into public.manager_notifications(organization_id, recipient_user_id, customer_id, subscription_id, kind, title, body, href)
    values (p_organization_id, v_owner, v_sub.customer_id, v_sub.id, 'SUBSCRIPTION_OFFER_DECLINED',
      'Plano recusado pelo cliente', v_customer.full_name || ' recusou o plano ' || v_plan.name || '.',
      '/gestor/clientes?cliente=' || v_sub.customer_id::text || '&aba=assinaturas')
    on conflict do nothing;
  end loop;
  return v_sub;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription or customer not found';
end;
$$;
revoke all on function public.decline_customer_subscription_offer(uuid, uuid) from public, anon;
grant execute on function public.decline_customer_subscription_offer(uuid, uuid) to authenticated;
