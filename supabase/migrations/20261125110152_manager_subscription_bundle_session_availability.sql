create or replace function public.get_manager_subscription_bundle_slots(
  p_organization_id uuid,
  p_subscription_id uuid,
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
  v_subscription public.customer_subscriptions%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_session public.subscription_bundle_sessions%rowtype;
  v_appointment public.appointments%rowtype;
  v_barber public.barbers%rowtype;
  v_source record;
  v_local_start timestamp;
  v_start timestamptz;
  v_period tstzrange;
  v_occupied integer;
  v_active_appointment_id uuid;
  v_slots jsonb := '[]'::jsonb;
  v_seen_starts timestamptz[] := array[]::timestamptz[];
begin
  if auth.uid() is null or not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization owner required';
  end if;
  if not public.organization_allows_existing_operations(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization access does not allow subscription operations';
  end if;
  if p_local_date is null then
    raise exception using errcode = '22023', message = 'availability date is required';
  end if;

  select * into strict v_org
    from public.organizations
   where id = p_organization_id;
  select * into strict v_subscription
    from public.customer_subscriptions
   where id = p_subscription_id
     and organization_id = p_organization_id;
  if not exists (
    select 1 from public.subscription_bundle_contracts contract
     where contract.subscription_id = p_subscription_id
       and contract.organization_id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'subscription bundle contract not found';
  end if;
  select * into strict v_version
    from public.subscription_plan_versions
   where id = v_subscription.plan_version_id
     and organization_id = p_organization_id;
  select * into strict v_barber
    from public.barbers
   where id = p_barber_id
     and organization_id = p_organization_id
     and active;

  if v_subscription.status not in ('ACTIVE', 'PENDING_PAYMENT') then
    raise exception using errcode = '22023', message = 'subscription does not accept session changes';
  end if;

  if p_session_id is not null then
    select * into strict v_session
      from public.subscription_bundle_sessions
     where id = p_session_id
       and subscription_id = p_subscription_id
       and organization_id = p_organization_id
       and deleted_at is null;
    if v_session.status = 'COMPLETED' then
      raise exception using errcode = '22023', message = 'completed subscription session cannot be rescheduled';
    end if;
    if v_session.appointment_id is not null then
      select * into v_appointment
        from public.appointments
       where id = v_session.appointment_id
         and organization_id = p_organization_id;
      if found and v_appointment.status in ('IN_SERVICE', 'COMPLETED', 'NO_SHOW', 'EXPIRED') then
        raise exception using errcode = '22023', message = 'started or completed subscription session cannot be rescheduled';
      end if;
      if found and v_appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE') then
        v_active_appointment_id := v_appointment.id;
      end if;
    end if;
  end if;

  if not exists (
    select 1 from public.barber_services assignment
     where assignment.organization_id = p_organization_id
       and assignment.barber_id = p_barber_id
       and assignment.service_id = v_version.bundle_service_id
       and assignment.active
  ) or not exists (
    select 1 from public.barber_subscription_plans assignment
     where assignment.organization_id = p_organization_id
       and assignment.barber_id = p_barber_id
       and assignment.plan_id = v_subscription.plan_id
       and assignment.active
  ) then
    raise exception using errcode = '22023', message = 'professional is not configured for this subscription service and plan';
  end if;

  v_occupied := ceil(v_version.bundle_session_duration_minutes::numeric / v_org.slot_interval_minutes)::integer
    * v_org.slot_interval_minutes;
  if p_local_date < (now() at time zone v_org.timezone)::date then
    return jsonb_build_object('duration_minutes', v_version.bundle_session_duration_minutes,
      'occupied_minutes', v_occupied, 'slots', v_slots);
  end if;

  for v_source in
    select sources.local_start, sources.local_limit
      from (
        select p_local_date + interval_data.starts_at as local_start,
               p_local_date + interval_data.ends_at as local_limit
          from public.work_intervals interval_data
         where interval_data.organization_id = p_organization_id
           and interval_data.barber_id = p_barber_id
           and interval_data.active
           and interval_data.weekday = extract(dow from p_local_date)::smallint
        union all
        select timezone(v_org.timezone,
                 greatest(lower(exception_row.service_period), p_local_date::timestamp at time zone v_org.timezone)) as local_start,
               timezone(v_org.timezone,
                 least(upper(exception_row.service_period), (p_local_date + 1)::timestamp at time zone v_org.timezone)) as local_limit
          from public.availability_exceptions exception_row
         where exception_row.organization_id = p_organization_id
           and exception_row.barber_id = p_barber_id
           and exception_row.kind = 'AVAILABLE_OVERRIDE'
           and exception_row.service_period && tstzrange(
             p_local_date::timestamp at time zone v_org.timezone,
             (p_local_date + 1)::timestamp at time zone v_org.timezone,
             '[)'
           )
      ) sources
     where sources.local_start < sources.local_limit
     order by sources.local_start, sources.local_limit
  loop
    v_local_start := date_trunc('day', v_source.local_start) + make_interval(mins =>
      ceil(extract(epoch from (v_source.local_start - date_trunc('day', v_source.local_start)))
        / 60 / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes);

    while v_local_start + make_interval(mins => v_occupied) <= v_source.local_limit loop
      v_start := v_local_start at time zone v_org.timezone;
      v_period := tstzrange(v_start, v_start + make_interval(mins => v_occupied), '[)');

      if v_start > now()
         and not (v_start = any(v_seen_starts))
         and (v_active_appointment_id is null or v_start <> lower(v_appointment.service_period))
         and not public.organization_date_blocked(p_organization_id, v_period)
         and public.is_barber_available(p_organization_id, p_barber_id, v_period)
         and not exists (
           select 1 from public.appointments appointment
            where appointment.organization_id = p_organization_id
              and appointment.customer_id = v_subscription.customer_id
              and appointment.id is distinct from v_active_appointment_id
              and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
              and appointment.service_period && v_period
         )
         and public.resolve_appointment_environment(
           p_organization_id, p_barber_id, v_barber.location_id, v_period, null, v_active_appointment_id
         ) is not null
         and (v_barber.allow_parallel_environment_appointments or not exists (
           select 1 from public.appointments appointment
            where appointment.organization_id = p_organization_id
              and appointment.barber_id = p_barber_id
              and appointment.id is distinct from v_active_appointment_id
              and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
              and appointment.service_period && v_period
         ))
         and not exists (
           select 1 from public.walkin_queue_holds hold
            where hold.organization_id = p_organization_id
              and hold.barber_id = p_barber_id
              and hold.consumed_at is null
              and hold.expires_at > now()
              and hold.service_period && v_period
         ) then
        v_slots := v_slots || jsonb_build_array(jsonb_build_object(
          'starts_at', v_start,
          'ends_at', upper(v_period)
        ));
        v_seen_starts := array_append(v_seen_starts, v_start);
      end if;

      v_local_start := v_local_start + make_interval(mins => v_org.slot_interval_minutes);
    end loop;
  end loop;

  return jsonb_build_object(
    'duration_minutes', v_version.bundle_session_duration_minutes,
    'occupied_minutes', v_occupied,
    'slots', v_slots
  );
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription session or professional not found';
end;
$$;

revoke all on function public.get_manager_subscription_bundle_slots(uuid,uuid,uuid,uuid,date)
  from public, anon, service_role;
grant execute on function public.get_manager_subscription_bundle_slots(uuid,uuid,uuid,uuid,date)
  to authenticated;
