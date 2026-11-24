-- Keep manual agenda actions independent from whether each recipient has a
-- WhatsApp number. Missing contacts skip only that recipient's outbound job.

create or replace function public.enqueue_appointment_cancellation_whatsapp()
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
  v_payload jsonb;
  v_scheduled_for timestamptz := now();
  v_valid_until timestamptz := now() + interval '24 hours';
begin
  if new.status <> 'CANCELED'
     or old.status is not distinct from new.status
     or new.cancellation_source = 'WHATSAPP_CLIENT' then
    return new;
  end if;

  select * into v_connection
    from public.whatsapp_business_connections
   where organization_id = new.organization_id
     and provider = 'QR_WEB'
     and is_active
     and status = 'CONNECTED'
   order by updated_at desc
   limit 1;
  if not found then return new; end if;

  select * into v_settings
    from public.whatsapp_automation_settings_v2
   where organization_id = new.organization_id;
  if not found or v_settings.mode <> 'ACTIVE' or v_settings.dispatch_paused then
    return new;
  end if;

  select * into v_customer
    from public.customers
   where id = new.customer_id and organization_id = new.organization_id;
  select * into v_barber
    from public.barbers
   where id = new.barber_id and organization_id = new.organization_id;
  select * into v_org
    from public.organizations
   where id = new.organization_id;
  if v_org.id is null or v_customer.id is null or v_barber.id is null then
    return new;
  end if;

  v_payload := jsonb_build_object(
    'customer_name', v_customer.full_name,
    'barber_name', v_barber.display_name,
    'starts_at', lower(new.service_period),
    'timezone', v_org.timezone,
    'currency', new.currency,
    'total_cents', new.total_cents_snapshot,
    'cancellation_outcome', new.cancellation_outcome,
    'cancellation_actor_name', new.cancellation_actor_name,
    'cancelled_at', new.cancelled_at,
    'templates', v_settings.templates
  );

  if v_customer.phone_e164 is not null
     and public.whatsapp_v2_consented(new.organization_id, new.customer_id) then
    insert into public.whatsapp_automation_jobs (
      organization_id, connection_id, appointment_id, appointment_version,
      customer_id, priority, job_type, recipient_e164, payload,
      scheduled_for, next_attempt_at, valid_until, status, dedupe_key
    ) values (
      new.organization_id, v_connection.id, new.id, new.version,
      new.customer_id, 0, 'CANCELLATION_ACK_CLIENT', v_customer.phone_e164,
      v_payload, v_scheduled_for, v_scheduled_for, v_valid_until, 'PENDING',
      'v2:' || new.id || ':v' || new.version || ':cancellation:client'
    ) on conflict (organization_id, dedupe_key) do nothing;
  end if;

  if v_settings.staff_notifications_enabled and v_barber.whatsapp_e164 is not null then
    insert into public.whatsapp_automation_jobs (
      organization_id, connection_id, appointment_id, appointment_version,
      customer_id, priority, job_type, recipient_e164, payload,
      scheduled_for, next_attempt_at, valid_until, status, dedupe_key
    ) values (
      new.organization_id, v_connection.id, new.id, new.version,
      new.customer_id, 0, 'APPOINTMENT_CANCELED_STAFF', v_barber.whatsapp_e164,
      v_payload, v_scheduled_for, v_scheduled_for, v_valid_until, 'PENDING',
      'v2:' || new.id || ':v' || new.version || ':cancellation:staff'
    ) on conflict (organization_id, dedupe_key) do nothing;
  elsif v_settings.staff_notifications_enabled then
    begin
      perform public.enqueue_appointment_auxiliary_staff_message(
        new.organization_id, new.id, 'CANCEL', null, false
      );
    exception when others then
      raise warning 'Auxiliary cancellation notice could not be queued (SQLSTATE %)', sqlstate;
    end;
  end if;

  return new;
end;
$$;

create or replace function public.confirm_appointment_manually_by_whatsapp(p_appointment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_appointment public.appointments%rowtype;
  v_connection public.whatsapp_business_connections%rowtype;
  v_settings public.whatsapp_automation_settings_v2%rowtype;
  v_customer public.customers%rowtype;
  v_barber public.barbers%rowtype;
  v_auxiliary record;
  v_timezone text;
  v_templates jsonb;
begin
  select * into v_appointment from public.appointments where id = p_appointment_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'appointment not found'; end if;
  if not public.is_organization_owner(v_appointment.organization_id) then
    raise exception using errcode = '42501', message = 'organization owner required';
  end if;
  if not public.organization_allows_existing_operations(v_appointment.organization_id) then
    raise exception using errcode = '42501', message = 'organization access does not allow appointment operations';
  end if;
  if v_appointment.status <> 'CONFIRMED' then
    raise exception using errcode = '22023', message = 'appointment must be operationally confirmed';
  end if;
  if v_appointment.whatsapp_response_status in ('CONFIRMED_BY_WHATSAPP', 'CONFIRMED_MANUALLY') then
    raise exception using errcode = '22023', message = 'appointment is already confirmed';
  end if;

  select * into v_customer from public.customers
  where id = v_appointment.customer_id and organization_id = v_appointment.organization_id;
  if not found then raise exception using errcode = 'P0002', message = 'appointment customer not found'; end if;
  select * into v_barber from public.barbers
  where id = v_appointment.barber_id and organization_id = v_appointment.organization_id;
  if not found then raise exception using errcode = 'P0002', message = 'appointment barber not found'; end if;
  if v_customer.phone_e164 is not null
     and not public.whatsapp_v2_consented(v_appointment.organization_id, v_customer.id) then
    raise exception using errcode = '42501', message = 'customer WhatsApp transactional consent is required';
  end if;

  select * into v_connection from public.whatsapp_business_connections
  where organization_id = v_appointment.organization_id and provider = 'QR_WEB' and is_active and status = 'CONNECTED'
  order by updated_at desc limit 1 for update;
  if not found then raise exception using errcode = 'P0002', message = 'active WhatsApp QR connection not found'; end if;
  select * into v_settings from public.whatsapp_automation_settings_v2
  where organization_id = v_appointment.organization_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'WhatsApp automation settings not found'; end if;
  if v_settings.mode <> 'ACTIVE' then raise exception using errcode = '22023', message = 'WhatsApp automation is not active'; end if;
  if v_settings.dispatch_paused then raise exception using errcode = '22023', message = 'WhatsApp dispatch is paused'; end if;
  select timezone into strict v_timezone from public.organizations where id = v_appointment.organization_id;
  v_templates := public.whatsapp_v2_default_message_templates() || v_settings.templates;

  update public.whatsapp_confirmation_requests_v2
  set status = 'EXPIRED', updated_at = now()
  where appointment_id = v_appointment.id and organization_id = v_appointment.organization_id and status = 'PENDING';
  update public.whatsapp_automation_jobs
  set status = 'CANCELED', last_error_code = 'MANUAL_CONFIRMATION_SUPERSEDED_REMINDER', updated_at = now()
  where appointment_id = v_appointment.id and organization_id = v_appointment.organization_id
    and status in ('PENDING', 'RETRY')
    and job_type in ('REMINDER_T24_CLIENT', 'REMINDER_MORNING_CLIENT', 'REMINDER_T180_CLIENT', 'REMINDER_T45_CLIENT');
  update public.appointments set whatsapp_response_status = 'CONFIRMED_MANUALLY', updated_at = now()
  where id = v_appointment.id and organization_id = v_appointment.organization_id;
  insert into public.appointment_status_events
    (organization_id, appointment_id, from_status, to_status, reason, actor_user_id, metadata)
  values (v_appointment.organization_id, v_appointment.id, v_appointment.status, v_appointment.status,
    'manual_whatsapp_confirmation_requested', auth.uid(), jsonb_build_object('whatsapp_response_status', 'CONFIRMED_MANUALLY'));

  if v_customer.phone_e164 is not null then
    insert into public.whatsapp_automation_jobs
      (organization_id, connection_id, appointment_id, appointment_version, job_type, recipient_e164, payload, valid_until, dedupe_key)
    values (v_appointment.organization_id, v_connection.id, v_appointment.id, v_appointment.version,
      'MANUAL_OUTBOUND_TEXT', v_customer.phone_e164,
      jsonb_build_object('message_kind', 'MANUAL_CONFIRMATION_CLIENT', 'customer_name', v_customer.full_name,
        'barber_name', v_barber.display_name, 'starts_at', lower(v_appointment.service_period),
        'timezone', v_timezone, 'templates', v_templates),
      lower(v_appointment.service_period), 'v2:' || v_appointment.id || ':v' || v_appointment.version || ':manual-confirm:client')
    on conflict (organization_id, dedupe_key) do nothing;
  end if;

  if v_barber.whatsapp_e164 is not null then
    insert into public.whatsapp_automation_jobs
      (organization_id, connection_id, appointment_id, appointment_version, job_type, recipient_e164, payload, valid_until, dedupe_key)
    values (v_appointment.organization_id, v_connection.id, v_appointment.id, v_appointment.version,
      'MANUAL_OUTBOUND_TEXT', v_barber.whatsapp_e164,
      jsonb_build_object('message_kind', 'MANUAL_CONFIRMATION_STAFF', 'customer_name', v_customer.full_name,
        'barber_name', v_barber.display_name, 'starts_at', lower(v_appointment.service_period),
        'timezone', v_timezone, 'templates', v_templates),
      lower(v_appointment.service_period), 'v2:' || v_appointment.id || ':v' || v_appointment.version || ':manual-confirm:staff')
    on conflict (organization_id, dedupe_key) do nothing;
  else
    for v_auxiliary in
      select assignment.id, assistant.whatsapp_e164, assistant.display_name
      from public.appointment_auxiliaries assignment
      join public.barbers assistant
        on assistant.id = assignment.assistant_barber_id
       and assistant.organization_id = assignment.organization_id
      where assignment.organization_id = v_appointment.organization_id
        and assignment.appointment_id = v_appointment.id
        and assistant.whatsapp_e164 is not null
        and assistant.whatsapp_e164 ~ '^\+[1-9][0-9]{7,14}$'
    loop
      insert into public.whatsapp_automation_jobs
        (organization_id, connection_id, appointment_id, appointment_version, job_type, recipient_e164, payload, valid_until, dedupe_key)
      values (v_appointment.organization_id, v_connection.id, v_appointment.id, v_appointment.version,
        'MANUAL_OUTBOUND_TEXT', v_auxiliary.whatsapp_e164,
        jsonb_build_object('message_kind', 'MANUAL_CONFIRMATION_STAFF', 'message_audience', 'AUXILIARY',
          'customer_name', v_customer.full_name, 'barber_name', v_auxiliary.display_name,
          'primary_barber_name', v_barber.display_name, 'starts_at', lower(v_appointment.service_period),
          'timezone', v_timezone, 'templates', v_templates),
        lower(v_appointment.service_period), 'v2:' || v_appointment.id || ':v' || v_appointment.version
          || ':manual-confirm:staff:assistant:' || v_auxiliary.id)
      on conflict (organization_id, dedupe_key) do nothing;
    end loop;
  end if;

  return jsonb_build_object('appointment_id', v_appointment.id, 'whatsapp_response_status', 'CONFIRMED_MANUALLY');
end;
$$;

create or replace function public.enqueue_appointment_reschedule_whatsapp()
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
  v_client_consented boolean;
  v_service_names text;
  v_start timestamptz;
  v_payload jsonb;
begin
  if new.status <> 'CONFIRMED'
     or old.status <> 'CONFIRMED'
     or (new.service_period is not distinct from old.service_period
         and new.barber_id is not distinct from old.barber_id) then
    return new;
  end if;

  select * into v_connection
  from public.whatsapp_business_connections
  where organization_id = new.organization_id and provider = 'QR_WEB' and is_active and status = 'CONNECTED'
  order by updated_at desc limit 1;
  if not found then return new; end if;
  select * into v_settings from public.whatsapp_automation_settings_v2
  where organization_id = new.organization_id;
  if not found or v_settings.mode <> 'ACTIVE' or v_settings.dispatch_paused then return new; end if;

  select * into v_customer from public.customers
  where id = new.customer_id and organization_id = new.organization_id;
  select * into v_barber from public.barbers
  where id = new.barber_id and organization_id = new.organization_id;
  select * into v_org from public.organizations where id = new.organization_id;
  if v_customer.id is null or v_barber.id is null or v_org.id is null then return new; end if;

  select coalesce(nullif(string_agg(item.service_name_snapshot, ', ' order by item.position), ''), 'Serviço não informado')
  into v_service_names from public.appointment_items item
  where item.organization_id = new.organization_id and item.appointment_id = new.id;
  v_client_consented := public.whatsapp_v2_consented(new.organization_id, new.customer_id);
  v_start := lower(new.service_period);
  v_payload := jsonb_build_object(
    'customer_name', v_customer.full_name,
    'barber_name', v_barber.display_name,
    'primary_barber_name', v_barber.display_name,
    'service_names', v_service_names,
    'starts_at', v_start,
    'timezone', v_org.timezone,
    'currency', new.currency,
    'total_cents', new.total_cents_snapshot,
    'templates', public.whatsapp_v2_default_message_templates() || coalesce(v_settings.templates, '{}'::jsonb)
  );

  if v_settings.booking_client_enabled
     and v_customer.phone_e164 is not null
     and v_client_consented then
    insert into public.whatsapp_automation_jobs (
      organization_id, connection_id, appointment_id, appointment_version,
      job_type, recipient_e164, payload, valid_until, dedupe_key
    ) values (
      new.organization_id, v_connection.id, new.id, new.version,
      'BOOKING_CREATED_CLIENT', v_customer.phone_e164, v_payload, v_start,
      'v2:' || new.id || ':v' || new.version || ':rescheduled:client'
    ) on conflict (organization_id, dedupe_key) do nothing;
  end if;

  if v_settings.booking_staff_enabled
     and v_settings.staff_notifications_enabled
     and v_barber.whatsapp_e164 is not null then
    insert into public.whatsapp_automation_jobs (
      organization_id, connection_id, appointment_id, appointment_version,
      job_type, recipient_e164, payload, valid_until, dedupe_key
    ) values (
      new.organization_id, v_connection.id, new.id, new.version,
      'BOOKING_CREATED_STAFF', v_barber.whatsapp_e164, v_payload, v_start,
      'v2:' || new.id || ':v' || new.version || ':rescheduled:staff'
    ) on conflict (organization_id, dedupe_key) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists zzz_appointments_enqueue_reschedule_whatsapp on public.appointments;
create trigger zzz_appointments_enqueue_reschedule_whatsapp
after update of service_period, barber_id on public.appointments
for each row execute function public.enqueue_appointment_reschedule_whatsapp();

revoke all on function public.enqueue_appointment_cancellation_whatsapp() from public, anon, authenticated;
revoke all on function public.confirm_appointment_manually_by_whatsapp(uuid) from public, anon;
grant execute on function public.confirm_appointment_manually_by_whatsapp(uuid) to authenticated;
revoke all on function public.enqueue_appointment_reschedule_whatsapp() from public, anon, authenticated;
