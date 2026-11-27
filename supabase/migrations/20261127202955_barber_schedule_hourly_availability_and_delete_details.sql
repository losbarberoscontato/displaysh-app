-- Hourly availability for the professional schedule editor. The visible agenda
-- currently spans 08:00–22:00; availability is derived from the same tenant,
-- room, recurring schedule and appointment records used by booking.
create or replace function public.get_my_barber_available_schedule_slots(
  p_organization_id uuid,
  p_weekday smallint,
  p_environment_id uuid,
  p_ignore_interval_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_barber public.barbers%rowtype;
  v_timezone text;
  v_slots jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_weekday is null or p_weekday not between 0 and 6 then
    raise exception using errcode = '22023', message = 'valid weekday required';
  end if;

  select barber.* into v_barber
  from public.barbers barber
  where barber.organization_id = p_organization_id
    and barber.auth_user_id = auth.uid()
    and barber.active
    and barber.app_access_enabled;
  if not found then
    raise exception using errcode = '42501', message = 'barber schedule access denied';
  end if;

  if not exists (
    select 1 from public.agenda_environments environment
    where environment.id = p_environment_id
      and environment.organization_id = p_organization_id
      and environment.location_id = v_barber.location_id
      and environment.active
  ) then
    raise exception using errcode = '22023', message = 'select an active agenda environment';
  end if;
  if p_ignore_interval_id is not null and not exists (
    select 1 from public.work_intervals interval_row
    where interval_row.id = p_ignore_interval_id
      and interval_row.organization_id = p_organization_id
      and interval_row.barber_id = v_barber.id
      and interval_row.active
  ) then
    raise exception using errcode = '42501', message = 'work interval access denied';
  end if;

  select organization.timezone into strict v_timezone
  from public.organizations organization
  where organization.id = p_organization_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'starts_at', to_char(candidate.starts_at, 'HH24:MI'),
      'ends_at', to_char(candidate.ends_at, 'HH24:MI')
    ) order by candidate.starts_at
  ), '[]'::jsonb)
  into v_slots
  from (
    select make_time(hour_value, 0, 0) as starts_at,
      make_time(hour_value + 1, 0, 0) as ends_at
    from generate_series(8, 21) as hour_slots(hour_value)
  ) candidate
  where not exists (
    select 1 from public.work_intervals interval_row
    where interval_row.organization_id = p_organization_id
      and interval_row.active
      and interval_row.weekday = p_weekday
      and interval_row.id is distinct from p_ignore_interval_id
      and interval_row.starts_at < candidate.ends_at
      and interval_row.ends_at > candidate.starts_at
      and (interval_row.environment_id = p_environment_id or interval_row.barber_id = v_barber.id)
  )
  and not exists (
    select 1
    from public.appointments appointment
    where appointment.organization_id = p_organization_id
      and appointment.barber_id = v_barber.id
      and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
      and upper(appointment.service_period) > now()
      and (lower(appointment.service_period) at time zone v_timezone)::date >= (now() at time zone v_timezone)::date
      and extract(dow from lower(appointment.service_period) at time zone v_timezone)::smallint = p_weekday
      and (lower(appointment.service_period) at time zone v_timezone)::time < candidate.ends_at
      and (upper(appointment.service_period) at time zone v_timezone)::time > candidate.starts_at
  );

  return v_slots;
end;
$$;

revoke all on function public.get_my_barber_available_schedule_slots(uuid, smallint, uuid, uuid) from public, anon;
grant execute on function public.get_my_barber_available_schedule_slots(uuid, smallint, uuid, uuid) to authenticated;

-- Persist a cropped profile photo immediately without overwriting unsaved
-- contact fields from the personal-data form.
create or replace function public.update_my_barber_avatar(
  p_organization_id uuid,
  p_avatar_url text
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if nullif(btrim(p_avatar_url), '') is null then
    raise exception using errcode = '22023', message = 'valid barber avatar URL required';
  end if;

  update public.barbers barber
  set avatar_url = btrim(p_avatar_url), updated_at = now()
  where barber.organization_id = p_organization_id
    and barber.auth_user_id = auth.uid()
    and barber.active
    and barber.app_access_enabled
    and position(
      '/storage/v1/object/public/barber-avatars/' || p_organization_id::text || '/' || barber.id::text || '/'
      in p_avatar_url
    ) > 0;
  if not found then
    raise exception using errcode = '42501', message = 'barber avatar update denied';
  end if;
end;
$$;

revoke all on function public.update_my_barber_avatar(uuid, text) from public, anon;
grant execute on function public.update_my_barber_avatar(uuid, text) to authenticated;

-- Keep the room-row lock and existing validation path. Professionals can only
-- add or change one-hour blocks; the trigger remains the final concurrency guard.
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
  v_is_professional boolean := false;
  v_error_message text;
  v_timezone text;
  v_interval public.work_intervals%rowtype;
  v_customer_name text;
  v_conflict_start timestamp;
  v_conflict_end timestamp;
begin
  v_is_professional := exists (
    select 1 from public.barbers barber
    where barber.id = p_barber_id
      and barber.organization_id = p_organization_id
      and barber.active
      and barber.auth_user_id = auth.uid()
      and barber.app_access_enabled
  );

  if v_is_professional and p_action in ('ADD_INTERVAL', 'UPDATE_INTERVAL') then
    if p_starts_at is null or p_ends_at is null
       or p_starts_at < time '08:00' or p_starts_at >= time '22:00'
       or p_ends_at <> p_starts_at + interval '1 hour' then
      raise exception using errcode = '22023',
        message = 'Escolha um bloco disponível de uma hora entre 08:00 e 22:00.';
    end if;
  end if;

  if p_action = 'ADD_INTERVAL' and p_environment_id is null then
    if auth.uid() is null then
      raise exception using errcode = '28000', message = 'authentication required';
    end if;
    if not public.is_organization_owner(p_organization_id) and not v_is_professional then
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
          and interval_row.environment_id = environment.id
          and interval_row.active
          and interval_row.weekday = p_weekday
          and interval_row.starts_at < p_ends_at
          and interval_row.ends_at > p_starts_at
      )
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

  begin
    return public.mutate_barber_schedule_before_shared_room_schedules(
      p_organization_id, p_barber_id, p_action, p_interval_id, p_weekday,
      p_starts_at, p_ends_at, p_environment_id, p_exception_id,
      p_exception_start, p_exception_end, p_reason, p_exception_kind
    );
  exception when check_violation then
    get stacked diagnostics v_error_message = message_text;
    if p_action = 'DELETE_INTERVAL'
       and v_error_message = 'schedule interval has future appointments and cannot be changed' then
      select interval_row.* into v_interval
      from public.work_intervals interval_row
      where interval_row.id = p_interval_id
        and interval_row.organization_id = p_organization_id
        and interval_row.barber_id = p_barber_id
        and interval_row.active;
      if found then
        select organization.timezone into strict v_timezone
        from public.organizations organization
        where organization.id = p_organization_id;
        select customer.full_name,
          lower(appointment.service_period) at time zone v_timezone,
          upper(appointment.service_period) at time zone v_timezone
        into v_customer_name, v_conflict_start, v_conflict_end
        from public.appointments appointment
        join public.customers customer
          on customer.id = appointment.customer_id
         and customer.organization_id = appointment.organization_id
        where appointment.organization_id = p_organization_id
          and appointment.barber_id = p_barber_id
          and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
          and upper(appointment.service_period) > now()
          and (lower(appointment.service_period) at time zone v_timezone)::date >= (now() at time zone v_timezone)::date
          and extract(dow from lower(appointment.service_period) at time zone v_timezone)::smallint = v_interval.weekday
          and (lower(appointment.service_period) at time zone v_timezone)::time < v_interval.ends_at
          and (upper(appointment.service_period) at time zone v_timezone)::time > v_interval.starts_at
        order by lower(appointment.service_period)
        limit 1;
        if found then
          raise exception using errcode = '23514', message = format(
            'Não é possível remover o horário de %s, das %s às %s. Há um atendimento de %s em %s, das %s às %s.',
            case v_interval.weekday when 0 then 'domingo' when 1 then 'segunda-feira' when 2 then 'terça-feira' when 3 then 'quarta-feira' when 4 then 'quinta-feira' when 5 then 'sexta-feira' else 'sábado' end,
            to_char(v_interval.starts_at, 'HH24:MI'),
            to_char(v_interval.ends_at, 'HH24:MI'),
            v_customer_name,
            to_char(v_conflict_start, 'DD/MM/YYYY'),
            to_char(v_conflict_start, 'HH24:MI'),
            to_char(v_conflict_end, 'HH24:MI')
          );
        end if;
      end if;
    end if;
    raise;
  end;
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
