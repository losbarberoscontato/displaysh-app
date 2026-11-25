-- Keep unconfirmed holds out of operational agendas and prevent overlapping
-- bookings for the same customer and attendee across every Display tenant.

alter table public.appointments
  drop constraint if exists appointments_deleted_only_when_expired;
alter table public.appointments
  add constraint appointments_deleted_when_expired_or_canceled
  check (deleted_at is null or status in ('EXPIRED', 'CANCELED'));

alter table public.appointments
  drop constraint if exists appointments_no_barber_overlap;
alter table public.appointments
  add constraint appointments_no_barber_overlap
  exclude using gist (
    organization_id with =,
    barber_id with =,
    service_period with &&
  ) where (
    status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
    and deleted_at is null
  );

alter table public.appointments
  add constraint appointments_no_customer_attendee_overlap
  exclude using gist (
    organization_id with =,
    customer_id with =,
    service_period with &&
  ) where (
    attendee_dependent_id is null
    and status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
    and deleted_at is null
  );

alter table public.appointments
  add constraint appointments_no_dependent_attendee_overlap
  exclude using gist (
    organization_id with =,
    customer_id with =,
    attendee_dependent_id with =,
    service_period with &&
  ) where (
    attendee_dependent_id is not null
    and status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
    and deleted_at is null
  );

-- Only the dedicated owner cleanup path may hide a confirmed, unpaid customer
-- booking. All normal deletions remain limited to expired holds.
create or replace function public.prevent_appointment_deletion_undo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.deleted_at is not null then
    if new.deleted_at is distinct from old.deleted_at
       or new.deleted_by_user_id is distinct from old.deleted_by_user_id then
      raise exception using errcode = '22023', message = 'appointment deletion is irreversible';
    end if;
    return new;
  end if;

  if new.deleted_at is not null then
    if auth.uid() is null
       or new.deleted_by_user_id is distinct from auth.uid()
       or not public.is_organization_owner(old.organization_id, auth.uid()) then
      raise exception using errcode = '42501', message = 'organization owner required to delete appointment';
    end if;
    if old.status = 'EXPIRED' and new.status = 'EXPIRED' then
      return new;
    end if;
    if old.status = 'CONFIRMED'
       and new.status = 'CANCELED'
       and old.source = 'CUSTOMER'
       and current_setting('app.allow_customer_booking_cleanup_delete', true) = '1' then
      return new;
    end if;
    raise exception using errcode = '22023', message = 'only expired holds or owner-canceled unpaid customer bookings can be deleted';
  elsif new.deleted_by_user_id is not null then
    raise exception using errcode = '22023', message = 'appointment deletion metadata is invalid';
  end if;

  return new;
end;
$$;

-- Suppress outbound cancellation notices only when the appointment is hidden
-- by the owner cleanup operation. Ordinary cancellations keep existing behavior.
drop trigger if exists zz_appointments_enqueue_cancellation_whatsapp on public.appointments;
create trigger zz_appointments_enqueue_cancellation_whatsapp
  after update of status on public.appointments
  for each row
  when (new.deleted_at is null)
  execute function public.enqueue_appointment_cancellation_whatsapp();

create or replace function public.create_customer_booking_hold(
  p_organization_id uuid,
  p_customer_id uuid,
  p_barber_id uuid,
  p_starts_at timestamptz,
  p_selections jsonb,
  p_idempotency_key uuid,
  p_walkin_queue_hold_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_org public.organizations%rowtype;
  v_barber public.barbers%rowtype;
  v_existing public.appointments%rowtype;
  v_previous public.appointments%rowtype;
  v_resolution jsonb;
  v_duration integer;
  v_occupied_minutes integer;
  v_period tstzrange;
  v_appointment_id uuid;
  v_total bigint;
  v_local_start timestamp;
  v_expires_at timestamptz;
  v_fingerprint text;
  v_legacy_fingerprint text;
  v_attendee_dependent_id uuid;
  v_attendee record;
begin
  if p_idempotency_key is null then
    raise exception using errcode = '22023', message = 'idempotency key is required';
  end if;
  if not public.is_organization_customer(p_organization_id, p_customer_id) then
    raise exception using errcode = '42501', message = 'customer identity does not match caller';
  end if;
  perform 1 from public.customers
  where id = p_customer_id and organization_id = p_organization_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'customer not found';
  end if;

  v_attendee_dependent_id := nullif(
    current_setting('app.customer_booking_attendee_dependent_id', true),
    ''
  )::uuid;
  select * into v_attendee
  from public.resolve_customer_attendee(
    p_organization_id, p_customer_id, v_attendee_dependent_id
  );

  v_fingerprint := md5(jsonb_build_object(
    'customer_id', p_customer_id,
    'barber_id', p_barber_id,
    'starts_at', p_starts_at,
    'selections', p_selections,
    'payment_mode', 'COUNTER',
    'attendee_dependent_id', v_attendee_dependent_id
  )::text);
  v_legacy_fingerprint := md5(jsonb_build_object(
    'customer_id', p_customer_id,
    'barber_id', p_barber_id,
    'starts_at', p_starts_at,
    'selections', p_selections,
    'payment_mode', 'COUNTER'
  )::text);

  select * into v_existing
  from public.appointments a
  where a.organization_id = p_organization_id
    and a.created_by = auth.uid()
    and a.booking_hold_idempotency_key = p_idempotency_key
  for update;
  if found then
    if v_existing.booking_hold_fingerprint is distinct from v_fingerprint
       and not (
         v_attendee_dependent_id is null
         and v_existing.attendee_dependent_id is null
         and v_existing.booking_hold_fingerprint = v_legacy_fingerprint
       ) then
      raise exception using errcode = '22023', message = 'idempotency key belongs to another booking request';
    end if;
    if v_existing.booking_hold_fingerprint is distinct from v_fingerprint then
      update public.appointments
         set booking_hold_fingerprint = v_fingerprint
       where id = v_existing.id and organization_id = p_organization_id;
    end if;
    if v_existing.status = 'HELD' and v_existing.hold_expires_at > now() then
      return jsonb_build_object(
        'appointment_id', v_existing.id,
        'status', v_existing.status,
        'expires_at', v_existing.hold_expires_at,
        'total_cents', v_existing.total_cents_snapshot,
        'amount_due_now_cents', 0,
        'service_period', v_existing.service_period
      );
    end if;
    if v_existing.status = 'CONFIRMED' then
      return jsonb_build_object(
        'appointment_id', v_existing.id,
        'status', v_existing.status,
        'expires_at', null,
        'total_cents', v_existing.total_cents_snapshot,
        'amount_due_now_cents', 0,
        'service_period', v_existing.service_period
      );
    end if;
    raise exception using errcode = '22023', message = 'appointment hold expired';
  end if;

  if not public.organization_accepts_new_bookings(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization is not accepting new bookings';
  end if;
  if p_starts_at <= now() then
    raise exception using errcode = '22023', message = 'appointment start must be in the future';
  end if;

  select * into strict v_org from public.organizations where id = p_organization_id;
  select * into strict v_barber from public.barbers
  where id = p_barber_id and organization_id = p_organization_id and active
  for update;

  v_local_start := p_starts_at at time zone v_org.timezone;
  if v_local_start::date > (now() at time zone v_org.timezone)::date + 15 then
    raise exception using errcode = '22023', message = 'appointment date outside allowed window';
  end if;
  if extract(second from v_local_start) <> 0
     or mod(extract(minute from v_local_start)::integer, v_org.slot_interval_minutes) <> 0 then
    raise exception using errcode = '22023', message = 'start time is not aligned to slot interval';
  end if;

  v_resolution := public.resolve_booking_selection(
    p_organization_id, p_barber_id, p_selections, null
  );
  v_duration := (v_resolution ->> 'duration_minutes')::integer;
  v_occupied_minutes := ceil(v_duration::numeric / v_org.slot_interval_minutes)::integer
    * v_org.slot_interval_minutes;
  v_period := tstzrange(
    p_starts_at,
    p_starts_at + make_interval(mins => v_occupied_minutes),
    '[)'
  );
  perform public.expire_conflicting_appointment_holds(
    p_organization_id, p_barber_id, v_period
  );
  select * into v_previous
  from public.appointments a
  where a.organization_id = p_organization_id
    and a.customer_id = p_customer_id
    and a.created_by = auth.uid()
    and a.attendee_dependent_id is not distinct from v_attendee_dependent_id
    and a.status = 'HELD'
    and a.hold_expires_at > now()
  order by a.hold_expires_at desc
  limit 1
  for update;
  if found then
    if v_previous.booking_hold_fingerprint = v_fingerprint then
      return jsonb_build_object(
        'appointment_id', v_previous.id,
        'status', v_previous.status,
        'expires_at', v_previous.hold_expires_at,
        'total_cents', v_previous.total_cents_snapshot,
        'amount_due_now_cents', 0,
        'service_period', v_previous.service_period
      );
    end if;
    raise exception using errcode = '55000', message = 'customer already has an active booking hold';
  end if;

  if p_walkin_queue_hold_id is not null then
    perform 1 from public.walkin_queue_holds h
    where h.id = p_walkin_queue_hold_id
      and h.organization_id = p_organization_id
      and h.barber_id = p_barber_id
      and h.consumed_at is null
      and h.expires_at > now()
      and lower(h.service_period) = p_starts_at
    for update;
    if not found then
      raise exception using errcode = '22023', message = 'appointment hold expired';
    end if;
  end if;

  if exists (
    select 1 from public.walkin_queue_holds h
    where h.organization_id = p_organization_id
      and h.barber_id = p_barber_id
      and h.consumed_at is null
      and h.expires_at > now()
      and h.service_period && v_period
      and h.id is distinct from p_walkin_queue_hold_id
  ) or not public.is_barber_available(p_organization_id, p_barber_id, v_period) then
    raise exception using errcode = '23P01', message = 'requested slot is no longer available';
  end if;

  v_total := (v_resolution ->> 'total_cents')::bigint;
  v_expires_at := now() + make_interval(mins => v_org.hold_duration_minutes);
  insert into public.appointments (
    organization_id, location_id, customer_id, attendee_dependent_id,
    attendee_name_snapshot, attendee_relationship_snapshot, barber_id,
    status, source, service_period, hold_expires_at, payment_mode, currency,
    total_cents_snapshot, list_total_cents_snapshot, deposit_bps_snapshot,
    deposit_required_cents_snapshot, cancellation_lead_minutes_snapshot,
    created_by, booking_hold_idempotency_key, booking_hold_fingerprint
  ) values (
    p_organization_id, v_barber.location_id, p_customer_id,
    v_attendee.attendee_dependent_id, v_attendee.attendee_name,
    v_attendee.attendee_relationship, p_barber_id,
    'HELD', 'CUSTOMER', v_period, v_expires_at, 'COUNTER', v_org.currency,
    v_total, (v_resolution ->> 'list_total_cents')::bigint, 0, 0,
    v_org.cancellation_lead_minutes, auth.uid(), p_idempotency_key, v_fingerprint
  ) returning id into v_appointment_id;

  perform public.insert_resolved_appointment_items(
    v_appointment_id, p_organization_id, v_resolution
  );
  if p_walkin_queue_hold_id is not null then
    update public.walkin_queue_holds
    set consumed_at = now()
    where id = p_walkin_queue_hold_id;
  end if;
  insert into public.appointment_status_events (
    organization_id, appointment_id, to_status, reason, actor_user_id
  ) values (
    p_organization_id, v_appointment_id, 'HELD',
    'customer_booking_hold_created', auth.uid()
  );

  return jsonb_build_object(
    'appointment_id', v_appointment_id,
    'status', 'HELD',
    'expires_at', v_expires_at,
    'total_cents', v_total,
    'amount_due_now_cents', 0,
    'service_period', v_period
  );
exception
  when exclusion_violation then
    raise exception using errcode = '23P01', message = 'requested slot is no longer available';
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization or barber not found';
end;
$$;

create or replace function public.create_customer_booking_hold(
  p_organization_id uuid,
  p_customer_id uuid,
  p_barber_id uuid,
  p_starts_at timestamptz,
  p_selections jsonb,
  p_idempotency_key uuid,
  p_walkin_queue_hold_id uuid,
  p_attendee_dependent_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform set_config(
    'app.customer_booking_attendee_dependent_id',
    coalesce(p_attendee_dependent_id::text, ''),
    true
  );
  return public.create_customer_booking_hold(
    p_organization_id, p_customer_id, p_barber_id, p_starts_at,
    p_selections, p_idempotency_key, p_walkin_queue_hold_id
  );
end;
$$;

revoke all on function public.create_customer_booking_hold(
  uuid, uuid, uuid, timestamptz, jsonb, uuid, uuid, uuid
) from public, anon;
grant execute on function public.create_customer_booking_hold(
  uuid, uuid, uuid, timestamptz, jsonb, uuid, uuid, uuid
) to authenticated;

create or replace function public.book_customer_subscription_session(
  p_organization_id uuid,
  p_customer_id uuid,
  p_subscription_session_id uuid,
  p_barber_id uuid,
  p_starts_at timestamptz,
  p_attendee_dependent_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if not public.is_organization_owner(p_organization_id)
     and not public.is_organization_customer(p_organization_id, p_customer_id) then
    raise exception using errcode = '42501', message = 'customer booking denied';
  end if;
  perform set_config(
    'app.customer_booking_attendee_dependent_id',
    coalesce(p_attendee_dependent_id::text, ''),
    true
  );
  return public.book_customer_subscription_session(
    p_organization_id, p_customer_id, p_subscription_session_id,
    p_barber_id, p_starts_at
  );
end;
$$;

revoke all on function public.book_customer_subscription_session(
  uuid, uuid, uuid, uuid, timestamptz, uuid
) from public, anon;
grant execute on function public.book_customer_subscription_session(
  uuid, uuid, uuid, uuid, timestamptz, uuid
) to authenticated;

create or replace function public.book_customer_subscription_bundle_session(
  p_organization_id uuid,
  p_customer_id uuid,
  p_session_id uuid,
  p_barber_id uuid,
  p_starts_at timestamptz,
  p_attendee_dependent_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if not public.is_organization_customer(p_organization_id, p_customer_id) then
    raise exception using errcode = '42501', message = 'customer booking denied';
  end if;
  perform set_config(
    'app.customer_booking_attendee_dependent_id',
    coalesce(p_attendee_dependent_id::text, ''),
    true
  );
  return public.book_customer_subscription_bundle_session(
    p_organization_id, p_customer_id, p_session_id, p_barber_id, p_starts_at
  );
end;
$$;

revoke all on function public.book_customer_subscription_bundle_session(
  uuid, uuid, uuid, uuid, timestamptz, uuid
) from public, anon;
grant execute on function public.book_customer_subscription_bundle_session(
  uuid, uuid, uuid, uuid, timestamptz, uuid
) to authenticated;

create or replace function public.create_subscription_bundle_appointment(
  p_organization_id uuid,
  p_customer_id uuid,
  p_subscription_id uuid,
  p_session_id uuid,
  p_barber_id uuid,
  p_environment_id uuid,
  p_starts_at timestamptz,
  p_actor_id uuid,
  p_source public.booking_source
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_org public.organizations%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_service public.services%rowtype;
  v_barber public.barbers%rowtype;
  v_period tstzrange;
  v_occupied integer;
  v_appointment_id uuid;
  v_commission_mode public.commission_mode;
  v_commission_percentage_bps integer;
  v_commission_fixed_cents bigint;
  v_session_number smallint;
  v_resolved_environment_id uuid;
  v_attendee_dependent_id uuid;
  v_attendee record;
begin
  v_attendee_dependent_id := nullif(
    current_setting('app.customer_booking_attendee_dependent_id', true),
    ''
  )::uuid;
  select * into v_attendee
  from public.resolve_customer_attendee(
    p_organization_id, p_customer_id, v_attendee_dependent_id
  );

  select * into strict v_org from public.organizations where id = p_organization_id;
  select version.* into strict v_version
    from public.customer_subscriptions sub
    join public.subscription_plan_versions version
      on version.id = sub.plan_version_id and version.organization_id = sub.organization_id
   where sub.id = p_subscription_id and sub.organization_id = p_organization_id;
  select * into strict v_service from public.services
   where id = v_version.bundle_service_id and organization_id = p_organization_id and active;
  select * into strict v_barber from public.barbers
   where id = p_barber_id and organization_id = p_organization_id and active;
  if not exists (
       select 1 from public.barber_services bs
       where bs.organization_id = p_organization_id and bs.barber_id = p_barber_id
         and bs.service_id = v_service.id and bs.active
     )
     or not exists (
       select 1 from public.barber_subscription_plans bp
       where bp.organization_id = p_organization_id and bp.barber_id = p_barber_id
         and bp.plan_id = v_version.plan_id and bp.active
     ) then
    raise exception using errcode = '22023', message = 'professional is not configured for this subscription service and plan';
  end if;
  select snapshot.mode, snapshot.percentage_bps, snapshot.fixed_cents
    into v_commission_mode, v_commission_percentage_bps, v_commission_fixed_cents
    from public.subscription_bundle_commission_snapshot(
      p_organization_id, v_version.plan_id, p_barber_id, p_starts_at
    ) snapshot;
  if v_commission_mode is null then
    raise exception using errcode = '22023', message = 'professional subscription commission is not configured';
  end if;
  if extract(second from p_starts_at at time zone v_org.timezone) <> 0
     or mod(extract(minute from p_starts_at at time zone v_org.timezone)::integer, v_org.slot_interval_minutes) <> 0 then
    raise exception using errcode = '22023', message = 'start time is not aligned to the organization slot interval';
  end if;
  v_occupied := ceil(v_version.bundle_session_duration_minutes::numeric / v_org.slot_interval_minutes)::integer
    * v_org.slot_interval_minutes;
  v_period := tstzrange(p_starts_at, p_starts_at + make_interval(mins => v_occupied), '[)');
  v_resolved_environment_id := public.resolve_appointment_environment(
    p_organization_id, p_barber_id, v_barber.location_id, v_period, p_environment_id
  );
  if public.organization_date_blocked(p_organization_id, v_period)
     or not public.is_barber_available(p_organization_id, p_barber_id, v_period)
     or v_resolved_environment_id is null
     or exists (
       select 1 from public.appointments appointment
       where appointment.organization_id = p_organization_id
         and appointment.customer_id = p_customer_id
         and appointment.attendee_dependent_id is not distinct from v_attendee.attendee_dependent_id
         and appointment.deleted_at is null
         and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
         and appointment.service_period && v_period
     ) then
    raise exception using errcode = '23P01', message = 'requested subscription time is no longer available';
  end if;
  select session_number into strict v_session_number
    from public.subscription_bundle_sessions
   where id = p_session_id and organization_id = p_organization_id
   for update;
  perform set_config('app.agenda_environment_id', v_resolved_environment_id::text, true);
  insert into public.appointments(
    organization_id, location_id, customer_id, barber_id,
    attendee_dependent_id, attendee_name_snapshot, attendee_relationship_snapshot,
    status, source, service_period, payment_mode, currency,
    total_cents_snapshot, list_total_cents_snapshot, deposit_bps_snapshot,
    deposit_required_cents_snapshot, cancellation_lead_minutes_snapshot,
    notes, created_by, subscription_bundle_session_id
  ) values (
    p_organization_id, v_barber.location_id, p_customer_id, p_barber_id,
    v_attendee.attendee_dependent_id, v_attendee.attendee_name,
    v_attendee.attendee_relationship, 'CONFIRMED', p_source, v_period,
    'SUBSCRIPTION', v_org.currency, 0, 0, v_org.deposit_bps, 0,
    v_org.cancellation_lead_minutes,
    'Sessão de plano de assinatura · nº ' || v_session_number,
    p_actor_id, p_session_id
  ) returning id into v_appointment_id;
  insert into public.appointment_items(
    organization_id, appointment_id, selection_key, source, service_id,
    service_name_snapshot, quantity, charged_price_cents_snapshot,
    list_price_cents_snapshot, duration_minutes_snapshot, commission_mode_snapshot,
    commission_fixed_cents_snapshot, position
  ) values (
    p_organization_id, v_appointment_id, v_service.id, 'SERVICE', v_service.id,
    v_service.name, 1, 0, v_service.price_cents,
    v_version.bundle_session_duration_minutes, 'FIXED', 0, 0
  );
  update public.subscription_bundle_sessions
     set appointment_id = v_appointment_id, barber_id = p_barber_id,
         environment_id = v_resolved_environment_id, scheduled_for = p_starts_at,
         status = 'SCHEDULED', commission_mode = v_commission_mode,
         commission_percentage_bps = v_commission_percentage_bps,
         commission_fixed_cents = v_commission_fixed_cents
   where id = p_session_id and organization_id = p_organization_id;
  insert into public.appointment_status_events(
    organization_id, appointment_id, to_status, reason, actor_user_id, metadata
  ) values (
    p_organization_id, v_appointment_id, 'CONFIRMED',
    'subscription_bundle_session_booking', p_actor_id,
    jsonb_build_object(
      'subscription_id', p_subscription_id,
      'subscription_bundle_session_id', p_session_id
    )
  );
  return v_appointment_id;
end;
$$;

revoke all on function public.create_subscription_bundle_appointment(
  uuid, uuid, uuid, uuid, uuid, uuid, timestamptz, uuid, public.booking_source
) from public, anon, authenticated, service_role;

create or replace function public.delete_unpaid_customer_appointment(
  p_organization_id uuid,
  p_appointment_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_appointment public.appointments%rowtype;
  v_net_paid bigint;
  v_outcome text;
  v_actor_name text;
  v_cancelled_at timestamptz := clock_timestamp();
begin
  if p_organization_id is null or p_appointment_id is null then
    raise exception using errcode = '22023', message = 'organization and appointment are required';
  end if;
  if auth.uid() is null or not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization owner required';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id and organization_id = p_organization_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'appointment not found';
  end if;
  if v_appointment.deleted_at is not null then
    return jsonb_build_object(
      'appointment_id', v_appointment.id, 'status', v_appointment.status,
      'deleted', true, 'already_deleted', true
    );
  end if;
  if v_appointment.source <> 'CUSTOMER'
     or v_appointment.status <> 'CONFIRMED'
     or v_appointment.payment_mode <> 'COUNTER' then
    raise exception using errcode = '22023', message = 'only confirmed counter bookings created by customers can use this cleanup';
  end if;

  select coalesce(sum(case
    when kind in ('CAPTURE', 'ADJUSTMENT') then amount_cents
    when kind in ('REFUND', 'REVERSAL') then -amount_cents
  end), 0)::bigint into v_net_paid
  from public.payment_transactions
  where appointment_id = v_appointment.id
    and organization_id = p_organization_id;
  if greatest(v_net_paid, 0) > 0 or exists (
    select 1 from public.barber_cash_receipts receipt
    where receipt.appointment_id = v_appointment.id
      and receipt.organization_id = p_organization_id
      and receipt.status = 'RECONCILED'
  ) then
    raise exception using errcode = '22023', message = 'paid appointments require a financial reversal before cleanup';
  end if;

  select nullif(btrim(profile.display_name), '') into v_actor_name
  from public.profiles profile
  where profile.id = auth.uid();
  v_actor_name := coalesce(v_actor_name, 'Proprietário do estabelecimento');
  v_outcome := public.subscription_cancellation_outcome(
    v_appointment.service_period,
    v_appointment.cancellation_lead_minutes_snapshot
  );

  perform set_config('app.allow_customer_booking_cleanup_delete', '1', true);
  update public.appointments
     set status = 'CANCELED', hold_expires_at = null,
         amount_waived_cents = total_cents_snapshot,
         version = version + 1,
         cancellation_outcome = v_outcome,
         cancellation_actor_name = v_actor_name,
         cancelled_at = v_cancelled_at,
         cancellation_source = 'MANAGER',
         deleted_at = v_cancelled_at,
         deleted_by_user_id = auth.uid(),
         updated_at = v_cancelled_at
   where id = p_appointment_id and organization_id = p_organization_id;

  insert into public.appointment_status_events(
    organization_id, appointment_id, from_status, to_status,
    reason, actor_user_id, metadata
  ) values (
    p_organization_id, p_appointment_id, v_appointment.status, 'CANCELED',
    'owner_requested_unpaid_customer_booking_cleanup', auth.uid(),
    jsonb_build_object(
      'deleted_at', v_cancelled_at,
      'cancellation_outcome', v_outcome,
      'cancellation_actor_name', v_actor_name,
      'outbound_notifications_suppressed', true
    )
  );

  update public.payment_orders
     set status = 'CANCELED', failure_code = 'APPOINTMENT_CANCELED',
         failure_message = 'Uncaptured payment canceled with appointment'
   where appointment_id = p_appointment_id
     and organization_id = p_organization_id
     and kind in ('DEPOSIT', 'FULL', 'BALANCE')
     and status in ('CREATED', 'PENDING', 'REQUIRES_ACTION');

  update public.whatsapp_confirmation_requests_v2
     set status = 'EXPIRED', updated_at = v_cancelled_at
   where appointment_id = p_appointment_id
     and organization_id = p_organization_id
     and status = 'PENDING';
  update public.whatsapp_automation_jobs
     set status = 'CANCELED',
         last_error_code = 'OWNER_CLEANUP',
         updated_at = v_cancelled_at
   where appointment_id = p_appointment_id
     and organization_id = p_organization_id
     and status in ('PENDING', 'RETRY');

  return jsonb_build_object(
    'appointment_id', p_appointment_id, 'status', 'CANCELED',
    'deleted', true, 'already_deleted', false
  );
end;
$$;

revoke all on function public.delete_unpaid_customer_appointment(uuid, uuid)
  from public, anon;
grant execute on function public.delete_unpaid_customer_appointment(uuid, uuid)
  to authenticated;
