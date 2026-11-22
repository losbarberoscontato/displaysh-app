-- Capacity is a property of the physical room. Existing environments retain
-- their current single-booking behavior until a manager raises this value.
alter table public.agenda_environments
  add column if not exists max_simultaneous_appointments integer not null default 1;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.agenda_environments'::regclass
      and conname = 'agenda_environments_max_simultaneous_appointments_check'
  ) then
    alter table public.agenda_environments
      add constraint agenda_environments_max_simultaneous_appointments_check
      check (max_simultaneous_appointments >= 1);
  end if;
end;
$$;

-- Work intervals describe which professionals may use a room. The actual
-- appointment capacity is enforced transactionally when a booking is saved.
alter table public.work_intervals
  drop constraint if exists work_intervals_environment_no_overlap;
alter table public.appointments
  drop constraint if exists appointments_no_environment_overlap;

create index if not exists appointments_environment_capacity_period_idx
  on public.appointments using gist (organization_id, environment_id, service_period)
  where status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE');

-- VOLATILE is deliberate: an appointment trigger may have waited for the
-- environment lock, so its occupancy query must observe the preceding commit.
create or replace function public.agenda_environment_peak_occupancy(
  p_organization_id uuid,
  p_environment_id uuid,
  p_service_period tstzrange,
  p_appointment_id uuid default null
)
returns integer
language sql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
  with events as (
    select event_row.event_at, event_row.delta
    from public.appointments appointment
    cross join lateral (values
      (greatest(lower(appointment.service_period), lower(p_service_period)), 1),
      (least(upper(appointment.service_period), upper(p_service_period)), -1)
    ) as event_row(event_at, delta)
    where appointment.organization_id = p_organization_id
      and appointment.environment_id = p_environment_id
      and appointment.id is distinct from p_appointment_id
      and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
      and appointment.service_period && p_service_period
  ), grouped_events as (
    select events.event_at, sum(events.delta) as delta
    from events
    group by events.event_at
  ), occupancy as (
    select sum(grouped_events.delta) over (
      order by grouped_events.event_at rows between unbounded preceding and current row
    ) as active_count
    from grouped_events
  )
  select coalesce(max(occupancy.active_count), 0)::integer from occupancy;
$$;
revoke all on function public.agenda_environment_peak_occupancy(uuid,uuid,tstzrange,uuid) from public, anon, authenticated;

create or replace function public.guard_parallel_barber_environment_capacity()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_allow_parallel boolean := false;
  v_overlaps boolean := false;
  v_validate_appointment boolean := false;
  v_environment_capacity integer;
  v_environment_occupancy integer;
begin
  if tg_table_name = 'work_intervals' then
    if tg_op = 'UPDATE' then
      if (old.organization_id, old.barber_id) is distinct from (new.organization_id, new.barber_id) then
        perform b.id from public.barbers b
        where (b.organization_id = old.organization_id and b.id = old.barber_id)
           or (b.organization_id = new.organization_id and b.id = new.barber_id)
        order by b.organization_id, b.id for update;
      else
        perform 1 from public.barbers b
        where b.id = new.barber_id and b.organization_id = new.organization_id
        for update;
      end if;
    else
      perform 1 from public.barbers b
      where b.id = new.barber_id and b.organization_id = new.organization_id
      for update;
    end if;

    select coalesce(b.allow_parallel_environment_appointments, false)
    into v_allow_parallel
    from public.barbers b
    where b.id = new.barber_id and b.organization_id = new.organization_id;

    if new.active then
      select exists (
        select 1 from public.work_intervals wi
        where wi.organization_id = new.organization_id
          and wi.barber_id = new.barber_id
          and wi.id is distinct from new.id
          and wi.active
          and wi.weekday = new.weekday
          and int4range((extract(epoch from wi.starts_at) / 60)::integer,
                        (extract(epoch from wi.ends_at) / 60)::integer, '[)')
              && int4range((extract(epoch from new.starts_at) / 60)::integer,
                           (extract(epoch from new.ends_at) / 60)::integer, '[)')
          and (not v_allow_parallel
            or new.environment_id is null
            or wi.environment_id is null
            or wi.environment_id = new.environment_id)
      ) into v_overlaps;
      if v_overlaps then
        raise exception using errcode = '23P01', message = 'barber already has a work interval in this period';
      end if;
    end if;
    return new;
  end if;

  if tg_table_name = 'appointments' then
    if tg_op = 'UPDATE' then
      if (old.organization_id, old.barber_id) is distinct from (new.organization_id, new.barber_id) then
        perform b.id from public.barbers b
        where (b.organization_id = old.organization_id and b.id = old.barber_id)
           or (b.organization_id = new.organization_id and b.id = new.barber_id)
        order by b.organization_id, b.id for update;
      else
        perform 1 from public.barbers b
        where b.id = new.barber_id and b.organization_id = new.organization_id
        for update;
      end if;
    else
      perform 1 from public.barbers b
      where b.id = new.barber_id and b.organization_id = new.organization_id
      for update;
    end if;

    if tg_op = 'INSERT' then
      v_validate_appointment := new.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE');
    else
      v_validate_appointment := new.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
        and (old.status not in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
          or old.organization_id is distinct from new.organization_id
          or old.barber_id is distinct from new.barber_id
          or old.service_period is distinct from new.service_period
          or old.environment_id is distinct from new.environment_id);
    end if;

    if v_validate_appointment then
      select coalesce(b.allow_parallel_environment_appointments, false)
      into v_allow_parallel
      from public.barbers b
      where b.id = new.barber_id and b.organization_id = new.organization_id;

      if exists (
        select 1 from public.appointments a
        where a.organization_id = new.organization_id
          and a.barber_id = new.barber_id
          and a.id is distinct from new.id
          and a.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
          and a.service_period && new.service_period
          and (not v_allow_parallel or new.environment_id is null or a.environment_id is null)
      ) then
        raise exception using errcode = '23P01', message = 'barber is already serving a client during this period';
      end if;

      if new.environment_id is null then
        raise exception using errcode = '23P01', message = 'no active environment available for requested period';
      end if;

      -- Serializes bookings for one room across professionals. After waiting,
      -- the occupancy query sees the preceding committed appointment.
      select environment.max_simultaneous_appointments
      into v_environment_capacity
      from public.agenda_environments environment
      where environment.id = new.environment_id
        and environment.organization_id = new.organization_id
        and environment.active
      for update;
      if v_environment_capacity is null then
        raise exception using errcode = '23P01', message = 'environment is not active for this unit';
      end if;

      v_environment_occupancy := public.agenda_environment_peak_occupancy(
        new.organization_id, new.environment_id, new.service_period, new.id
      );
      if v_environment_occupancy >= v_environment_capacity then
        raise exception using errcode = '23P01', message = 'environment has reached its simultaneous appointment limit';
      end if;
    end if;
    return new;
  end if;

  raise exception using errcode = '22023', message = 'unsupported parallel capacity trigger table';
end;
$$;

revoke all on function public.guard_parallel_barber_environment_capacity() from public, anon, authenticated;

drop trigger if exists work_intervals_guard_parallel_capacity on public.work_intervals;
create trigger work_intervals_guard_parallel_capacity
  before insert or update on public.work_intervals
  for each row execute function public.guard_parallel_barber_environment_capacity();

drop trigger if exists appointments_guard_parallel_capacity on public.appointments;
create trigger appointments_guard_parallel_capacity
  before insert or update of organization_id, barber_id, service_period, environment_id, status
  on public.appointments
  for each row execute function public.guard_parallel_barber_environment_capacity();

create or replace function public.guard_agenda_environment_capacity()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_peak_occupancy integer := 0;
begin
  if new.max_simultaneous_appointments >= old.max_simultaneous_appointments then
    return new;
  end if;

  with events as (
    select lower(appointment.service_period) as event_at, 1 as delta
    from public.appointments appointment
    where appointment.organization_id = old.organization_id
      and appointment.environment_id = old.id
      and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
      and not lower_inf(appointment.service_period) and not upper_inf(appointment.service_period)
    union all
    select upper(appointment.service_period) as event_at, -1 as delta
    from public.appointments appointment
    where appointment.organization_id = old.organization_id
      and appointment.environment_id = old.id
      and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
      and not lower_inf(appointment.service_period) and not upper_inf(appointment.service_period)
  ), grouped_events as (
    select events.event_at, sum(events.delta) as delta
    from events
    group by events.event_at
  ), occupancy as (
    select sum(grouped_events.delta) over (order by grouped_events.event_at) as active_count
    from grouped_events
  )
  select coalesce(max(occupancy.active_count), 0)::integer into v_peak_occupancy
  from occupancy;

  if new.max_simultaneous_appointments < v_peak_occupancy then
    raise exception using errcode = '23514', message = 'environment capacity cannot be lower than current concurrent appointments';
  end if;
  return new;
end;
$$;

revoke all on function public.guard_agenda_environment_capacity() from public, anon, authenticated;
drop trigger if exists agenda_environments_guard_capacity on public.agenda_environments;
create trigger agenda_environments_guard_capacity
  before update of max_simultaneous_appointments on public.agenda_environments
  for each row execute function public.guard_agenda_environment_capacity();

create or replace function public.resolve_appointment_environment(
  p_organization_id uuid,
  p_barber_id uuid,
  p_location_id uuid,
  p_service_period tstzrange,
  p_environment_id uuid default null,
  p_appointment_id uuid default null
)
returns uuid
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_timezone text;
  v_local_start timestamp;
  v_local_end timestamp;
  v_environment uuid;
  v_environment_capacity integer;
  v_environment_occupancy integer;
  v_allow_parallel boolean := false;
  v_requested uuid := coalesce(
    p_environment_id,
    nullif(current_setting('app.agenda_environment_id', true), '')::uuid
  );
begin
  if isempty(p_service_period) then return null; end if;
  select organization.timezone, coalesce(barber.allow_parallel_environment_appointments, false)
  into v_timezone, v_allow_parallel
  from public.organizations organization
  join public.barbers barber on barber.organization_id = organization.id and barber.id = p_barber_id
  where organization.id = p_organization_id;
  if v_timezone is null then return null; end if;
  v_local_start := lower(p_service_period) at time zone v_timezone;
  v_local_end := upper(p_service_period) at time zone v_timezone;
  if v_local_start::date <> v_local_end::date then return null; end if;

  if v_requested is not null then
    select environment.max_simultaneous_appointments into v_environment_capacity
    from public.agenda_environments environment
    where environment.id = v_requested and environment.organization_id = p_organization_id
      and environment.location_id = p_location_id and environment.active;
    if v_environment_capacity is null then
      raise exception using errcode = '22023', message = 'environment is not active for this unit';
    end if;
    if exists (
      select 1 from public.availability_exceptions exception_row
      where exception_row.organization_id = p_organization_id and exception_row.barber_id = p_barber_id
        and exception_row.kind = 'UNAVAILABLE' and exception_row.service_period && p_service_period
    ) then
      raise exception using errcode = '22023', message = 'barber is unavailable for requested period';
    end if;
    if not exists (
      select 1 from public.availability_exceptions exception_row
      where exception_row.organization_id = p_organization_id and exception_row.barber_id = p_barber_id
        and exception_row.kind = 'AVAILABLE_OVERRIDE' and exception_row.environment_id = v_requested
        and exception_row.service_period @> p_service_period
    ) and not exists (
      select 1 from public.work_intervals interval_row
      where interval_row.organization_id = p_organization_id and interval_row.barber_id = p_barber_id
        and interval_row.environment_id = v_requested and interval_row.active
        and interval_row.weekday = extract(dow from v_local_start)::smallint
        and interval_row.starts_at <= v_local_start::time and interval_row.ends_at >= v_local_end::time
    ) then
      raise exception using errcode = '22023', message = 'environment is not assigned to barber for requested period';
    end if;
    if (not v_allow_parallel or exists (
      select 1 from public.appointments unassigned_appointment
      where unassigned_appointment.organization_id = p_organization_id and unassigned_appointment.barber_id = p_barber_id
        and unassigned_appointment.environment_id is null
        and unassigned_appointment.id is distinct from p_appointment_id
        and unassigned_appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
        and unassigned_appointment.service_period && p_service_period
    )) and exists (
      select 1 from public.appointments appointment
      where appointment.organization_id = p_organization_id and appointment.barber_id = p_barber_id
        and appointment.id is distinct from p_appointment_id
        and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
        and appointment.service_period && p_service_period
    ) then
      raise exception using errcode = '23P01', message = 'barber is already serving a client during this period';
    end if;
    v_environment_occupancy := public.agenda_environment_peak_occupancy(
      p_organization_id, v_requested, p_service_period, p_appointment_id
    );
    if v_environment_occupancy >= v_environment_capacity then
      raise exception using errcode = '23P01', message = 'environment is no longer available';
    end if;
    if exists (
      select 1 from public.walkin_queue_holds hold
      where hold.organization_id = p_organization_id and hold.barber_id = p_barber_id
        and hold.consumed_at is null and hold.expires_at > now()
        and hold.service_period && p_service_period
    ) then
      raise exception using errcode = '23P01', message = 'requested slot is no longer available';
    end if;
    return v_requested;
  end if;

  -- Legacy unassigned bookings and queue holds continue to block the whole
  -- professional because no room-level capacity can be established for them.
  if exists (
    select 1 from public.appointments appointment
    where appointment.organization_id = p_organization_id and appointment.barber_id = p_barber_id
      and appointment.environment_id is null and appointment.id is distinct from p_appointment_id
      and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
      and appointment.service_period && p_service_period
  ) then
    return null;
  end if;
  if not v_allow_parallel and exists (
    select 1 from public.appointments appointment
    where appointment.organization_id = p_organization_id and appointment.barber_id = p_barber_id
      and appointment.id is distinct from p_appointment_id
      and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
      and appointment.service_period && p_service_period
  ) then
    return null;
  end if;

  select environment.id into v_environment
  from public.agenda_environments environment
  where environment.organization_id = p_organization_id
    and environment.location_id = p_location_id and environment.active
    and (
      exists (
        select 1 from public.availability_exceptions exception_row
        where exception_row.organization_id = p_organization_id and exception_row.barber_id = p_barber_id
          and exception_row.kind = 'AVAILABLE_OVERRIDE' and exception_row.environment_id = environment.id
          and exception_row.service_period @> p_service_period
      )
      or exists (
        select 1 from public.work_intervals interval_row
        where interval_row.organization_id = p_organization_id and interval_row.barber_id = p_barber_id
          and interval_row.environment_id = environment.id and interval_row.active
          and interval_row.weekday = extract(dow from v_local_start)::smallint
          and interval_row.starts_at <= v_local_start::time and interval_row.ends_at >= v_local_end::time
      )
    )
    and public.agenda_environment_peak_occupancy(
      p_organization_id, environment.id, p_service_period, p_appointment_id
    ) < environment.max_simultaneous_appointments
    and not exists (
      select 1 from public.walkin_queue_holds hold
      where hold.organization_id = p_organization_id and hold.barber_id = p_barber_id
        and hold.consumed_at is null and hold.expires_at > now()
        and hold.service_period && p_service_period
    )
  order by environment.sort_order, environment.id
  limit 1;
  return v_environment;
end;
$$;

revoke all on function public.resolve_appointment_environment(uuid,uuid,uuid,tstzrange,uuid,uuid) from public, anon, authenticated;

-- Project-session availability is separate from the main booking slot RPC,
-- so it also needs to consider the professional opt-in and the room limit.
create or replace function public.get_project_session_environments(
  p_organization_id uuid, p_session_id uuid, p_barber_id uuid, p_service_id uuid, p_starts_at timestamptz
)
returns table (id uuid, name text, sort_order integer)
language plpgsql stable security definer set search_path = public, extensions, pg_temp as $$
declare
  v_org public.organizations%rowtype; v_session public.project_engagement_sessions%rowtype;
  v_engagement public.project_engagements%rowtype; v_package public.project_packages%rowtype;
  v_service public.services%rowtype; v_barber public.barbers%rowtype;
  v_period tstzrange; v_local_start timestamp; v_local_end timestamp; v_occupied integer;
begin
  select organization.* into strict v_org from public.organizations organization where organization.id = p_organization_id;
  select session.* into strict v_session from public.project_engagement_sessions session
   where session.id = p_session_id and session.organization_id = p_organization_id;
  select engagement.* into strict v_engagement from public.project_engagements engagement
   where engagement.id = v_session.engagement_id and engagement.organization_id = p_organization_id;
  if not public.is_organization_owner(p_organization_id) and not public.is_organization_customer(p_organization_id, v_engagement.customer_id) then
    raise exception using errcode = '42501', message = 'project session availability denied';
  end if;
  if v_session.status <> 'OPEN' then return; end if;
  if v_engagement.status <> 'ACTIVE' and not exists (select 1 from public.customer_project_cancellation_requests request
    where request.organization_id = p_organization_id and request.engagement_id = v_engagement.id
      and request.status = 'CONFIRMED' and request.last_session_id = v_session.id) then return; end if;
  if exists (select 1 from public.customer_project_cancellation_requests request where request.organization_id = p_organization_id
    and request.engagement_id = v_engagement.id and request.status = 'PENDING'
    and (request.last_session_id is null or v_session.session_number >
      (select cutoff.session_number from public.project_engagement_sessions cutoff
        where cutoff.id = request.last_session_id and cutoff.organization_id = p_organization_id))) then return; end if;
  select pkg.* into strict v_package from public.project_packages pkg
   where pkg.id = v_engagement.package_id and pkg.organization_id = p_organization_id;
  perform 1 from public.project_package_service_assignments assignment where assignment.organization_id = p_organization_id
    and assignment.project_package_id = v_package.id and assignment.service_id = p_service_id and assignment.barber_id = p_barber_id;
  if not found then return; end if;
  select service.* into strict v_service from public.services service
   where service.id = p_service_id and service.organization_id = p_organization_id and service.active;
  select barber.* into strict v_barber from public.barbers barber
   where barber.id = p_barber_id and barber.organization_id = p_organization_id and barber.active;
  if p_starts_at <= now() then return; end if;
  v_local_start := p_starts_at at time zone v_org.timezone;
  if extract(second from v_local_start) <> 0 or mod(extract(minute from v_local_start)::integer, v_org.slot_interval_minutes) <> 0 then return; end if;
  v_occupied := ceil(v_service.duration_minutes::numeric / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes;
  v_period := tstzrange(p_starts_at, p_starts_at + make_interval(mins => v_occupied), '[)');
  v_local_end := upper(v_period) at time zone v_org.timezone;
  if v_local_start::date <> v_local_end::date or exists (select 1 from public.availability_exceptions exception_row
    where exception_row.organization_id = p_organization_id and exception_row.barber_id = p_barber_id
      and exception_row.kind = 'UNAVAILABLE' and exception_row.service_period && v_period) then return; end if;
  return query select environment.id, environment.name, environment.sort_order from public.agenda_environments environment
   where environment.organization_id = p_organization_id and environment.location_id = v_barber.location_id and environment.active
     and (exists (select 1 from public.availability_exceptions exception_row where exception_row.organization_id = p_organization_id
       and exception_row.barber_id = p_barber_id and exception_row.kind = 'AVAILABLE_OVERRIDE'
       and exception_row.environment_id = environment.id and exception_row.service_period @> v_period)
       or exists (select 1 from public.work_intervals interval_row where interval_row.organization_id = p_organization_id
       and interval_row.barber_id = p_barber_id and interval_row.environment_id = environment.id and interval_row.active
       and interval_row.weekday = extract(dow from v_local_start)::smallint
       and interval_row.starts_at <= v_local_start::time and interval_row.ends_at >= v_local_end::time))
     and public.agenda_environment_peak_occupancy(p_organization_id, environment.id, v_period) < environment.max_simultaneous_appointments
     and not exists (select 1 from public.appointments unassigned_appointment where unassigned_appointment.organization_id = p_organization_id
       and unassigned_appointment.barber_id = p_barber_id and unassigned_appointment.environment_id is null
       and unassigned_appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
       and unassigned_appointment.service_period && v_period)
     and (v_barber.allow_parallel_environment_appointments or not exists (
       select 1 from public.appointments appointment where appointment.organization_id = p_organization_id
         and appointment.barber_id = p_barber_id and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
         and appointment.service_period && v_period))
     and not exists (select 1 from public.walkin_queue_holds hold where hold.organization_id = p_organization_id
       and hold.barber_id = p_barber_id and hold.consumed_at is null and hold.expires_at > now() and hold.service_period && v_period)
   order by environment.sort_order, environment.id;
exception when no_data_found then return;
end $$;
revoke all on function public.get_project_session_environments(uuid, uuid, uuid, uuid, timestamptz) from public, anon;
grant execute on function public.get_project_session_environments(uuid, uuid, uuid, uuid, timestamptz) to authenticated;

-- Subscription-bundle slot listing had an additional professional-wide
-- overlap filter that bypassed its shared environment resolver.
create or replace function public.get_customer_subscription_bundle_slots(
  p_organization_id uuid,
  p_customer_id uuid,
  p_session_id uuid,
  p_barber_id uuid,
  p_local_date date
)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_org public.organizations%rowtype;
  v_sub public.customer_subscriptions%rowtype;
  v_session public.subscription_bundle_sessions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_barber public.barbers%rowtype;
  v_source record;
  v_local_start timestamp;
  v_start timestamptz;
  v_period tstzrange;
  v_occupied integer;
  v_slots jsonb := '[]'::jsonb;
  v_seen_starts timestamptz[] := array[]::timestamptz[];
  v_today date;
begin
  if auth.uid() is null or not public.is_organization_customer(p_organization_id, p_customer_id, auth.uid()) then
    raise exception using errcode = '42501', message = 'customer booking denied';
  end if;
  select * into strict v_org from public.organizations where id = p_organization_id;
  select * into strict v_session from public.subscription_bundle_sessions
   where id = p_session_id and organization_id = p_organization_id;
  select * into strict v_sub from public.customer_subscriptions
   where id = v_session.subscription_id and organization_id = p_organization_id;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_sub.id and organization_id = p_organization_id;
  select * into strict v_version from public.subscription_plan_versions
   where id = v_sub.plan_version_id and organization_id = p_organization_id;
  select * into strict v_barber from public.barbers
   where id = p_barber_id and organization_id = p_organization_id and active;
  v_today := (now() at time zone v_org.timezone)::date;
  if v_sub.customer_id <> p_customer_id or v_sub.status <> 'ACTIVE'
     or v_contract.scheduling_mode <> 'FREE' or v_session.status <> 'AVAILABLE'
     or v_session.release_on > v_today or v_contract.first_session_date > v_today
     or exists (select 1 from public.subscription_bundle_installments installment
       where installment.organization_id = p_organization_id and installment.subscription_id = v_sub.id
         and installment.due_on < v_today and installment.status in ('OPEN', 'OVERDUE'))
     or date_trunc('month', p_local_date::timestamp)::date <> date_trunc('month', v_today::timestamp)::date
     or p_local_date < v_today
     or p_local_date < v_contract.first_session_date
     or not public.organization_accepts_new_bookings(p_organization_id) then
    raise exception using errcode = '22023', message = 'subscription bundle booking date is not available';
  end if;
  if not exists (select 1 from public.barber_services service_assignment where service_assignment.organization_id = p_organization_id
      and service_assignment.barber_id = p_barber_id and service_assignment.service_id = v_contract.service_id and service_assignment.active)
     or not exists (select 1 from public.barber_subscription_plans plan_assignment where plan_assignment.organization_id = p_organization_id
      and plan_assignment.barber_id = p_barber_id and plan_assignment.plan_id = v_sub.plan_id and plan_assignment.active)
     or not exists (select 1 from public.commission_rules commission_rule where commission_rule.organization_id = p_organization_id
      and commission_rule.barber_id = p_barber_id and commission_rule.subscription_plan_id = v_sub.plan_id
      and commission_rule.active and commission_rule.effective_period @> now()) then
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
                 greatest(lower(exception_row.service_period), p_local_date::timestamp at time zone v_org.timezone)) as local_start,
               timezone(v_org.timezone,
                 least(upper(exception_row.service_period), (p_local_date + 1)::timestamp at time zone v_org.timezone)) as local_limit
          from public.availability_exceptions exception_row
         where exception_row.organization_id = p_organization_id and exception_row.barber_id = p_barber_id
           and exception_row.kind = 'AVAILABLE_OVERRIDE'
           and exception_row.service_period && tstzrange(p_local_date::timestamp at time zone v_org.timezone,
             (p_local_date + 1)::timestamp at time zone v_org.timezone, '[)')
      ) sources where sources.local_start < sources.local_limit
      order by sources.local_start, sources.local_limit
  loop
    v_local_start := date_trunc('day', v_source.local_start) + make_interval(mins =>
      ceil(extract(epoch from (v_source.local_start - date_trunc('day', v_source.local_start))) / 60 / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes);
    while v_local_start + make_interval(mins => v_occupied) <= v_source.local_limit loop
      v_start := v_local_start at time zone v_org.timezone;
      v_period := tstzrange(v_start, v_start + make_interval(mins => v_occupied), '[)');
      if v_start > now() and not (v_start = any(v_seen_starts))
         and not public.organization_date_blocked(p_organization_id, v_period)
         and public.is_barber_available(p_organization_id, p_barber_id, v_period)
         and public.resolve_appointment_environment(p_organization_id, p_barber_id, v_barber.location_id, v_period, null) is not null
         and (v_barber.allow_parallel_environment_appointments or not exists (
           select 1 from public.appointments appointment where appointment.organization_id = p_organization_id
             and appointment.barber_id = p_barber_id and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
             and appointment.service_period && v_period)) then
        v_slots := v_slots || jsonb_build_array(jsonb_build_object('starts_at', v_start, 'ends_at', upper(v_period)));
        v_seen_starts := array_append(v_seen_starts, v_start);
      end if;
      v_local_start := v_local_start + make_interval(mins => v_org.slot_interval_minutes);
    end loop;
  end loop;
  return jsonb_build_object('duration_minutes', v_contract.session_duration_minutes,
    'occupied_minutes', v_occupied, 'total_cents', 0, 'slots', v_slots);
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle session or professional not found';
end;
$$;
revoke all on function public.get_customer_subscription_bundle_slots(uuid,uuid,uuid,uuid,date) from public, anon;
grant execute on function public.get_customer_subscription_bundle_slots(uuid,uuid,uuid,uuid,date) to authenticated;
