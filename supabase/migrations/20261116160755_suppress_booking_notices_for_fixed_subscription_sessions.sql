-- Fixed subscription sessions are created as confirmed appointments, but are
-- not newly booked by the client or manager. Keep presence reminders and replies;
-- suppress only the booking announcements to client, primary staff, and assistants.

create or replace function public.appointment_uses_fixed_subscription_schedule(
  p_organization_id uuid,
  p_appointment_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.appointments appointment
    join public.customer_subscription_sessions session
      on session.id = appointment.subscription_session_id
     and session.organization_id = appointment.organization_id
    join public.customer_subscriptions subscription
      on subscription.id = session.subscription_id
     and subscription.organization_id = session.organization_id
    join public.subscription_plan_versions plan_version
      on plan_version.id = subscription.plan_version_id
     and plan_version.organization_id = subscription.organization_id
    where appointment.id = p_appointment_id
      and appointment.organization_id = p_organization_id
      and plan_version.scheduling_mode = 'FIXED'
  );
$$;

revoke all on function public.appointment_uses_fixed_subscription_schedule(uuid, uuid)
  from public, anon, authenticated, service_role;

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
  v_confirmed_transition boolean := new.status = 'CONFIRMED' and (tg_op = 'INSERT' or old.status is distinct from 'CONFIRMED');
  v_changed boolean := tg_op = 'UPDATE' and (old.service_period is distinct from new.service_period or old.barber_id is distinct from new.barber_id or old.customer_id is distinct from new.customer_id or old.version is distinct from new.version);
  v_client_consented boolean;
  v_service_names text;
  v_payload jsonb;
  v_fixed_subscription boolean := false;
begin
  if new.status in ('CANCELED', 'COMPLETED', 'EXPIRED', 'IN_SERVICE', 'NO_SHOW') then
    update public.whatsapp_automation_jobs set status = 'CANCELED', updated_at = now(), last_error_code = case when new.status = 'CANCELED' then 'APPOINTMENT_CANCELED' else 'APPOINTMENT_COMPLETED' end
    where appointment_id = new.id and organization_id = new.organization_id and job_type in ('REMINDER_T24_CLIENT', 'REMINDER_MORNING_CLIENT', 'REMINDER_T180_CLIENT', 'REMINDER_T45_CLIENT')
      and (status in ('PENDING', 'RETRY') or (status = 'PROCESSING' and send_started_at is null));
    if new.status = 'CANCELED' then
      update public.whatsapp_confirmation_requests_v2 set status = 'EXPIRED', updated_at = now()
      where appointment_id = new.id and status = 'PENDING';
    end if;
    return new;
  end if;

  if not (tg_op = 'INSERT' or v_confirmed_transition or v_changed) then return new; end if;
  select * into v_connection from public.whatsapp_business_connections
  where organization_id = new.organization_id and provider = 'QR_WEB' and is_active order by updated_at desc limit 1;
  if not found then return new; end if;
  select * into v_settings from public.whatsapp_automation_settings_v2 where organization_id = new.organization_id;
  if not found or v_settings.mode <> 'ACTIVE' or v_settings.dispatch_paused then return new; end if;

  if v_changed then
    update public.whatsapp_automation_jobs set status = 'CANCELED', updated_at = now(), last_error_code = 'APPOINTMENT_VERSION_SUPERSEDED'
    where appointment_id = new.id and organization_id = new.organization_id and appointment_version <> new.version
      and (status in ('PENDING', 'RETRY') or (status = 'PROCESSING' and send_started_at is null));
    update public.whatsapp_confirmation_requests_v2 set status = 'SUPERSEDED', updated_at = now()
    where appointment_id = new.id and organization_id = new.organization_id and appointment_version <> new.version and status = 'PENDING';
  end if;

  -- Deferred appointment triggers may carry the pre-link INSERT row. Read the
  -- current row through this helper so fixed-session metadata is authoritative.
  v_fixed_subscription := public.appointment_uses_fixed_subscription_schedule(new.organization_id, new.id);

  select * into strict v_customer from public.customers where id = new.customer_id and organization_id = new.organization_id;
  select * into strict v_barber from public.barbers where id = new.barber_id and organization_id = new.organization_id;
  select * into strict v_org from public.organizations where id = new.organization_id;
  select coalesce(nullif(string_agg(ai.service_name_snapshot, ', ' order by ai.position), ''), 'Serviço não informado')
  into v_service_names from public.appointment_items ai
  where ai.organization_id = new.organization_id and ai.appointment_id = new.id;
  v_client_consented := public.whatsapp_v2_consented(new.organization_id, new.customer_id);
  v_start := lower(new.service_period);
  v_payload := jsonb_build_object(
    'customer_name', v_customer.full_name, 'barber_name', v_barber.display_name,
    'service_names', v_service_names, 'starts_at', v_start, 'timezone', v_org.timezone,
    'currency', new.currency, 'total_cents', new.total_cents_snapshot,
    'templates', public.whatsapp_v2_default_message_templates() || v_settings.templates
  );

  if not v_fixed_subscription and v_confirmed_transition and v_settings.booking_client_enabled and v_customer.phone_e164 is not null and v_client_consented then
    insert into public.whatsapp_automation_jobs (organization_id, connection_id, appointment_id, appointment_version, job_type, recipient_e164, payload, valid_until, dedupe_key)
    values (new.organization_id, v_connection.id, new.id, new.version, 'BOOKING_CREATED_CLIENT', v_customer.phone_e164, v_payload, v_start, 'v2:' || new.id || ':v' || new.version || ':booking:client') on conflict (organization_id, dedupe_key) do nothing;
  end if;
  if not v_fixed_subscription and v_confirmed_transition and v_settings.booking_staff_enabled and v_settings.staff_notifications_enabled and v_barber.whatsapp_e164 is not null then
    insert into public.whatsapp_automation_jobs (organization_id, connection_id, appointment_id, appointment_version, job_type, recipient_e164, payload, valid_until, dedupe_key)
    values (new.organization_id, v_connection.id, new.id, new.version, 'BOOKING_CREATED_STAFF', v_barber.whatsapp_e164, v_payload, v_start, 'v2:' || new.id || ':v' || new.version || ':booking:staff') on conflict (organization_id, dedupe_key) do nothing;
  end if;

  if v_start > now() then
    perform public.whatsapp_v2_enqueue_presence_reminder(new.organization_id, new.id, v_connection.id, v_settings.templates);
  end if;
  return new;
end;
$$;

revoke all on function public.schedule_whatsapp_v2_for_appointment() from public, anon, authenticated;

create or replace function public.enqueue_appointment_auxiliary_staff_message(
  p_organization_id uuid,
  p_appointment_id uuid,
  p_kind text,
  p_auxiliary_id uuid default null,
  p_is_new_assignment boolean default false
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_appointment public.appointments%rowtype;
  v_connection public.whatsapp_business_connections%rowtype;
  v_settings public.whatsapp_automation_settings_v2%rowtype;
  v_customer public.customers%rowtype;
  v_primary public.barbers%rowtype;
  v_org public.organizations%rowtype;
  v_auxiliary record;
  v_payload jsonb;
  v_service_names text;
  v_when timestamptz;
  v_key text;
begin
  if p_kind not in ('BOOKING', 'CANCEL') then
    raise exception using errcode = '22023', message = 'unsupported auxiliary notification kind';
  end if;
  select * into v_appointment from public.appointments
  where id = p_appointment_id and organization_id = p_organization_id;
  if not found then return; end if;
  if p_kind = 'BOOKING'
     and public.appointment_uses_fixed_subscription_schedule(p_organization_id, p_appointment_id) then
    return;
  end if;
  select * into v_connection from public.whatsapp_business_connections
  where organization_id = p_organization_id and provider = 'QR_WEB' and is_active and status = 'CONNECTED'
  order by updated_at desc limit 1;
  if not found then return; end if;
  select * into v_settings from public.whatsapp_automation_settings_v2 where organization_id = p_organization_id;
  if not found or v_settings.mode <> 'ACTIVE' or v_settings.dispatch_paused
     or not v_settings.staff_notifications_enabled
     or (p_kind = 'BOOKING' and not v_settings.booking_staff_enabled) then return; end if;
  select * into v_customer from public.customers where id = v_appointment.customer_id and organization_id = p_organization_id;
  select * into v_primary from public.barbers where id = v_appointment.barber_id and organization_id = p_organization_id;
  select * into v_org from public.organizations where id = p_organization_id;
  if v_customer.id is null or v_primary.id is null or v_org.id is null then return; end if;
  select coalesce(nullif(string_agg(item.service_name_snapshot, ', ' order by item.position), ''), 'Serviço não informado')
  into v_service_names from public.appointment_items item
  where item.organization_id = p_organization_id and item.appointment_id = p_appointment_id;
  v_when := lower(v_appointment.service_period);
  v_payload := jsonb_build_object(
    'customer_name', v_customer.full_name, 'barber_name', v_primary.display_name,
    'primary_barber_name', v_primary.display_name,
    'service_names', v_service_names, 'starts_at', v_when, 'timezone', v_org.timezone,
    'currency', v_appointment.currency, 'total_cents', v_appointment.total_cents_snapshot,
    'templates', public.whatsapp_v2_default_message_templates() || v_settings.templates
  );
  for v_auxiliary in
    select assignment.id, assignment.assistant_barber_id, barber.whatsapp_e164, barber.display_name
    from public.appointment_auxiliaries assignment
    join public.barbers barber on barber.id = assignment.assistant_barber_id
      and barber.organization_id = assignment.organization_id
    where assignment.organization_id = p_organization_id and assignment.appointment_id = p_appointment_id
      and (p_auxiliary_id is null or assignment.id = p_auxiliary_id)
      and barber.whatsapp_e164 is not null
  loop
    if p_kind = 'BOOKING' then
      v_key := 'v2:' || p_appointment_id || ':assistant:' || v_auxiliary.id || ':'
        || case when p_is_new_assignment then 'assigned' else 'v' || v_appointment.version end;
      insert into public.whatsapp_automation_jobs (
        organization_id, connection_id, appointment_id, appointment_version, job_type,
        recipient_e164, payload, valid_until, dedupe_key
      ) values (
        p_organization_id, v_connection.id, p_appointment_id, v_appointment.version,
        'BOOKING_CREATED_STAFF', v_auxiliary.whatsapp_e164,
        v_payload || jsonb_build_object('message_audience', 'AUXILIARY', 'barber_name', v_auxiliary.display_name),
        v_when, v_key
      ) on conflict (organization_id, dedupe_key) do nothing;
    else
      v_key := 'v2:' || p_appointment_id || ':v' || v_appointment.version || ':cancellation:assistant:' || v_auxiliary.id;
      insert into public.whatsapp_automation_jobs (
        organization_id, connection_id, appointment_id, appointment_version,
        customer_id, priority, job_type, recipient_e164, payload, scheduled_for,
        next_attempt_at, valid_until, status, dedupe_key
      ) values (
        p_organization_id, v_connection.id, p_appointment_id, v_appointment.version,
        v_appointment.customer_id, 0, 'APPOINTMENT_CANCELED_STAFF', v_auxiliary.whatsapp_e164,
        v_payload || jsonb_build_object('message_audience', 'AUXILIARY', 'barber_name', v_auxiliary.display_name),
        now(), now(), now() + interval '24 hours', 'PENDING', v_key
      ) on conflict (organization_id, dedupe_key) do nothing;
    end if;
  end loop;
end;
$$;

revoke all on function public.enqueue_appointment_auxiliary_staff_message(uuid, uuid, text, uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.enqueue_appointment_auxiliary_staff_message(uuid, uuid, text, uuid, boolean)
  to service_role;

-- Prevent already queued, not-yet-sent booking notices from escaping after this
-- rule is deployed. Jobs already handed to the provider are left untouched.
update public.whatsapp_automation_jobs job
set status = 'CANCELED',
    updated_at = now(),
    last_error_code = 'FIXED_SUBSCRIPTION_BOOKING_NOTICE_SUPPRESSED'
where job.job_type in ('BOOKING_CREATED_CLIENT', 'BOOKING_CREATED_STAFF')
  and (job.status in ('PENDING', 'RETRY') or (job.status = 'PROCESSING' and job.send_started_at is null))
  and public.appointment_uses_fixed_subscription_schedule(job.organization_id, job.appointment_id);
