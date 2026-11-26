begin;

-- Work intervals may share a room only when their weekly time ranges do not
-- overlap. Lock the environment row first so concurrent changes serialize.
create or replace function public.guard_work_interval_room_schedule_conflict()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_environment_id uuid;
begin
  if not new.active or new.environment_id is null then
    return new;
  end if;

  select environment.id into v_environment_id
  from public.agenda_environments environment
  where environment.id = new.environment_id
    and environment.organization_id = new.organization_id
    and environment.active
  for update;
  if v_environment_id is null then
    raise exception using errcode = '23P01', message = 'environment is not active for this unit';
  end if;

  if exists (
    select 1 from public.work_intervals interval_row
    where interval_row.organization_id = new.organization_id
      and interval_row.environment_id = new.environment_id
      and interval_row.id is distinct from new.id
      and interval_row.active
      and interval_row.weekday = new.weekday
      and interval_row.starts_at < new.ends_at
      and interval_row.ends_at > new.starts_at
  ) then
    raise exception using errcode = '23P01', message = 'environment already has a work interval in this period';
  end if;

  return new;
end;
$$;

revoke all on function public.guard_work_interval_room_schedule_conflict() from public, anon, authenticated, service_role;

drop trigger if exists work_intervals_z_guard_room_schedule_conflict on public.work_intervals;
create trigger work_intervals_z_guard_room_schedule_conflict
  before insert or update on public.work_intervals
  for each row execute function public.guard_work_interval_room_schedule_conflict();

-- Keep auto-assignment working for older callers, but select only a room whose
-- weekly schedule has no overlapping professional interval.
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

commit;
