begin;

-- Work intervals describe professional availability. They do not reserve a room.
-- Appointment capacity remains enforced by resolve_appointment_environment.
alter table public.work_intervals
  drop constraint if exists work_intervals_environment_no_overlap;

-- Keep automatic environment assignment for legacy callers, but do not treat
-- another professional's work interval as room occupancy.
alter function public.mutate_barber_schedule(
  uuid, uuid, text, uuid, smallint, time, time, uuid, uuid,
  timestamptz, timestamptz, text, public.availability_exception_kind
) rename to mutate_barber_schedule_before_shared_room_schedules;

revoke all on function public.mutate_barber_schedule_before_shared_room_schedules(
  uuid, uuid, text, uuid, smallint, time, time, uuid, uuid,
  timestamptz, timestamptz, text, public.availability_exception_kind
) from public, anon, authenticated;

create or replace function public.mutate_barber_schedule(
  p_organization_id uuid,
  p_barber_id uuid,
  p_action text,
  p_interval_id uuid default null,
  p_weekday smallint default null,
  p_starts_at time default null,
  p_ends_at time default null,
  p_environment_id uuid default null,
  p_exception_id uuid default null,
  p_exception_start timestamptz default null,
  p_exception_end timestamptz default null,
  p_reason text default null,
  p_exception_kind public.availability_exception_kind default 'UNAVAILABLE'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_location_id uuid;
  v_environment_id uuid;
  v_allow_parallel boolean := false;
begin
  if p_action = 'ADD_INTERVAL' and p_environment_id is null then
    if auth.uid() is null then
      raise exception using errcode = '28000', message = 'authentication required';
    end if;
    if not public.is_organization_owner(p_organization_id)
       and not exists (
         select 1 from public.barbers barber
         where barber.id = p_barber_id
           and barber.organization_id = p_organization_id
           and barber.active
           and barber.auth_user_id = auth.uid()
           and barber.app_access_enabled
       ) then
      raise exception using errcode = '42501', message = 'barber schedule management denied';
    end if;

    select barber.location_id, coalesce(barber.allow_parallel_environment_appointments, false)
      into v_location_id, v_allow_parallel
    from public.barbers barber
    where barber.id = p_barber_id
      and barber.organization_id = p_organization_id
      and barber.active;
    if not found then
      raise exception using errcode = 'P0002', message = 'active barber not found';
    end if;

    if exists (
      select 1 from public.work_intervals interval_row
      where interval_row.organization_id = p_organization_id
        and interval_row.barber_id = p_barber_id
        and interval_row.active
        and interval_row.weekday = p_weekday
        and interval_row.starts_at < p_ends_at
        and interval_row.ends_at > p_starts_at
        and (not v_allow_parallel or interval_row.environment_id is null)
    ) then
      raise exception using errcode = '23P01', message = 'barber already has a work interval in this period';
    end if;

    select environment.id into v_environment_id
    from public.agenda_environments environment
    where environment.organization_id = p_organization_id
      and environment.location_id = v_location_id
      and environment.active
      and not exists (
        select 1 from public.work_intervals interval_row
        where interval_row.organization_id = p_organization_id
          and interval_row.barber_id = p_barber_id
          and interval_row.active
          and interval_row.weekday = p_weekday
          and interval_row.starts_at < p_ends_at
          and interval_row.ends_at > p_starts_at
          and (interval_row.environment_id is null or interval_row.environment_id = environment.id)
      )
    order by environment.sort_order, environment.id
    limit 1;
    if v_environment_id is null then
      if exists (
        select 1 from public.work_intervals interval_row
        where interval_row.organization_id = p_organization_id
          and interval_row.barber_id = p_barber_id
          and interval_row.active
          and interval_row.weekday = p_weekday
          and interval_row.starts_at < p_ends_at
          and interval_row.ends_at > p_starts_at
      ) then
        raise exception using errcode = '23P01', message = 'barber already has a work interval in this period';
      end if;
      raise exception using errcode = '22023', message = 'no active agenda environment is available for this time';
    end if;
    p_environment_id := v_environment_id;
  end if;

  return public.mutate_barber_schedule_before_shared_room_schedules(
    p_organization_id, p_barber_id, p_action, p_interval_id, p_weekday,
    p_starts_at, p_ends_at, p_environment_id, p_exception_id,
    p_exception_start, p_exception_end, p_reason, p_exception_kind
  );
end;
$$;

revoke all on function public.mutate_barber_schedule(
  uuid, uuid, text, uuid, smallint, time, time, uuid, uuid,
  timestamptz, timestamptz, text, public.availability_exception_kind
) from public, anon;
grant execute on function public.mutate_barber_schedule(
  uuid, uuid, text, uuid, smallint, time, time, uuid, uuid,
  timestamptz, timestamptz, text, public.availability_exception_kind
) to authenticated;

-- Reschedule availability from the appointment's exact stored selections,
-- while ignoring that appointment's current booking during conflict checks.
create or replace function public.get_manager_appointment_reschedule_slots(
  p_organization_id uuid,
  p_appointment_id uuid,
  p_barber_id uuid,
  p_local_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_org public.organizations%rowtype;
  v_appointment public.appointments%rowtype;
  v_location_id uuid;
  v_selections jsonb;
  v_resolution jsonb;
  v_duration integer;
  v_occupied integer;
  v_source record;
  v_environment record;
  v_local_start timestamp;
  v_start timestamptz;
  v_period tstzrange;
  v_resolved_environment_id uuid;
  v_slots jsonb := '[]'::jsonb;
  v_seen_starts timestamptz[] := array[]::timestamptz[];
  v_today date;
begin
  if auth.uid() is null or not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization owner required';
  end if;
  if not public.organization_accepts_new_bookings(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization is not accepting reschedules';
  end if;
  if p_local_date is null then
    raise exception using errcode = '22023', message = 'availability date is required';
  end if;

  select * into strict v_org
  from public.organizations organization
  where organization.id = p_organization_id;
  select * into strict v_appointment
  from public.appointments appointment
  where appointment.id = p_appointment_id
    and appointment.organization_id = p_organization_id;
  if v_appointment.status <> 'CONFIRMED' then
    raise exception using errcode = '22023', message = 'only confirmed appointments can be rescheduled';
  end if;

  select barber.location_id into v_location_id
  from public.barbers barber
  where barber.id = p_barber_id
    and barber.organization_id = p_organization_id
    and barber.active;
  if not found then
    raise exception using errcode = 'P0002', message = 'active barber not found';
  end if;

  v_today := (now() at time zone v_org.timezone)::date;
  if p_local_date < v_today or p_local_date > v_today + 180 then
    raise exception using errcode = '22023', message = 'availability date outside allowed window';
  end if;

  select coalesce(
    jsonb_agg(jsonb_build_object('preserved_selection_key', selection_keys.selection_key)),
    '[]'::jsonb
  ) into v_selections
  from (
    select distinct item.selection_key
    from public.appointment_items item
    where item.organization_id = p_organization_id
      and item.appointment_id = p_appointment_id
      and item.selection_key is not null
    order by item.selection_key
  ) selection_keys;
  if jsonb_array_length(v_selections) = 0 then
    raise exception using errcode = '22023', message = 'appointment has no preserved selections';
  end if;

  v_resolution := public.resolve_booking_selection(
    p_organization_id, p_barber_id, v_selections, p_appointment_id
  );
  v_duration := (v_resolution ->> 'duration_minutes')::integer;
  v_occupied := ceil(v_duration::numeric / v_org.slot_interval_minutes)::integer
    * v_org.slot_interval_minutes;

  for v_source in
    select sources.local_start, sources.local_limit
    from (
      select p_local_date + interval_row.starts_at as local_start,
             p_local_date + interval_row.ends_at as local_limit
      from public.work_intervals interval_row
      where interval_row.organization_id = p_organization_id
        and interval_row.barber_id = p_barber_id
        and interval_row.active
        and interval_row.weekday = extract(dow from p_local_date)::smallint
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
         and not public.organization_date_blocked(p_organization_id, v_period)
         and not exists (
           select 1 from public.availability_exceptions exception_row
           where exception_row.organization_id = p_organization_id
             and exception_row.barber_id = p_barber_id
             and exception_row.kind = 'UNAVAILABLE'
             and exception_row.service_period && v_period
         )
         and not exists (
           select 1 from public.appointments appointment
           where appointment.organization_id = p_organization_id
             and appointment.barber_id = p_barber_id
             and appointment.id is distinct from p_appointment_id
             and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
             and appointment.service_period && v_period
         )
         and not exists (
           select 1 from public.walkin_queue_holds hold
           where hold.organization_id = p_organization_id
             and hold.barber_id = p_barber_id
             and hold.consumed_at is null
             and hold.expires_at > now()
             and hold.service_period && v_period
         ) then
        for v_environment in
          select environment.id, environment.name, environment.sort_order
          from public.agenda_environments environment
          where environment.organization_id = p_organization_id
            and environment.location_id = v_location_id
            and environment.active
          order by environment.sort_order, environment.name, environment.id
        loop
          begin
            v_resolved_environment_id := public.resolve_appointment_environment(
              p_organization_id, p_barber_id, v_location_id, v_period,
              v_environment.id, p_appointment_id
            );
          exception
            when sqlstate '22023' or sqlstate '23P01' then
              continue;
          end;
          if v_resolved_environment_id = v_environment.id then
            v_slots := v_slots || jsonb_build_array(jsonb_build_object(
              'starts_at', v_start,
              'ends_at', upper(v_period),
              'environment_id', v_environment.id,
              'environment_name', v_environment.name
            ));
          end if;
        end loop;
        v_seen_starts := array_append(v_seen_starts, v_start);
      end if;

      v_local_start := v_local_start + make_interval(mins => v_org.slot_interval_minutes);
    end loop;
  end loop;

  return jsonb_build_object(
    'duration_minutes', v_duration,
    'occupied_minutes', v_occupied,
    'slots', v_slots
  );
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization, appointment or active barber not found';
end;
$$;

revoke all on function public.get_manager_appointment_reschedule_slots(uuid, uuid, uuid, date) from public, anon;
grant execute on function public.get_manager_appointment_reschedule_slots(uuid, uuid, uuid, date) to authenticated;

-- Re-resolve the room as part of the same atomic reschedule. The current
-- appointment is excluded from availability, then the appointment trigger
-- rechecks barber and room capacity while saving the new environment.
create or replace function public.reschedule_appointment(
  p_appointment_id uuid,
  p_new_barber_id uuid,
  p_new_starts_at timestamptz,
  p_selections jsonb default null,
  p_override_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_appointment public.appointments%rowtype;
  v_org public.organizations%rowtype;
  v_barber public.barbers%rowtype;
  v_resolution jsonb;
  v_effective_selections jsonb;
  v_period tstzrange;
  v_old_period tstzrange;
  v_duration integer;
  v_occupied integer;
  v_old_total bigint;
  v_new_total bigint;
  v_net_paid bigint;
  v_refund_amount bigint := 0;
  v_balance_amount bigint := 0;
  v_refund_order_id uuid;
  v_environment_id uuid;
  v_is_owner boolean;
  v_is_customer boolean;
  v_local_start timestamp;
begin
  select * into strict v_appointment
  from public.appointments where id = p_appointment_id for update;
  v_is_owner := public.is_organization_owner(v_appointment.organization_id);
  v_is_customer := public.is_organization_customer(
    v_appointment.organization_id, v_appointment.customer_id
  );
  if not (v_is_owner or v_is_customer) then
    raise exception using errcode = '42501', message = 'appointment reschedule denied';
  end if;
  if not public.organization_accepts_new_bookings(v_appointment.organization_id) then
    raise exception using errcode = '42501', message = 'organization is not accepting reschedules';
  end if;
  if v_appointment.status <> 'CONFIRMED' then
    raise exception using errcode = '22023', message = 'only confirmed appointments can be rescheduled';
  end if;
  if p_new_starts_at <= now() then
    raise exception using errcode = '22023', message = 'appointment start must be in the future';
  end if;
  if v_is_customer and now() > lower(v_appointment.service_period)
      - make_interval(mins => v_appointment.cancellation_lead_minutes_snapshot) then
    raise exception using errcode = '22023', message = 'customer reschedule deadline passed';
  end if;

  select * into strict v_org from public.organizations
    where id = v_appointment.organization_id;
  select * into strict v_barber from public.barbers
    where id = p_new_barber_id
      and organization_id = v_appointment.organization_id and active;
  v_local_start := p_new_starts_at at time zone v_org.timezone;
  if extract(second from v_local_start) <> 0
     or mod(extract(minute from v_local_start)::integer, v_org.slot_interval_minutes) <> 0 then
    raise exception using errcode = '22023', message = 'start time is not aligned to slot interval';
  end if;
  if p_selections is null then
    select jsonb_agg(jsonb_build_object('preserved_selection_key', keys.selection_key))
      into v_effective_selections
    from (
      select distinct item.selection_key
      from public.appointment_items item
      where item.appointment_id = v_appointment.id
        and item.organization_id = v_appointment.organization_id
    ) keys;
  else
    v_effective_selections := p_selections;
  end if;
  v_resolution := public.resolve_booking_selection(
    v_appointment.organization_id, p_new_barber_id,
    v_effective_selections, v_appointment.id
  );
  v_duration := (v_resolution ->> 'duration_minutes')::integer;
  v_occupied := ceil(v_duration::numeric / v_org.slot_interval_minutes)::integer
    * v_org.slot_interval_minutes;
  v_period := tstzrange(
    p_new_starts_at, p_new_starts_at + make_interval(mins => v_occupied), '[)'
  );
  if public.organization_date_blocked(v_appointment.organization_id, v_period) then
    raise exception using errcode = '22023', message = 'requested date is blocked';
  end if;
  v_environment_id := public.resolve_appointment_environment(
    v_appointment.organization_id, p_new_barber_id, v_barber.location_id,
    v_period, null, v_appointment.id
  );
  if v_environment_id is null then
    raise exception using errcode = '22023', message = 'barber unavailable or no active environment is available';
  end if;

  v_old_period := v_appointment.service_period;
  v_old_total := v_appointment.total_cents_snapshot;
  v_new_total := (v_resolution ->> 'total_cents')::bigint;

  -- This single update acquires the new slot. If GiST rejects it, the old row remains untouched.
  update public.appointments
    set barber_id = p_new_barber_id,
        location_id = v_barber.location_id,
        environment_id = v_environment_id,
        service_period = v_period,
        total_cents_snapshot = v_new_total,
        list_total_cents_snapshot = (v_resolution ->> 'list_total_cents')::bigint,
        schedule_override_reason = case when v_is_owner
          then nullif(btrim(p_override_reason), '') else null end,
        version = version + 1
    where id = v_appointment.id;

  delete from public.appointment_items
  where appointment_id = v_appointment.id
    and organization_id = v_appointment.organization_id;
  perform public.insert_resolved_appointment_items(
    v_appointment.id, v_appointment.organization_id, v_resolution
  );

  select coalesce(sum(case
    when kind in ('CAPTURE', 'ADJUSTMENT') then amount_cents
    when kind in ('REFUND', 'REVERSAL') then -amount_cents
  end), 0)::bigint
  into v_net_paid
  from public.payment_transactions
  where appointment_id = v_appointment.id
    and organization_id = v_appointment.organization_id;
  v_net_paid := greatest(v_net_paid, 0);
  v_refund_amount := greatest(v_net_paid - v_new_total, 0);
  v_balance_amount := greatest(v_new_total - v_net_paid, 0);
  if v_refund_amount > 0 then
    insert into public.payment_orders (
      organization_id, appointment_id, provider, kind, status,
      amount_cents, currency, idempotency_key, metadata
    ) values (
      v_appointment.organization_id, v_appointment.id, 'MANUAL', 'REFUND',
      'REQUIRES_ACTION', v_refund_amount, v_appointment.currency,
      'reschedule-refund:' || v_appointment.id || ':v' || (v_appointment.version + 1),
      jsonb_build_object(
        'old_total_cents', v_old_total,
        'new_total_cents', v_new_total,
        'net_paid_cents', v_net_paid,
        'manual_action_required', true
      )
    ) returning id into v_refund_order_id;
  end if;

  insert into public.appointment_status_events (
    organization_id, appointment_id, from_status, to_status,
    reason, actor_user_id, metadata
  ) values (
    v_appointment.organization_id, v_appointment.id, 'CONFIRMED', 'CONFIRMED',
    'appointment_rescheduled', auth.uid(),
    jsonb_build_object(
      'old_period', v_old_period,
      'new_period', v_period,
      'old_total_cents', v_old_total,
      'new_total_cents', v_new_total,
      'net_paid_cents', v_net_paid,
      'balance_cents', v_balance_amount,
      'manual_refund_cents', v_refund_amount,
      'refund_order_id', v_refund_order_id
    )
  );

  return jsonb_build_object(
    'appointment_id', v_appointment.id,
    'service_period', v_period,
    'environment_id', v_environment_id,
    'total_cents', v_new_total,
    'balance_cents', v_balance_amount,
    'refund_amount_cents', v_refund_amount,
    'refund_order_id', v_refund_order_id
  );
exception
  when exclusion_violation then
    raise exception using errcode = '23P01', message = 'new slot is no longer available; original appointment preserved';
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'appointment, organization or barber not found';
end;
$$;

revoke all on function public.reschedule_appointment(uuid, uuid, timestamptz, jsonb, text) from public, anon;
grant execute on function public.reschedule_appointment(uuid, uuid, timestamptz, jsonb, text) to authenticated;

notify pgrst, 'reload schema';

commit;
