alter table public.customer_subscription_sessions
  add column if not exists rescheduled_from timestamptz;

update public.customer_subscription_sessions session
   set rescheduled_from = (
     select lower((event.metadata ->> 'old_period')::tstzrange)
       from public.appointment_status_events event
      where event.organization_id = session.organization_id
        and event.appointment_id = session.appointment_id
        and event.reason = 'subscription_session_rescheduled'
        and nullif(event.metadata ->> 'old_period', '') is not null
      order by event.created_at, event.id
      limit 1
   )
 where session.rescheduled_from is null
   and session.appointment_id is not null
   and exists (
     select 1 from public.appointment_status_events event
      where event.organization_id = session.organization_id
        and event.appointment_id = session.appointment_id
        and event.reason = 'subscription_session_rescheduled'
        and nullif(event.metadata ->> 'old_period', '') is not null
   );

create or replace function public.guard_subscription_reschedule_original_window()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_timezone text;
  v_original_start timestamptz;
  v_original_date date;
  v_new_date date;
begin
  if tg_op = 'UPDATE' then
    if new.service_period = old.service_period then
      return new;
    end if;
  end if;

  if new.subscription_bundle_session_id is not null then
    select coalesce(session.rescheduled_from, session.scheduled_for, session.canceled_from)
      into v_original_start
      from public.subscription_bundle_sessions session
     where session.id = new.subscription_bundle_session_id
       and session.organization_id = new.organization_id;
  elsif new.subscription_session_id is not null and tg_op = 'UPDATE' then
    select session.rescheduled_from
      into v_original_start
      from public.customer_subscription_sessions session
     where session.id = new.subscription_session_id
       and session.organization_id = new.organization_id;
    v_original_start := coalesce(v_original_start, lower(old.service_period));
  else
    return new;
  end if;

  if v_original_start is null then
    return new;
  end if;

  select organization.timezone
    into strict v_timezone
    from public.organizations organization
   where organization.id = new.organization_id;
  v_original_date := (v_original_start at time zone v_timezone)::date;
  v_new_date := (lower(new.service_period) at time zone v_timezone)::date;
  if v_new_date < v_original_date - 14 or v_new_date > v_original_date + 14 then
    raise exception using errcode = '22023',
      message = 'subscription reschedule outside original two-week window';
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_guard_subscription_reschedule_original_window
  on public.appointments;
create trigger appointments_guard_subscription_reschedule_original_window
  before insert or update of service_period on public.appointments
  for each row execute function public.guard_subscription_reschedule_original_window();

revoke all on function public.guard_subscription_reschedule_original_window()
  from public, anon, authenticated, service_role;

create or replace function public.reschedule_fixed_customer_subscription_session(
  p_organization_id uuid,
  p_subscription_session_id uuid,
  p_new_starts_at timestamptz,
  p_new_barber_id uuid
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
  v_barber public.barbers%rowtype;
  v_is_owner boolean;
  v_is_customer boolean;
  v_original_start timestamptz;
  v_original_date date;
  v_new_local_start timestamp;
  v_new_date date;
  v_duration integer;
  v_occupied integer;
  v_new_period tstzrange;
  v_environment_id uuid;
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

  select * into strict v_subscription
    from public.customer_subscriptions subscription
   where subscription.id = v_session_subscription_id
     and subscription.organization_id = p_organization_id
   for update;
  select * into strict v_appointment
    from public.appointments appointment
   where appointment.id = v_session_appointment_id
     and appointment.organization_id = p_organization_id
   for update;
  select * into strict v_session
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
  select * into strict v_plan_version
    from public.subscription_plan_versions plan_version
   where plan_version.id = v_subscription.plan_version_id
     and plan_version.organization_id = p_organization_id;
  if v_plan_version.scheduling_mode <> 'FIXED' then
    raise exception using errcode = '22023', message = 'only fixed-plan sessions can be rescheduled here';
  end if;
  if v_session.status <> 'SCHEDULED' or v_appointment.subscription_session_id is distinct from v_session.id
     or v_appointment.status <> 'CONFIRMED' then
    raise exception using errcode = '22023', message = 'subscription appointment cannot be rescheduled';
  end if;
  if lower(v_appointment.service_period) <= now() then
    raise exception using errcode = '22023', message = 'only future subscription appointments can be rescheduled';
  end if;
  if not public.organization_accepts_new_bookings(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization is not accepting reschedules';
  end if;
  if p_new_starts_at is null or p_new_starts_at <= now() then
    raise exception using errcode = '22023', message = 'appointment start must be in the future';
  end if;

  select * into strict v_organization
    from public.organizations organization
   where organization.id = p_organization_id;
  v_original_start := coalesce(v_session.rescheduled_from, lower(v_appointment.service_period));
  v_original_date := (v_original_start at time zone v_organization.timezone)::date;
  v_new_local_start := p_new_starts_at at time zone v_organization.timezone;
  v_new_date := v_new_local_start::date;
  if v_new_date < v_original_date - 14 or v_new_date > v_original_date + 14 then
    raise exception using errcode = '22023', message = 'subscription reschedule outside original two-week window';
  end if;
  if v_is_customer and not v_is_owner and exists (
    select 1 from public.customer_subscription_cycles cycle
     where cycle.organization_id = p_organization_id
       and cycle.subscription_id = v_subscription.id
       and (cycle.status = 'OVERDUE'
         or (cycle.status = 'OPEN' and cycle.due_on < (now() at time zone v_organization.timezone)::date))
  ) then
    raise exception using errcode = '22023', message = 'subscription_overdue_installment';
  end if;

  if extract(second from v_new_local_start) <> 0
     or mod(extract(minute from v_new_local_start)::integer, v_organization.slot_interval_minutes) <> 0 then
    raise exception using errcode = '22023', message = 'start time is not aligned to slot interval';
  end if;
  select * into strict v_barber
    from public.barbers barber
   where barber.id = coalesce(p_new_barber_id, v_appointment.barber_id)
     and barber.organization_id = p_organization_id
     and barber.active;
  if not exists (
    select 1 from public.barber_subscription_plans assignment
     where assignment.organization_id = p_organization_id
       and assignment.barber_id = v_barber.id
       and assignment.plan_id = v_subscription.plan_id
       and assignment.active
  ) or exists (
    select 1 from public.subscription_plan_services plan_service
     where plan_service.organization_id = p_organization_id
       and plan_service.plan_version_id = v_plan_version.id
       and not exists (
         select 1 from public.barber_services assignment
          where assignment.organization_id = p_organization_id
            and assignment.barber_id = v_barber.id
            and assignment.service_id = plan_service.service_id
            and assignment.active
       )
  ) then
    raise exception using errcode = '22023', message = 'professional is not configured for this subscription service and plan';
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
  if not public.is_barber_available(p_organization_id, v_barber.id, v_new_period) then
    raise exception using errcode = '22023', message = 'requested slot is outside the professional schedule';
  end if;
  if public.organization_date_blocked(p_organization_id, v_new_period) then
    raise exception using errcode = '22023', message = 'requested date is blocked';
  end if;
  if exists (
    select 1 from public.appointments appointment
     where appointment.organization_id = p_organization_id
       and appointment.customer_id = v_subscription.customer_id
       and appointment.id <> v_appointment.id
       and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
       and appointment.service_period && v_new_period
  ) then
    raise exception using errcode = '23P01', message = 'customer already has an appointment in this period';
  end if;
  v_environment_id := public.resolve_appointment_environment(
    p_organization_id, v_barber.id, v_barber.location_id, v_new_period, null, v_appointment.id
  );
  if v_environment_id is null then
    raise exception using errcode = '23P01', message = 'no environment is available for this professional';
  end if;

  update public.appointments
     set barber_id = v_barber.id,
         location_id = v_barber.location_id,
         environment_id = v_environment_id,
         service_period = v_new_period,
         payment_mode = 'SUBSCRIPTION',
         total_cents_snapshot = 0,
         list_total_cents_snapshot = 0,
         deposit_required_cents_snapshot = 0,
         amount_waived_cents = 0,
         cancellation_lead_minutes_snapshot = 1440,
         version = version + 1
   where id = v_appointment.id
     and organization_id = p_organization_id;

  update public.customer_subscription_sessions
     set rescheduled_from = coalesce(rescheduled_from, lower(v_appointment.service_period))
   where id = v_session.id and organization_id = p_organization_id;

  insert into public.appointment_status_events(
    organization_id, appointment_id, from_status, to_status, reason, actor_user_id, metadata
  ) values (
    p_organization_id, v_appointment.id, 'CONFIRMED', 'CONFIRMED',
    'subscription_session_rescheduled', auth.uid(),
    jsonb_build_object(
      'subscription_session_id', v_session.id,
      'old_period', v_appointment.service_period,
      'new_period', v_new_period,
      'original_start', v_original_start,
      'reschedule_window_days', 14
    )
  );
  return jsonb_build_object(
    'appointment_id', v_appointment.id,
    'subscription_session_id', v_session.id,
    'service_period', v_new_period,
    'barber_id', v_barber.id,
    'status', 'CONFIRMED'
  );
exception
  when exclusion_violation then
    raise exception using errcode = '23P01', message = 'new slot is no longer available; original appointment preserved';
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization, subscription session, appointment or professional not found';
end;
$$;

create or replace function public.reschedule_fixed_customer_subscription_session(
  p_organization_id uuid,
  p_subscription_session_id uuid,
  p_new_starts_at timestamptz
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.reschedule_fixed_customer_subscription_session(
    p_organization_id, p_subscription_session_id, p_new_starts_at, null::uuid
  );
$$;

revoke all on function public.reschedule_fixed_customer_subscription_session(uuid, uuid, timestamptz, uuid)
  from public, anon, service_role;
grant execute on function public.reschedule_fixed_customer_subscription_session(uuid, uuid, timestamptz, uuid)
  to authenticated;
revoke all on function public.reschedule_fixed_customer_subscription_session(uuid, uuid, timestamptz)
  from public, anon, service_role;
grant execute on function public.reschedule_fixed_customer_subscription_session(uuid, uuid, timestamptz)
  to authenticated;

alter function public.get_manager_subscription_bundle_slots(uuid, uuid, uuid, uuid, date)
  rename to get_manager_subscription_bundle_slots_unbounded;
revoke all on function public.get_manager_subscription_bundle_slots_unbounded(uuid, uuid, uuid, uuid, date)
  from public, anon, authenticated, service_role;

create function public.get_manager_subscription_bundle_slots(
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
set search_path = ''
as $$
declare
  v_timezone text;
  v_original_start timestamptz;
  v_original_date date;
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

  if p_session_id is not null then
    select coalesce(session.rescheduled_from, session.scheduled_for, session.canceled_from)
      into v_original_start
      from public.subscription_bundle_sessions session
     where session.id = p_session_id
       and session.subscription_id = p_subscription_id
       and session.organization_id = p_organization_id
       and session.deleted_at is null;
    if found and v_original_start is not null then
      select organization.timezone into strict v_timezone
        from public.organizations organization
       where organization.id = p_organization_id;
      v_original_date := (v_original_start at time zone v_timezone)::date;
      if p_local_date < v_original_date - 14 or p_local_date > v_original_date + 14 then
        raise exception using errcode = '22023', message = 'subscription reschedule outside original two-week window';
      end if;
    end if;
  end if;

  return public.get_manager_subscription_bundle_slots_unbounded(
    p_organization_id, p_subscription_id, p_session_id, p_barber_id, p_local_date
  );
end;
$$;
revoke all on function public.get_manager_subscription_bundle_slots(uuid, uuid, uuid, uuid, date)
  from public, anon, service_role;
grant execute on function public.get_manager_subscription_bundle_slots(uuid, uuid, uuid, uuid, date)
  to authenticated;
