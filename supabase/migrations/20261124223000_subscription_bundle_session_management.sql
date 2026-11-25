alter table public.subscription_bundle_sessions
  add column substitute_barber_id uuid,
  add column rescheduled_from timestamptz,
  add column canceled_from timestamptz,
  add column cancellation_observation text,
  add column deleted_at timestamptz,
  add column deleted_by uuid references auth.users(id),
  add constraint subscription_bundle_sessions_substitute_barber_fk
    foreign key (substitute_barber_id, organization_id)
    references public.barbers(id, organization_id),
  add constraint subscription_bundle_sessions_deleted_by_check
    check ((deleted_at is null) = (deleted_by is null));

create index subscription_bundle_sessions_visible_idx
  on public.subscription_bundle_sessions (organization_id, subscription_id, session_number)
  where deleted_at is null;

update public.subscription_bundle_sessions session
   set canceled_from = lower(appointment.service_period),
       cancellation_observation = nullif(left(btrim(coalesce(event.reason, '')), 500), '')
  from public.appointments appointment
  join lateral (
    select status_event.reason
      from public.appointment_status_events status_event
     where status_event.organization_id = appointment.organization_id
       and status_event.appointment_id = appointment.id
       and status_event.to_status = 'CANCELED'
     order by status_event.created_at desc, status_event.id desc
     limit 1
  ) event on true
 where appointment.organization_id = session.organization_id
   and appointment.subscription_bundle_session_id = session.id
   and session.canceled_at is not null;

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
             when coalesce(new.cancellation_outcome::text, 'AFTER_DEADLINE') = 'ON_TIME' then 'AVAILABLE'
             else 'CONSUMED' end,
           appointment_id = case when coalesce(new.cancellation_outcome::text, 'AFTER_DEADLINE') = 'ON_TIME' then null else appointment_id end,
           scheduled_for = case when coalesce(new.cancellation_outcome::text, 'AFTER_DEADLINE') = 'ON_TIME' then null else scheduled_for end,
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

create or replace function public.capture_subscription_bundle_cancellation_observation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_appointment public.appointments%rowtype;
begin
  if new.to_status <> 'CANCELED' then return new; end if;
  select * into v_appointment
    from public.appointments appointment
   where appointment.id = new.appointment_id
     and appointment.organization_id = new.organization_id;
  if v_appointment.subscription_bundle_session_id is not null then
    update public.subscription_bundle_sessions
       set canceled_from = lower(v_appointment.service_period),
           cancellation_observation = nullif(left(btrim(coalesce(new.reason, '')), 500), '')
     where id = v_appointment.subscription_bundle_session_id
       and organization_id = new.organization_id;
  end if;
  return new;
end;
$$;
revoke all on function public.capture_subscription_bundle_cancellation_observation()
  from public, anon, authenticated, service_role;
drop trigger if exists capture_subscription_bundle_cancellation_observation
  on public.appointment_status_events;
create trigger capture_subscription_bundle_cancellation_observation
  after insert on public.appointment_status_events
  for each row execute function public.capture_subscription_bundle_cancellation_observation();

create or replace function public.manage_subscription_bundle_session(
  p_organization_id uuid,
  p_session_id uuid,
  p_action text,
  p_barber_id uuid default null,
  p_starts_at timestamptz default null,
  p_observation text default null,
  p_auxiliaries jsonb default null,
  p_confirm_late_cancel boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_session public.subscription_bundle_sessions%rowtype;
  v_subscription public.customer_subscriptions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_org public.organizations%rowtype;
  v_appointment public.appointments%rowtype;
  v_barber public.barbers%rowtype;
  v_service public.services%rowtype;
  v_period tstzrange;
  v_environment_id uuid;
  v_appointment_id uuid;
  v_original_barber_id uuid;
  v_commission_mode public.commission_mode;
  v_commission_percentage_bps integer;
  v_commission_fixed_cents bigint;
  v_occupied integer;
  v_has_active_appointment boolean := false;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization owner required';
  end if;
  if not public.organization_allows_existing_operations(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization access does not allow subscription operations';
  end if;
  if coalesce(p_action, '') not in ('EDIT', 'RESCHEDULE', 'DELETE') then
    raise exception using errcode = '22023', message = 'unsupported subscription session action';
  end if;

  select * into strict v_session
    from public.subscription_bundle_sessions
   where id = p_session_id and organization_id = p_organization_id
     and deleted_at is null
   for update;
  select * into strict v_subscription
    from public.customer_subscriptions
   where id = v_session.subscription_id and organization_id = p_organization_id
   for update;
  select * into strict v_contract
    from public.subscription_bundle_contracts
   where subscription_id = v_subscription.id and organization_id = p_organization_id;
  select * into strict v_version
    from public.subscription_plan_versions
   where id = v_subscription.plan_version_id and organization_id = p_organization_id;
  select * into strict v_org from public.organizations where id = p_organization_id;
  select * into strict v_service
    from public.services
   where id = v_version.bundle_service_id and organization_id = p_organization_id;

  if v_subscription.status not in ('ACTIVE', 'PENDING_PAYMENT') then
    raise exception using errcode = '22023', message = 'subscription does not accept session changes';
  end if;

  if v_session.appointment_id is not null then
    select * into v_appointment
      from public.appointments
     where id = v_session.appointment_id and organization_id = p_organization_id
     for update;
    v_has_active_appointment := found and v_appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE');
  end if;

  if p_action = 'DELETE' then
    if v_session.status = 'COMPLETED' or (v_appointment.id is not null and v_appointment.status in ('IN_SERVICE', 'COMPLETED', 'NO_SHOW', 'EXPIRED')) then
      raise exception using errcode = '22023', message = 'started or completed subscription session cannot be deleted';
    end if;
    if v_has_active_appointment then
      perform public.cancel_appointment(v_appointment.id, 'Sessão excluída pelo gestor', false);
    elsif v_appointment.id is not null and v_appointment.status <> 'CANCELED' then
      raise exception using errcode = '22023', message = 'subscription session appointment cannot be deleted';
    end if;
    update public.subscription_bundle_sessions
       set deleted_at = now(), deleted_by = auth.uid()
     where id = v_session.id and organization_id = p_organization_id;
    return jsonb_build_object('session_id', v_session.id, 'action', 'DELETE');
  end if;

  if p_action = 'EDIT' then
    if v_session.status = 'COMPLETED' or (v_appointment.id is not null and v_appointment.status in ('IN_SERVICE', 'COMPLETED', 'NO_SHOW', 'EXPIRED')) then
      raise exception using errcode = '22023', message = 'started or completed subscription session cannot be edited';
    end if;
    if p_observation is not null and length(p_observation) > 500 then
      raise exception using errcode = '22023', message = 'cancellation observation is too long';
    end if;
    if p_barber_id is not null then
      select * into strict v_barber from public.barbers
       where id = p_barber_id and organization_id = p_organization_id and active;
      if not exists (select 1 from public.barber_services link
          where link.organization_id = p_organization_id and link.barber_id = p_barber_id
            and link.service_id = v_service.id and link.active)
         or not exists (select 1 from public.barber_subscription_plans link
          where link.organization_id = p_organization_id and link.barber_id = p_barber_id
            and link.plan_id = v_subscription.plan_id and link.active) then
        raise exception using errcode = '22023', message = 'professional is not configured for this subscription service and plan';
      end if;
      select snapshot.mode, snapshot.percentage_bps, snapshot.fixed_cents
        into v_commission_mode, v_commission_percentage_bps, v_commission_fixed_cents
        from public.subscription_bundle_commission_snapshot(
          p_organization_id, v_subscription.plan_id, p_barber_id,
          coalesce(p_starts_at, v_session.scheduled_for, now())
        ) snapshot;
      if v_commission_mode is null then
        raise exception using errcode = '22023', message = 'professional subscription commission is not configured';
      end if;
      v_original_barber_id := coalesce(v_session.barber_id, v_appointment.barber_id, p_barber_id);
      if v_has_active_appointment then
        if v_appointment.status <> 'CONFIRMED' then
          raise exception using errcode = '22023', message = 'only confirmed appointments accept professional changes';
        end if;
        if p_barber_id is distinct from v_appointment.barber_id then
          v_period := v_appointment.service_period;
          if not public.is_barber_available(p_organization_id, p_barber_id, v_period) then
            raise exception using errcode = '23P01', message = 'professional is not available for this session';
          end if;
          v_environment_id := public.resolve_appointment_environment(
            p_organization_id, p_barber_id, v_barber.location_id, v_period, null, v_appointment.id
          );
          if v_environment_id is null then
            raise exception using errcode = '23P01', message = 'no environment is available for this professional';
          end if;
          update public.appointments
             set barber_id = p_barber_id, location_id = v_barber.location_id,
                 environment_id = v_environment_id, version = version + 1
           where id = v_appointment.id and organization_id = p_organization_id;
          insert into public.appointment_status_events(
            organization_id, appointment_id, from_status, to_status, reason, actor_user_id, metadata
          ) values (
            p_organization_id, v_appointment.id, v_appointment.status, v_appointment.status,
            'subscription_bundle_session_professional_changed', auth.uid(),
            jsonb_build_object('subscription_bundle_session_id', v_session.id, 'previous_barber_id', v_appointment.barber_id, 'barber_id', p_barber_id)
          );
        end if;
      elsif v_session.status not in ('AVAILABLE', 'CONSUMED', 'CANCELED') then
        raise exception using errcode = '22023', message = 'subscription session cannot change professional';
      end if;
      update public.subscription_bundle_sessions
         set barber_id = v_original_barber_id,
             substitute_barber_id = case when p_barber_id = v_original_barber_id then null else p_barber_id end,
             commission_mode = v_commission_mode,
             commission_percentage_bps = v_commission_percentage_bps,
             commission_fixed_cents = v_commission_fixed_cents
       where id = v_session.id and organization_id = p_organization_id;
    end if;
    update public.subscription_bundle_sessions
       set cancellation_observation = nullif(btrim(coalesce(p_observation, '')), '')
     where id = v_session.id and organization_id = p_organization_id;
    if v_has_active_appointment and p_auxiliaries is not null then
      perform public.save_appointment_auxiliaries(p_organization_id, v_appointment.id, p_auxiliaries);
    elsif p_auxiliaries is not null and jsonb_array_length(p_auxiliaries) > 0 then
      raise exception using errcode = '22023', message = 'auxiliaries require a booked session';
    end if;
    return jsonb_build_object('session_id', v_session.id, 'action', 'EDIT');
  end if;

  if p_starts_at is null or p_starts_at <= now() or p_barber_id is null then
    raise exception using errcode = '22023', message = 'future session date, time, and professional are required';
  end if;
  if v_session.status = 'COMPLETED' or (v_appointment.id is not null and v_appointment.status in ('IN_SERVICE', 'COMPLETED', 'NO_SHOW', 'EXPIRED')) then
    raise exception using errcode = '22023', message = 'started or completed subscription session cannot be rescheduled';
  end if;
  if v_session.status = 'CONSUMED' and not p_confirm_late_cancel then
    raise exception using errcode = '22023', message = 'late-canceled session requires manager confirmation';
  end if;
  select * into strict v_barber from public.barbers
   where id = p_barber_id and organization_id = p_organization_id and active;
  if not exists (select 1 from public.barber_services link
      where link.organization_id = p_organization_id and link.barber_id = p_barber_id
        and link.service_id = v_service.id and link.active)
     or not exists (select 1 from public.barber_subscription_plans link
      where link.organization_id = p_organization_id and link.barber_id = p_barber_id
        and link.plan_id = v_subscription.plan_id and link.active) then
    raise exception using errcode = '22023', message = 'professional is not configured for this subscription service and plan';
  end if;
  if extract(second from p_starts_at at time zone v_org.timezone) <> 0
     or mod(extract(minute from p_starts_at at time zone v_org.timezone)::integer, v_org.slot_interval_minutes) <> 0 then
    raise exception using errcode = '22023', message = 'start time is not aligned to the organization slot interval';
  end if;
  v_occupied := ceil(v_version.bundle_session_duration_minutes::numeric / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes;
  v_period := tstzrange(p_starts_at, p_starts_at + make_interval(mins => v_occupied), '[)');
  if public.organization_date_blocked(p_organization_id, v_period)
     or not public.is_barber_available(p_organization_id, p_barber_id, v_period)
     or exists (select 1 from public.appointments appointment
       where appointment.organization_id = p_organization_id and appointment.customer_id = v_subscription.customer_id
         and appointment.id is distinct from case when v_has_active_appointment then v_appointment.id else null end
         and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
         and appointment.service_period && v_period) then
    raise exception using errcode = '23P01', message = 'requested subscription time is no longer available';
  end if;
  v_environment_id := public.resolve_appointment_environment(
    p_organization_id, p_barber_id, v_barber.location_id, v_period, null,
    case when v_has_active_appointment then v_appointment.id else null end
  );
  if v_environment_id is null then
    raise exception using errcode = '23P01', message = 'no environment is available for this professional';
  end if;
  select snapshot.mode, snapshot.percentage_bps, snapshot.fixed_cents
    into v_commission_mode, v_commission_percentage_bps, v_commission_fixed_cents
    from public.subscription_bundle_commission_snapshot(
      p_organization_id, v_subscription.plan_id, p_barber_id, p_starts_at
    ) snapshot;
  if v_commission_mode is null then
    raise exception using errcode = '22023', message = 'professional subscription commission is not configured';
  end if;

  v_original_barber_id := coalesce(v_session.barber_id, v_appointment.barber_id, p_barber_id);
  if v_has_active_appointment then
    if v_appointment.status <> 'CONFIRMED' then
      raise exception using errcode = '22023', message = 'only confirmed appointments can be rescheduled';
    end if;
    update public.appointments
       set barber_id = p_barber_id, location_id = v_barber.location_id,
           environment_id = v_environment_id, service_period = v_period, version = version + 1
     where id = v_appointment.id and organization_id = p_organization_id;
    v_appointment_id := v_appointment.id;
    insert into public.appointment_status_events(
      organization_id, appointment_id, from_status, to_status, reason, actor_user_id, metadata
    ) values (
      p_organization_id, v_appointment_id, v_appointment.status, v_appointment.status,
      'subscription_bundle_session_rescheduled', auth.uid(),
      jsonb_build_object('subscription_bundle_session_id', v_session.id, 'previous_starts_at', lower(v_appointment.service_period), 'starts_at', p_starts_at)
    );
  else
    perform set_config('app.agenda_environment_id', v_environment_id::text, true);
    v_appointment_id := public.create_subscription_bundle_appointment(
      p_organization_id, v_subscription.customer_id, v_subscription.id, v_session.id,
      p_barber_id, v_environment_id, p_starts_at, auth.uid(), 'MANAGER'
    );
    v_original_barber_id := coalesce(v_session.barber_id, v_original_barber_id);
  end if;
  update public.subscription_bundle_sessions
     set barber_id = v_original_barber_id,
         substitute_barber_id = case when p_barber_id = v_original_barber_id then null else p_barber_id end,
         appointment_id = v_appointment_id, scheduled_for = p_starts_at,
         rescheduled_from = coalesce(rescheduled_from, scheduled_for, canceled_from),
         canceled_at = null,
         commission_mode = v_commission_mode,
         commission_percentage_bps = v_commission_percentage_bps,
         commission_fixed_cents = v_commission_fixed_cents,
         status = 'SCHEDULED'
   where id = v_session.id and organization_id = p_organization_id;
  return jsonb_build_object('session_id', v_session.id, 'appointment_id', v_appointment_id, 'action', 'RESCHEDULE');
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription bundle session not found';
end;
$$;
revoke all on function public.manage_subscription_bundle_session(uuid,uuid,text,uuid,timestamptz,text,jsonb,boolean)
  from public, anon, service_role;
grant execute on function public.manage_subscription_bundle_session(uuid,uuid,text,uuid,timestamptz,text,jsonb,boolean)
  to authenticated;

create or replace function public.add_subscription_bundle_courtesy_session(
  p_organization_id uuid,
  p_subscription_id uuid,
  p_barber_id uuid,
  p_starts_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_subscription public.customer_subscriptions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_org public.organizations%rowtype;
  v_session_id uuid;
  v_session_number integer;
  v_installment_number smallint;
  v_appointment_id uuid;
  v_barber public.barbers%rowtype;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization owner required';
  end if;
  if not public.organization_allows_existing_operations(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization access does not allow subscription operations';
  end if;
  if p_starts_at is null or p_starts_at <= now() then
    raise exception using errcode = '22023', message = 'courtesy session must be scheduled in the future';
  end if;
  select * into strict v_subscription from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id
   for update;
  if v_subscription.status not in ('ACTIVE', 'PENDING_PAYMENT') then
    raise exception using errcode = '22023', message = 'subscription does not accept courtesy sessions';
  end if;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = p_subscription_id and organization_id = p_organization_id;
  select * into strict v_version from public.subscription_plan_versions
   where id = v_subscription.plan_version_id and organization_id = p_organization_id;
  select * into strict v_org from public.organizations where id = p_organization_id;
  select * into strict v_barber from public.barbers
   where id = p_barber_id and organization_id = p_organization_id and active;
  select coalesce(max(session_number), 0) + 1 into v_session_number
    from public.subscription_bundle_sessions
   where subscription_id = p_subscription_id and organization_id = p_organization_id;
  if v_session_number > 300 then
    raise exception using errcode = '22023', message = 'subscription session limit reached';
  end if;
  select greatest(1, max(installment_number))::smallint into v_installment_number
    from public.subscription_bundle_installments
   where subscription_id = p_subscription_id and organization_id = p_organization_id;
  if v_installment_number is null then
    raise exception using errcode = '22023', message = 'subscription has no installment to associate with the courtesy session';
  end if;
  insert into public.subscription_bundle_sessions(
    organization_id, subscription_id, session_number, release_on, installment_number, barber_id
  ) values (
    p_organization_id, p_subscription_id, v_session_number,
    (p_starts_at at time zone v_org.timezone)::date, v_installment_number, p_barber_id
  ) returning id into v_session_id;
  v_appointment_id := public.create_subscription_bundle_appointment(
    p_organization_id, v_subscription.customer_id, p_subscription_id, v_session_id,
    p_barber_id, null, p_starts_at, auth.uid(), 'MANAGER'
  );
  insert into public.appointment_status_events(
    organization_id, appointment_id, to_status, reason, actor_user_id, metadata
  ) values (
    p_organization_id, v_appointment_id, 'CONFIRMED', 'subscription_bundle_courtesy_session_added', auth.uid(),
    jsonb_build_object('subscription_id', p_subscription_id, 'subscription_bundle_session_id', v_session_id,
      'courtesy', true, 'contract_price_changed', false, 'installments_changed', false)
  );
  return jsonb_build_object('session_id', v_session_id, 'appointment_id', v_appointment_id,
    'session_number', v_session_number, 'courtesy', true);
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription bundle not found';
end;
$$;
revoke all on function public.add_subscription_bundle_courtesy_session(uuid,uuid,uuid,timestamptz)
  from public, anon, service_role;
grant execute on function public.add_subscription_bundle_courtesy_session(uuid,uuid,uuid,timestamptz)
  to authenticated;

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
     and session.deleted_at is null and session.status in ('SCHEDULED', 'COMPLETED') and session.scheduled_for is not null
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
