-- Combina apenas mensagens do cliente quando o lembrete de presença já venceu
-- no momento da reserva. O job de equipe e suas cópias para auxiliares ficam intactos.
create or replace function public.coalesce_immediate_client_booking_notice()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking_job_id uuid;
  v_connection_id uuid;
  v_presence_job_id uuid;
begin
  if new.status <> 'CONFIRMED'
     or lower(new.service_period) <= now()
     or public.appointment_uses_fixed_subscription_schedule(new.organization_id, new.id) then
    return new;
  end if;

  select job.id, job.connection_id
  into v_booking_job_id, v_connection_id
  from public.whatsapp_automation_jobs job
  where job.organization_id = new.organization_id
    and job.appointment_id = new.id
    and job.appointment_version = new.version
    and job.job_type = 'BOOKING_CREATED_CLIENT'
    and job.status = 'PENDING'
  order by job.created_at desc, job.id desc
  limit 1
  for update;
  if v_booking_job_id is null then return new; end if;

  select job.id
  into v_presence_job_id
  from public.whatsapp_automation_jobs job
  where job.organization_id = new.organization_id
    and job.connection_id = v_connection_id
    and job.appointment_id = new.id
    and job.appointment_version = new.version
    and job.job_type in (
      'REMINDER_T24_CLIENT',
      'REMINDER_MORNING_CLIENT',
      'REMINDER_T180_CLIENT',
      'REMINDER_T45_CLIENT'
    )
    and job.status = 'PENDING'
    and job.scheduled_for <= now()
    and job.valid_until > now()
    and job.send_started_at is null
  order by job.scheduled_for desc, job.created_at desc, job.id desc
  limit 1
  for update;
  if v_presence_job_id is null then return new; end if;

  update public.whatsapp_automation_jobs
  set payload = payload || jsonb_build_object('immediate_booking_confirmation', true),
      updated_at = now()
  where id = v_presence_job_id
    and organization_id = new.organization_id
    and status = 'PENDING';

  update public.whatsapp_automation_jobs
  set status = 'CANCELED',
      last_error_code = 'COALESCED_WITH_IMMEDIATE_PRESENCE',
      updated_at = now()
  where id = v_booking_job_id
    and organization_id = new.organization_id
    and status = 'PENDING';

  return new;
end;
$$;

revoke all on function public.coalesce_immediate_client_booking_notice()
from public, anon, authenticated;

drop trigger if exists zzzzzz_appointments_coalesce_immediate_client_booking_notice
on public.appointments;

create trigger zzzzzz_appointments_coalesce_immediate_client_booking_notice
after insert or update on public.appointments
for each row execute function public.coalesce_immediate_client_booking_notice();

-- Presence reminders and response requests are valid only after the appointment
-- is operationally confirmed. Settings rebuilds can run for pending appointments,
-- so enforce this both when queuing and immediately before provider delivery.
create or replace function public.whatsapp_v2_enqueue_presence_reminder(
  p_organization_id uuid,
  p_appointment_id uuid,
  p_connection_id uuid,
  p_templates jsonb,
  p_dedupe_suffix text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_appointment public.appointments%rowtype;
  v_settings public.whatsapp_automation_settings_v2%rowtype;
  v_customer public.customers%rowtype;
  v_barber public.barbers%rowtype;
  v_org public.organizations%rowtype;
  v_reminder_type public.whatsapp_v2_job_type;
  v_reminder_name text;
  v_reminder_at timestamptz;
  v_start timestamptz;
  v_service_names text;
  v_payload jsonb;
  v_dedupe_key text;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id and organization_id = p_organization_id;
  if not found or v_appointment.version is null
     or v_appointment.status <> 'CONFIRMED' then
    return false;
  end if;

  v_start := lower(v_appointment.service_period);
  if v_start <= now() then return false; end if;

  select * into v_settings
  from public.whatsapp_automation_settings_v2
  where organization_id = p_organization_id;
  if not found then return false; end if;
  select * into v_org from public.organizations where id = p_organization_id;
  if not found then return false; end if;

  if v_settings.reminder_t24_enabled then
    v_reminder_type := 'REMINDER_T24_CLIENT';
    v_reminder_name := 't24';
    v_reminder_at := v_start - interval '24 hours';
  elsif v_settings.reminder_morning_enabled then
    v_reminder_type := 'REMINDER_MORNING_CLIENT';
    v_reminder_name := 'morning';
    v_reminder_at := ((v_start at time zone v_org.timezone)::date + v_settings.morning_local_time) at time zone v_org.timezone;
  elsif v_settings.reminder_t180_enabled then
    v_reminder_type := 'REMINDER_T180_CLIENT';
    v_reminder_name := 't180';
    v_reminder_at := v_start - interval '180 minutes';
  elsif v_settings.reminder_t45_enabled then
    v_reminder_type := 'REMINDER_T45_CLIENT';
    v_reminder_name := 't45';
    v_reminder_at := v_start - make_interval(mins => v_settings.t45_offset_minutes);
  else
    return false;
  end if;
  if v_reminder_at >= v_start then return false; end if;

  select * into v_customer from public.customers
  where id = v_appointment.customer_id and organization_id = p_organization_id;
  if not found or v_customer.phone_e164 is null
     or not public.whatsapp_v2_consented(p_organization_id, v_customer.id) then
    return false;
  end if;
  select * into v_barber from public.barbers
  where id = v_appointment.barber_id and organization_id = p_organization_id;
  if not found then return false; end if;
  if exists (
    select 1 from public.whatsapp_automation_jobs j
    where j.organization_id = p_organization_id
      and j.appointment_id = v_appointment.id
      and j.appointment_version = v_appointment.version
      and j.job_type in ('REMINDER_T24_CLIENT', 'REMINDER_MORNING_CLIENT', 'REMINDER_T180_CLIENT', 'REMINDER_T45_CLIENT')
      and (j.status in ('SUBMITTED', 'DELIVERED', 'READ', 'SEND_UNKNOWN')
        or (j.status = 'PROCESSING' and j.send_started_at is not null))
  ) then
    return false;
  end if;

  select coalesce(nullif(string_agg(ai.service_name_snapshot, ', ' order by ai.position), ''), 'Serviço não informado')
  into v_service_names
  from public.appointment_items ai
  where ai.organization_id = p_organization_id and ai.appointment_id = v_appointment.id;

  v_payload := jsonb_build_object(
    'customer_name', v_customer.full_name,
    'barber_name', v_barber.display_name,
    'service_names', v_service_names,
    'starts_at', v_start,
    'timezone', v_org.timezone,
    'currency', v_appointment.currency,
    'total_cents', v_appointment.total_cents_snapshot,
    'templates', public.whatsapp_v2_default_message_templates() || coalesce(p_templates, v_settings.templates)
  );
  v_dedupe_key := 'v2:' || v_appointment.id || ':v' || v_appointment.version || ':' || v_reminder_name || ':client'
    || coalesce(p_dedupe_suffix, '');

  insert into public.whatsapp_automation_jobs (
    organization_id, connection_id, appointment_id, appointment_version,
    job_type, recipient_e164, payload, scheduled_for, next_attempt_at,
    valid_until, status, dedupe_key
  ) values (
    p_organization_id, p_connection_id, v_appointment.id, v_appointment.version,
    v_reminder_type, v_customer.phone_e164, v_payload,
    greatest(v_reminder_at, now()), greatest(v_reminder_at, now()),
    v_start, 'PENDING', v_dedupe_key
  ) on conflict (organization_id, dedupe_key) do nothing;
  return found;
end;
$$;

revoke all on function public.whatsapp_v2_enqueue_presence_reminder(uuid, uuid, uuid, jsonb, text)
  from public, anon, authenticated, service_role;

create or replace function public.whatsapp_runtime_prepare(p_job_id uuid, p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  j public.whatsapp_automation_jobs%rowtype;
  a public.appointments%rowtype;
  c public.customers%rowtype;
  tz text;
  reason text;
  setting public.whatsapp_custom_message_settings_v2%rowtype;
begin
  perform public.require_service_role();
  select * into j from public.whatsapp_automation_jobs where id = p_job_id for update;
  if j.id is null or j.status <> 'PROCESSING' or j.lease_token is distinct from p_token or j.lock_expires_at <= now() then
    raise exception 'STALE_LEASE';
  end if;
  if j.valid_until <= now() or (j.job_type::text like 'REMINDER_%' and j.scheduled_for + interval '5 minutes' <= now()) then
    reason := 'DELIVERY_WINDOW_EXPIRED';
  end if;
  if not exists (
    select 1 from public.whatsapp_automation_settings_v2 s
    join public.whatsapp_business_connections w on w.organization_id = s.organization_id
    where s.organization_id = j.organization_id and s.runtime_engine = 'ACTIVE' and s.mode = 'ACTIVE'
      and not s.dispatch_paused and w.id = j.connection_id and w.is_active and w.status = 'CONNECTED'
  ) then reason := 'CONNECTION_OR_AUTOMATION_PAUSED'; end if;
  if exists (
    select 1 from public.whatsapp_automation_settings_v2 s
    where s.organization_id = j.organization_id and not case j.job_type::text
      when 'BOOKING_CREATED_CLIENT' then s.booking_client_enabled
      when 'BOOKING_CREATED_STAFF' then s.booking_staff_enabled and s.staff_notifications_enabled
      when 'REMINDER_T24_CLIENT' then s.reminder_t24_enabled
      when 'REMINDER_MORNING_CLIENT' then s.reminder_morning_enabled
      when 'REMINDER_T180_CLIENT' then s.reminder_t180_enabled
      when 'REMINDER_T45_CLIENT' then s.reminder_t45_enabled
      when 'APPOINTMENT_CONFIRMED_STAFF' then s.staff_notifications_enabled
      when 'APPOINTMENT_CANCELED_STAFF' then s.staff_notifications_enabled
      else true end
  ) then reason := 'AUTOMATION_DISABLED'; end if;

  if coalesce((j.payload ->> 'transactional_plan_notice')::boolean, false) then
    select * into c from public.customers where id = j.customer_id and organization_id = j.organization_id for share;
    if c.id is null or not c.active or not public.whatsapp_v2_consented(j.organization_id, j.customer_id) then
      reason := 'TRANSACTIONAL_REVOKED';
    elsif c.phone_e164 is distinct from j.recipient_e164 then
      reason := 'RECIPIENT_CHANGED';
    end if;
  end if;

  if j.appointment_id is not null then
    select * into a from public.appointments where id = j.appointment_id and organization_id = j.organization_id;
    if j.job_type::text like 'REMINDER_%' then
      if a.id is null or a.version is distinct from j.appointment_version or a.status <> 'CONFIRMED' or lower(a.service_period) <= now() then
        reason := case when a.id is not null and a.status <> 'CONFIRMED'
          then 'APPOINTMENT_NOT_CONFIRMED' else 'APPOINTMENT_CHANGED' end;
      end if;
    elsif j.job_type::text like 'BOOKING_CREATED_%' then
      if a.id is null or a.version is distinct from j.appointment_version or a.status <> 'CONFIRMED' or lower(a.service_period) <= now() then
        reason := 'APPOINTMENT_CHANGED';
      end if;
    end if;
    if j.job_type::text like '%_CLIENT' or j.payload ->> 'message_kind' = 'MANUAL_CONFIRMATION_CLIENT' then
      if a.id is null or not public.whatsapp_v2_consented(j.organization_id, a.customer_id) then reason := 'TRANSACTIONAL_REVOKED'; end if;
      select * into c from public.customers where id = a.customer_id and organization_id = j.organization_id;
      if c.phone_e164 is distinct from j.recipient_e164 then reason := 'RECIPIENT_CHANGED'; end if;
    end if;
  end if;
  if j.dedupe_key like 'campaign:%' and exists (
    select 1 from public.whatsapp_campaigns ca where ca.id::text = split_part(j.dedupe_key, ':', 2)
      and ca.organization_id = j.organization_id and ca.status = 'CANCELED'
  ) then reason := 'CAMPAIGN_CANCELED'; end if;
  if j.custom_key is not null then
    select * into c from public.customers where id = j.customer_id and organization_id = j.organization_id for update;
    select timezone into tz from public.organizations where id = j.organization_id;
    select * into setting from public.whatsapp_custom_message_settings_v2 where organization_id = j.organization_id and message_key = j.custom_key;
    if not coalesce(setting.enabled, false) then reason := 'AUTOMATION_DISABLED'; end if;
    if not public.whatsapp_marketing_allowed(j.organization_id, j.customer_id) then reason := 'MARKETING_REVOKED'; end if;
    if c.id is null or not c.active or c.phone_e164 is distinct from j.recipient_e164 then reason := 'RECIPIENT_CHANGED'; end if;
    if exists (
      select 1 from public.whatsapp_automation_jobs x
      where x.organization_id = j.organization_id and x.customer_id = j.customer_id and x.id <> j.id
        and x.custom_key is not null and x.send_started_at is not null
        and x.status in ('PROCESSING', 'SUBMITTED', 'DELIVERED', 'READ', 'SEND_UNKNOWN')
        and (x.send_started_at at time zone tz)::date = (now() at time zone tz)::date
    ) or (
      select count(*) from public.whatsapp_automation_jobs x
      where x.organization_id = j.organization_id and x.customer_id = j.customer_id and x.id <> j.id
        and x.custom_key is not null and x.send_started_at is not null
        and x.status in ('PROCESSING', 'SUBMITTED', 'DELIVERED', 'READ', 'SEND_UNKNOWN')
        and x.send_started_at >= date_trunc('week', now() at time zone tz) at time zone tz
    ) >= 2 then reason := 'FREQUENCY_LIMIT'; end if;
    if j.custom_key like 'AFTER_SERVICE_%' and exists (
      select 1 from public.appointments x where x.organization_id = j.organization_id and x.customer_id = j.customer_id
        and ((x.status = 'CONFIRMED' and lower(x.service_period) > now()) or
          (x.status = 'COMPLETED' and coalesce((select max(se.created_at) from public.appointment_status_events se
            where se.organization_id = x.organization_id and se.appointment_id = x.id and se.to_status = 'COMPLETED'), upper(x.service_period)) > (j.payload ->> 'completed_at')::timestamptz))
    ) then reason := 'CUSTOMER_RETURNED_OR_BOOKED'; end if;
  end if;
  if reason is not null then
    update public.whatsapp_automation_jobs set status = 'SKIPPED', last_error_code = reason,
      locked_by = null, lease_token = null, lock_expires_at = null, updated_at = now() where id = j.id;
    return jsonb_build_object('ready', false, 'reason', reason);
  end if;
  if j.job_type::text like 'REMINDER_%' then perform public.create_whatsapp_v2_confirmation_request(j.id, j.locked_by); end if;
  return jsonb_build_object('ready', true);
end;
$$;

revoke all on function public.whatsapp_runtime_prepare(uuid, uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_runtime_prepare(uuid, uuid) to service_role;
