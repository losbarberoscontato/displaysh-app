create or replace function public.get_customer_subscription_bundle_reschedule_slots(
  p_organization_id uuid,
  p_customer_id uuid,
  p_session_id uuid,
  p_barber_id uuid,
  p_local_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_org public.organizations%rowtype;
  v_session public.subscription_bundle_sessions%rowtype;
  v_subscription public.customer_subscriptions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_appointment public.appointments%rowtype;
  v_barber public.barbers%rowtype;
  v_source record;
  v_local_start timestamp;
  v_start timestamptz;
  v_period tstzrange;
  v_original_date date;
  v_today date;
  v_occupied integer;
  v_slots jsonb := '[]'::jsonb;
  v_seen_starts timestamptz[] := array[]::timestamptz[];
begin
  if auth.uid() is null or not public.is_organization_customer(p_organization_id, p_customer_id, auth.uid()) then
    raise exception using errcode = '42501', message = 'customer reschedule denied';
  end if;
  if p_local_date is null or p_barber_id is null then
    raise exception using errcode = '22023', message = 'date and professional are required';
  end if;
  if not public.organization_module_enabled(p_organization_id, 'subscription_plans') then
    raise exception using errcode = '42501', message = 'subscription module disabled';
  end if;
  select * into strict v_org from public.organizations where id = p_organization_id;
  select * into strict v_session from public.subscription_bundle_sessions
   where id = p_session_id and organization_id = p_organization_id and deleted_at is null;
  select * into strict v_subscription from public.customer_subscriptions
   where id = v_session.subscription_id and organization_id = p_organization_id;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_subscription.id and organization_id = p_organization_id;
  select * into strict v_version from public.subscription_plan_versions
   where id = v_subscription.plan_version_id and organization_id = p_organization_id;
  select * into strict v_appointment from public.appointments
   where id = v_session.appointment_id and organization_id = p_organization_id;
  select * into strict v_barber from public.barbers
   where id = p_barber_id and organization_id = p_organization_id and active;

  v_today := (now() at time zone v_org.timezone)::date;
  v_original_date := (coalesce(v_session.rescheduled_from, v_session.scheduled_for, lower(v_appointment.service_period)) at time zone v_org.timezone)::date;
  if v_subscription.customer_id <> p_customer_id
     or v_subscription.status <> 'ACTIVE'
     or v_subscription.contract_accepted_at is null
     or v_version.model <> 'SESSION_BUNDLE_V1'
     or v_session.status <> 'SCHEDULED'
     or v_appointment.status <> 'CONFIRMED'
     or v_appointment.subscription_bundle_session_id is distinct from v_session.id
     or v_appointment.customer_id is distinct from p_customer_id
     or lower(v_appointment.service_period) <= now()
     or p_local_date < greatest(v_today, v_original_date - 14)
     or p_local_date > v_original_date + 14
     or not public.organization_accepts_new_bookings(p_organization_id) then
    raise exception using errcode = '22023', message = 'subscription session reschedule date is not available';
  end if;
  if not exists (select 1 from public.barber_services link
      where link.organization_id = p_organization_id and link.barber_id = p_barber_id
        and link.service_id = v_contract.service_id and link.active)
     or not exists (select 1 from public.barber_subscription_plans link
      where link.organization_id = p_organization_id and link.barber_id = p_barber_id
        and link.plan_id = v_subscription.plan_id and link.active)
     then
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
      ) sources
     where sources.local_start < sources.local_limit
     order by sources.local_start, sources.local_limit
  loop
    v_local_start := date_trunc('day', v_source.local_start) + make_interval(mins =>
      ceil(extract(epoch from (v_source.local_start - date_trunc('day', v_source.local_start))) / 60 / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes);
    while v_local_start + make_interval(mins => v_occupied) <= v_source.local_limit loop
      v_start := v_local_start at time zone v_org.timezone;
      v_period := tstzrange(v_start, v_start + make_interval(mins => v_occupied), '[)');
      if v_start > now()
         and not (v_start = any(v_seen_starts))
         and not public.organization_date_blocked(p_organization_id, v_period)
         and not exists (select 1 from public.availability_exceptions exception
           where exception.organization_id = p_organization_id
             and exception.barber_id = p_barber_id
             and exception.kind = 'UNAVAILABLE'
             and exception.service_period && v_period)
         and public.resolve_appointment_environment(
           p_organization_id, p_barber_id, v_barber.location_id, v_period, null, v_appointment.id
         ) is not null
         and exists (select 1 from public.commission_rules rule
           where rule.organization_id = p_organization_id
             and rule.barber_id = p_barber_id
             and rule.subscription_plan_id = v_subscription.plan_id
             and rule.active and rule.effective_period @> v_start)
         and not exists (select 1 from public.appointments appointment
           where appointment.organization_id = p_organization_id
             and appointment.id is distinct from v_appointment.id
             and appointment.barber_id = p_barber_id
             and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
             and appointment.service_period && v_period)
         and not exists (select 1 from public.appointments appointment
           where appointment.organization_id = p_organization_id
             and appointment.customer_id = p_customer_id
             and appointment.id is distinct from v_appointment.id
             and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
             and appointment.service_period && v_period) then
        v_slots := v_slots || jsonb_build_array(jsonb_build_object('starts_at', v_start, 'ends_at', upper(v_period)));
        v_seen_starts := array_append(v_seen_starts, v_start);
      end if;
      v_local_start := v_local_start + make_interval(mins => v_org.slot_interval_minutes);
    end loop;
  end loop;
  return jsonb_build_object('duration_minutes', v_contract.session_duration_minutes,
    'occupied_minutes', v_occupied, 'slots', v_slots);
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle session or professional not found';
end;
$$;
revoke all on function public.get_customer_subscription_bundle_reschedule_slots(uuid,uuid,uuid,uuid,date) from public, anon;
grant execute on function public.get_customer_subscription_bundle_reschedule_slots(uuid,uuid,uuid,uuid,date) to authenticated;

create or replace function public.reschedule_customer_subscription_bundle_session(
  p_organization_id uuid,
  p_customer_id uuid,
  p_session_id uuid,
  p_barber_id uuid,
  p_starts_at timestamptz,
  p_reason text default null
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
  v_appointment public.appointments%rowtype;
  v_org public.organizations%rowtype;
  v_barber public.barbers%rowtype;
  v_period tstzrange;
  v_original_start timestamptz;
  v_original_date date;
  v_new_local_start timestamp;
  v_new_date date;
  v_occupied integer;
  v_environment_id uuid;
  v_commission_mode public.commission_mode;
  v_commission_percentage_bps integer;
  v_commission_fixed_cents bigint;
begin
  if auth.uid() is null or not public.is_organization_customer(p_organization_id, p_customer_id, auth.uid()) then
    raise exception using errcode = '42501', message = 'customer reschedule denied';
  end if;
  if length(coalesce(p_reason, '')) > 500 then
    raise exception using errcode = '22023', message = 'reschedule reason is too long';
  end if;
  if not public.organization_module_enabled(p_organization_id, 'subscription_plans') then
    raise exception using errcode = '42501', message = 'subscription module disabled';
  end if;

  select * into strict v_session from public.subscription_bundle_sessions
   where id = p_session_id and organization_id = p_organization_id and deleted_at is null for update;
  select * into strict v_subscription from public.customer_subscriptions
   where id = v_session.subscription_id and organization_id = p_organization_id for update;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_subscription.id and organization_id = p_organization_id;
  select * into strict v_version from public.subscription_plan_versions
   where id = v_subscription.plan_version_id and organization_id = p_organization_id;
  select * into strict v_org from public.organizations where id = p_organization_id;
  select * into strict v_appointment from public.appointments
   where id = v_session.appointment_id and organization_id = p_organization_id for update;
  if v_subscription.customer_id <> p_customer_id
     or v_subscription.status <> 'ACTIVE'
     or v_subscription.contract_accepted_at is null
     or v_version.model <> 'SESSION_BUNDLE_V1'
     or v_session.status <> 'SCHEDULED'
     or v_appointment.status <> 'CONFIRMED'
     or v_appointment.customer_id is distinct from p_customer_id
     or v_appointment.subscription_bundle_session_id is distinct from v_session.id then
    raise exception using errcode = '22023', message = 'subscription bundle session cannot be rescheduled';
  end if;
  if lower(v_appointment.service_period) <= now() or p_starts_at is null or p_starts_at <= now()
     or not public.organization_accepts_new_bookings(p_organization_id) then
    raise exception using errcode = '22023', message = 'future date and accepting establishment are required';
  end if;
  if p_barber_id is null then
    raise exception using errcode = '22023', message = 'professional is required';
  end if;
  select * into strict v_barber from public.barbers
   where id = p_barber_id and organization_id = p_organization_id and active;
  if not exists (select 1 from public.barber_services link
      where link.organization_id = p_organization_id and link.barber_id = p_barber_id
        and link.service_id = v_contract.service_id and link.active)
     or not exists (select 1 from public.barber_subscription_plans link
      where link.organization_id = p_organization_id and link.barber_id = p_barber_id
        and link.plan_id = v_subscription.plan_id and link.active) then
    raise exception using errcode = '22023', message = 'professional is not configured for this subscription service and plan';
  end if;

  v_original_start := coalesce(v_session.rescheduled_from, v_session.scheduled_for, lower(v_appointment.service_period));
  v_original_date := (v_original_start at time zone v_org.timezone)::date;
  v_new_local_start := p_starts_at at time zone v_org.timezone;
  v_new_date := v_new_local_start::date;
  if v_new_date < greatest((now() at time zone v_org.timezone)::date, v_original_date - 14)
     or v_new_date > v_original_date + 14 then
    raise exception using errcode = '22023', message = 'subscription reschedule outside original two-week window';
  end if;
  if extract(second from v_new_local_start) <> 0
     or mod(extract(minute from v_new_local_start)::integer, v_org.slot_interval_minutes) <> 0 then
    raise exception using errcode = '22023', message = 'start time is not aligned to organization slot interval';
  end if;
  v_occupied := ceil(v_contract.session_duration_minutes::numeric / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes;
  v_period := tstzrange(p_starts_at, p_starts_at + make_interval(mins => v_occupied), '[)');
  if public.organization_date_blocked(p_organization_id, v_period)
     or exists (select 1 from public.availability_exceptions exception
       where exception.organization_id = p_organization_id
         and exception.barber_id = p_barber_id
         and exception.kind = 'UNAVAILABLE'
         and exception.service_period && v_period)
     or exists (select 1 from public.appointments appointment
       where appointment.organization_id = p_organization_id
         and appointment.customer_id = p_customer_id
         and appointment.id is distinct from v_appointment.id
         and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
         and appointment.service_period && v_period) then
    raise exception using errcode = '23P01', message = 'requested subscription time is no longer available';
  end if;
  v_environment_id := public.resolve_appointment_environment(
    p_organization_id, p_barber_id, v_barber.location_id, v_period, null, v_appointment.id
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

  update public.appointments
     set barber_id = p_barber_id,
         location_id = v_barber.location_id,
         environment_id = v_environment_id,
         service_period = v_period,
         version = version + 1
   where id = v_appointment.id and organization_id = p_organization_id;
  insert into public.appointment_status_events(
    organization_id, appointment_id, from_status, to_status, reason, actor_user_id, metadata
  ) values (
    p_organization_id, v_appointment.id, v_appointment.status, v_appointment.status,
    'subscription_bundle_session_rescheduled_by_customer', auth.uid(),
    jsonb_build_object('subscription_bundle_session_id', v_session.id,
      'previous_starts_at', lower(v_appointment.service_period), 'starts_at', p_starts_at)
  );
  update public.subscription_bundle_sessions
     set barber_id = coalesce(barber_id, v_appointment.barber_id),
         substitute_barber_id = case when p_barber_id = coalesce(barber_id, v_appointment.barber_id) then null else p_barber_id end,
         scheduled_for = p_starts_at,
         rescheduled_from = coalesce(rescheduled_from, scheduled_for, lower(v_appointment.service_period)),
         reschedule_observation = nullif(btrim(coalesce(p_reason, '')), ''),
         canceled_at = null,
         commission_mode = v_commission_mode,
         commission_percentage_bps = v_commission_percentage_bps,
         commission_fixed_cents = v_commission_fixed_cents,
         status = 'SCHEDULED'
   where id = v_session.id and organization_id = p_organization_id;

  return jsonb_build_object('session_id', v_session.id, 'appointment_id', v_appointment.id,
    'starts_at', p_starts_at, 'status', 'SCHEDULED');
exception
  when exclusion_violation then
    raise exception using errcode = '23P01', message = 'new slot is no longer available; original session remains unchanged';
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription bundle session or professional not found';
end;
$$;
revoke all on function public.reschedule_customer_subscription_bundle_session(uuid,uuid,uuid,uuid,timestamptz,text) from public, anon, service_role;
grant execute on function public.reschedule_customer_subscription_bundle_session(uuid,uuid,uuid,uuid,timestamptz,text) to authenticated;
