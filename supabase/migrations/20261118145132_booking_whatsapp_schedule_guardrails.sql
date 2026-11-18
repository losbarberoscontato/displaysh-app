-- Guard booking reminders and confirmation requests to operationally confirmed
-- appointments, and exclude the appointment being updated from its schedule check.

create or replace function public.is_barber_available_for_appointment(
  p_organization_id uuid,
  p_barber_id uuid,
  p_service_period tstzrange,
  p_appointment_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_location uuid;
begin
  select b.location_id into v_location
  from public.barbers b
  where b.id = p_barber_id
    and b.organization_id = p_organization_id
    and b.active;
  if v_location is null then return false; end if;

  if exists (
    select 1
    from public.availability_exceptions ae
    where ae.organization_id = p_organization_id
      and ae.barber_id = p_barber_id
      and ae.kind = 'UNAVAILABLE'
      and ae.service_period && p_service_period
  ) then
    return false;
  end if;

  return public.resolve_appointment_environment(
    p_organization_id,
    p_barber_id,
    v_location,
    p_service_period,
    null,
    p_appointment_id
  ) is not null;
end;
$$;

revoke all on function public.is_barber_available_for_appointment(uuid, uuid, tstzrange, uuid)
  from public, anon, authenticated, service_role;

create or replace function public.enforce_appointment_schedule_lock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status in ('HELD','PENDING_PAYMENT','CONFIRMED','IN_SERVICE') then
    perform 1 from public.barbers b
    where b.id = new.barber_id and b.organization_id = new.organization_id
    for key share;
    if not found then
      raise exception using errcode = 'P0002', message = 'appointment barber not found';
    end if;
    if new.schedule_override_reason is null
       and not public.is_barber_available_for_appointment(
         new.organization_id, new.barber_id, new.service_period, new.id
       ) then
      raise exception using errcode = '23514', message = 'appointment is outside the current barber schedule';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_appointment_schedule_lock() from public, anon, authenticated;

create or replace function public.schedule_whatsapp_v2_for_appointment()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_connection public.whatsapp_business_connections%rowtype;
  v_settings public.whatsapp_automation_settings_v2%rowtype;
  v_customer public.customers%rowtype;
  v_barber public.barbers%rowtype;
  v_org public.organizations%rowtype;
  v_start timestamptz;
  v_confirmed_transition boolean := new.status = 'CONFIRMED'
    and (tg_op = 'INSERT' or old.status is distinct from 'CONFIRMED');
  v_changed boolean := tg_op = 'UPDATE' and (
    old.service_period is distinct from new.service_period
    or old.barber_id is distinct from new.barber_id
    or old.customer_id is distinct from new.customer_id
    or old.version is distinct from new.version
  );
  v_client_consented boolean;
  v_service_names text;
  v_payload jsonb;
  v_fixed_subscription boolean := false;
begin
  if new.status in ('CANCELED', 'COMPLETED', 'EXPIRED', 'IN_SERVICE', 'NO_SHOW') then
    update public.whatsapp_automation_jobs
    set status = 'CANCELED',
        updated_at = now(),
        locked_by = null,
        lease_token = null,
        lock_expires_at = null,
        last_error_code = case
          when new.status = 'CANCELED' then 'APPOINTMENT_CANCELED'
          when new.status = 'EXPIRED' then 'APPOINTMENT_EXPIRED'
          else 'APPOINTMENT_COMPLETED'
        end
    where appointment_id = new.id
      and organization_id = new.organization_id
      and job_type in ('REMINDER_T24_CLIENT', 'REMINDER_MORNING_CLIENT', 'REMINDER_T180_CLIENT', 'REMINDER_T45_CLIENT')
      and (status in ('PENDING', 'RETRY') or (status = 'PROCESSING' and send_started_at is null));

    update public.whatsapp_confirmation_requests_v2
    set status = 'EXPIRED', updated_at = now()
    where appointment_id = new.id
      and organization_id = new.organization_id
      and status = 'PENDING';
    return new;
  end if;

  if not (tg_op = 'INSERT' or v_confirmed_transition or v_changed) then return new; end if;
  select * into v_connection
  from public.whatsapp_business_connections
  where organization_id = new.organization_id and provider = 'QR_WEB' and is_active
  order by updated_at desc limit 1;
  if not found then return new; end if;
  select * into v_settings
  from public.whatsapp_automation_settings_v2
  where organization_id = new.organization_id;
  if not found or v_settings.mode <> 'ACTIVE' or v_settings.dispatch_paused then return new; end if;

  if v_changed then
    update public.whatsapp_automation_jobs
    set status = 'CANCELED', updated_at = now(), last_error_code = 'APPOINTMENT_VERSION_SUPERSEDED'
    where appointment_id = new.id and organization_id = new.organization_id
      and appointment_version <> new.version
      and (status in ('PENDING', 'RETRY') or (status = 'PROCESSING' and send_started_at is null));
    update public.whatsapp_confirmation_requests_v2
    set status = 'SUPERSEDED', updated_at = now()
    where appointment_id = new.id and organization_id = new.organization_id
      and appointment_version <> new.version and status = 'PENDING';
  end if;

  v_fixed_subscription := public.appointment_uses_fixed_subscription_schedule(new.organization_id, new.id);

  select * into strict v_customer from public.customers
  where id = new.customer_id and organization_id = new.organization_id;
  select * into strict v_barber from public.barbers
  where id = new.barber_id and organization_id = new.organization_id;
  select * into strict v_org from public.organizations where id = new.organization_id;
  select coalesce(nullif(string_agg(ai.service_name_snapshot, ', ' order by ai.position), ''), 'Serviço não informado')
  into v_service_names
  from public.appointment_items ai
  where ai.organization_id = new.organization_id and ai.appointment_id = new.id;
  v_client_consented := public.whatsapp_v2_consented(new.organization_id, new.customer_id);
  v_start := lower(new.service_period);
  v_payload := jsonb_build_object(
    'customer_name', v_customer.full_name,
    'barber_name', v_barber.display_name,
    'service_names', v_service_names,
    'starts_at', v_start,
    'timezone', v_org.timezone,
    'currency', new.currency,
    'total_cents', new.total_cents_snapshot,
    'templates', public.whatsapp_v2_default_message_templates() || v_settings.templates
  );

  if not v_fixed_subscription and v_confirmed_transition
     and v_settings.booking_client_enabled
     and v_customer.phone_e164 is not null and v_client_consented then
    insert into public.whatsapp_automation_jobs (
      organization_id, connection_id, appointment_id, appointment_version,
      job_type, recipient_e164, payload, valid_until, dedupe_key
    ) values (
      new.organization_id, v_connection.id, new.id, new.version,
      'BOOKING_CREATED_CLIENT', v_customer.phone_e164, v_payload, v_start,
      'v2:' || new.id || ':v' || new.version || ':booking:client'
    ) on conflict (organization_id, dedupe_key) do nothing;
  end if;
  if not v_fixed_subscription and v_confirmed_transition
     and v_settings.booking_staff_enabled and v_settings.staff_notifications_enabled
     and v_barber.whatsapp_e164 is not null then
    insert into public.whatsapp_automation_jobs (
      organization_id, connection_id, appointment_id, appointment_version,
      job_type, recipient_e164, payload, valid_until, dedupe_key
    ) values (
      new.organization_id, v_connection.id, new.id, new.version,
      'BOOKING_CREATED_STAFF', v_barber.whatsapp_e164, v_payload, v_start,
      'v2:' || new.id || ':v' || new.version || ':booking:staff'
    ) on conflict (organization_id, dedupe_key) do nothing;
  end if;

  if v_start > now() and v_confirmed_transition then
    perform public.whatsapp_v2_enqueue_presence_reminder(
      new.organization_id, new.id, v_connection.id, v_settings.templates
    );
  end if;
  return new;
end;
$$;

revoke all on function public.schedule_whatsapp_v2_for_appointment() from public, anon, authenticated;

-- Repair stale requests/jobs created before this migration. Submitted sends are
-- deliberately preserved because the provider may already have delivered them.
update public.whatsapp_confirmation_requests_v2 request
set status = 'EXPIRED', updated_at = now()
from public.appointments appointment
where request.organization_id = appointment.organization_id
  and request.appointment_id = appointment.id
  and appointment.status <> 'CONFIRMED'
  and request.status = 'PENDING';

update public.whatsapp_automation_jobs job
set status = 'CANCELED',
    updated_at = now(),
    locked_by = null,
    lease_token = null,
    lock_expires_at = null,
    last_error_code = case
      when appointment.status = 'CANCELED' then 'APPOINTMENT_CANCELED'
      when appointment.status = 'EXPIRED' then 'APPOINTMENT_EXPIRED'
      when appointment.status in ('COMPLETED', 'IN_SERVICE', 'NO_SHOW') then 'APPOINTMENT_COMPLETED'
      else 'APPOINTMENT_NOT_CONFIRMED'
    end
from public.appointments appointment
where job.organization_id = appointment.organization_id
  and job.appointment_id = appointment.id
  and appointment.status <> 'CONFIRMED'
  and job.job_type in ('REMINDER_T24_CLIENT', 'REMINDER_MORNING_CLIENT', 'REMINDER_T180_CLIENT', 'REMINDER_T45_CLIENT')
  and (job.status in ('PENDING', 'RETRY') or (job.status = 'PROCESSING' and job.send_started_at is null));
