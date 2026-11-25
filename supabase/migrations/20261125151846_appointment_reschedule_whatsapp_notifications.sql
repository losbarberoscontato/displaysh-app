-- Dedicated, editable WhatsApp notices for appointment rescheduling.
-- Existing booking confirmations, presence reminders, and cancellation flows
-- retain their current rules and queue types.

alter table public.subscription_bundle_sessions
  add column if not exists reschedule_observation text;

-- Keep the existing session-management validation and transaction intact. The
-- wrapper persists the optional reschedule reason in the same transaction.
alter function public.manage_subscription_bundle_session(uuid,uuid,text,uuid,timestamptz,text,jsonb,boolean)
  rename to manage_subscription_bundle_session_before_reschedule_observation;
revoke all on function public.manage_subscription_bundle_session_before_reschedule_observation(uuid,uuid,text,uuid,timestamptz,text,jsonb,boolean)
  from public, anon, authenticated, service_role;

create function public.manage_subscription_bundle_session(
  p_organization_id uuid,
  p_session_id uuid,
  p_action text,
  p_barber_id uuid default null,
  p_starts_at timestamptz default null,
  p_observation text default null,
  p_auxiliaries jsonb default null,
  p_confirm_late_cancel boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_result jsonb;
begin
  if p_action = 'RESCHEDULE' and length(coalesce(p_observation, '')) > 500 then
    raise exception using errcode = '22023', message = 'reschedule observation is too long';
  end if;

  v_result := public.manage_subscription_bundle_session_before_reschedule_observation(
    p_organization_id, p_session_id, p_action, p_barber_id, p_starts_at,
    p_observation, p_auxiliaries, p_confirm_late_cancel
  );

  if p_action = 'RESCHEDULE' then
    update public.subscription_bundle_sessions
       set reschedule_observation = nullif(btrim(coalesce(p_observation, '')), '')
     where id = p_session_id and organization_id = p_organization_id
       and deleted_at is null;
  end if;
  return v_result;
end;
$$;
revoke all on function public.manage_subscription_bundle_session(uuid,uuid,text,uuid,timestamptz,text,jsonb,boolean)
  from public, anon, service_role;
grant execute on function public.manage_subscription_bundle_session(uuid,uuid,text,uuid,timestamptz,text,jsonb,boolean)
  to authenticated;

-- Add the three independently editable reschedule templates without replacing
-- any text already customized by a manager.
alter function public.whatsapp_v2_default_message_templates()
  rename to whatsapp_v2_default_message_templates_before_reschedule_notices;
create function public.whatsapp_v2_default_message_templates()
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $$
  select public.whatsapp_v2_default_message_templates_before_reschedule_notices() || jsonb_build_object(
    'APPOINTMENT_RESCHEDULED_CLIENT', 'Prezado(a) {cliente}, sua sessão do dia {horario_original}, foi reagendada para o dia {horario_novo} com o profissional {profissional}.',
    'APPOINTMENT_RESCHEDULED_STAFF', 'Sessão reagendada. Cliente: {cliente}, De: {horario_original}, para: {horario_novo}',
    'APPOINTMENT_RESCHEDULED_AUXILIARY', 'Sessão reagendada. Cliente: {cliente}, De: {horario_original}, para: {horario_novo}'
  );
$$;
revoke all on function public.whatsapp_v2_default_message_templates_before_reschedule_notices() from public, anon, authenticated;
grant execute on function public.whatsapp_v2_default_message_templates_before_reschedule_notices() to service_role;
revoke all on function public.whatsapp_v2_default_message_templates() from public, anon, authenticated;
grant execute on function public.whatsapp_v2_default_message_templates() to service_role;

alter function public.whatsapp_v2_legacy_default_message_templates()
  rename to whatsapp_v2_legacy_default_message_templates_before_reschedule_notices;
create function public.whatsapp_v2_legacy_default_message_templates()
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $$
  select public.whatsapp_v2_legacy_default_message_templates_before_reschedule_notices() || jsonb_build_object(
    'APPOINTMENT_RESCHEDULED_CLIENT', 'Prezado(a) {cliente}, sua sessão do dia {horario_original}, foi reagendada para o dia {horario_novo} com o profissional {profissional}.',
    'APPOINTMENT_RESCHEDULED_STAFF', 'Sessão reagendada. Cliente: {cliente}, De: {horario_original}, para: {horario_novo}',
    'APPOINTMENT_RESCHEDULED_AUXILIARY', 'Sessão reagendada. Cliente: {cliente}, De: {horario_original}, para: {horario_novo}'
  );
$$;
revoke all on function public.whatsapp_v2_legacy_default_message_templates_before_reschedule_notices() from public, anon, authenticated;
grant execute on function public.whatsapp_v2_legacy_default_message_templates_before_reschedule_notices() to service_role;
revoke all on function public.whatsapp_v2_legacy_default_message_templates() from public, anon, authenticated;
grant execute on function public.whatsapp_v2_legacy_default_message_templates() to service_role;

-- Preserve the established product-specific defaults and append the reschedule
-- copy to the settings payload returned for every Display product.
alter function public.whatsapp_v2_default_message_templates_for_product(text)
  rename to whatsapp_v2_default_message_templates_for_product_before_reschedule_notices;
create function public.whatsapp_v2_default_message_templates_for_product(p_product_key text)
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $$
  select public.whatsapp_v2_default_message_templates_for_product_before_reschedule_notices(p_product_key)
    || jsonb_build_object(
      'APPOINTMENT_RESCHEDULED_CLIENT', 'Prezado(a) {cliente}, sua sessão do dia {horario_original}, foi reagendada para o dia {horario_novo} com o profissional {profissional}.',
      'APPOINTMENT_RESCHEDULED_STAFF', 'Sessão reagendada. Cliente: {cliente}, De: {horario_original}, para: {horario_novo}',
      'APPOINTMENT_RESCHEDULED_AUXILIARY', 'Sessão reagendada. Cliente: {cliente}, De: {horario_original}, para: {horario_novo}'
    );
$$;
revoke all on function public.whatsapp_v2_default_message_templates_for_product_before_reschedule_notices(text) from public, anon, authenticated;
grant execute on function public.whatsapp_v2_default_message_templates_for_product_before_reschedule_notices(text) to service_role;
revoke all on function public.whatsapp_v2_default_message_templates_for_product(text) from public, anon, authenticated;
grant execute on function public.whatsapp_v2_default_message_templates_for_product(text) to service_role;

update public.whatsapp_automation_settings_v2
   set templates = public.whatsapp_v2_default_message_templates() || coalesce(templates, '{}'::jsonb)
 where not (coalesce(templates, '{}'::jsonb) ? 'APPOINTMENT_RESCHEDULED_CLIENT')
    or not (coalesce(templates, '{}'::jsonb) ? 'APPOINTMENT_RESCHEDULED_STAFF')
    or not (coalesce(templates, '{}'::jsonb) ? 'APPOINTMENT_RESCHEDULED_AUXILIARY');

-- Only the dedicated reschedule messages are exempt from the subscription
-- WhatsApp pause. Presence and automatic booking messages stay paused.
create or replace function public.pause_subscription_whatsapp_job_insert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status in ('PENDING', 'RETRY') and (
    new.payload ->> 'message_kind' = 'SUBSCRIPTION_CREATED_CLIENT'
    or new.payload ->> 'payment_mode' = 'SUBSCRIPTION'
    or (
      new.appointment_id is not null
      and new.job_type::text not in (
        'REMINDER_T24_CLIENT',
        'REMINDER_MORNING_CLIENT',
        'REMINDER_T180_CLIENT',
        'REMINDER_T45_CLIENT'
      )
      and new.job_type::text not in (
        'CANCELLATION_ACK_CLIENT',
        'APPOINTMENT_CANCELED_STAFF'
      )
      and not (
        new.job_type::text = 'MANUAL_OUTBOUND_TEXT'
        and new.payload ->> 'message_kind' in (
          'MANUAL_CONFIRMATION_CLIENT',
          'MANUAL_CONFIRMATION_STAFF',
          'APPOINTMENT_RESCHEDULED_CLIENT',
          'APPOINTMENT_RESCHEDULED_STAFF',
          'APPOINTMENT_RESCHEDULED_AUXILIARY'
        )
      )
      and (
        exists (
          select 1 from public.appointments appointment
          where appointment.id = new.appointment_id
            and appointment.organization_id = new.organization_id
            and (appointment.subscription_session_id is not null
              or appointment.subscription_bundle_session_id is not null)
        )
        or exists (
          select 1 from public.customer_subscription_sessions session
          where session.appointment_id = new.appointment_id
            and session.organization_id = new.organization_id
        )
        or exists (
          select 1 from public.subscription_bundle_sessions session
          where session.appointment_id = new.appointment_id
            and session.organization_id = new.organization_id
        )
      )
    )
  ) then
    new.status := 'SKIPPED';
    new.last_error_code := 'SUBSCRIPTION_WHATSAPP_PAUSED';
    new.locked_at := null;
    new.locked_by := null;
    new.lock_expires_at := null;
    new.lease_token := null;
    new.updated_at := now();
  end if;
  return new;
end;
$$;
revoke all on function public.pause_subscription_whatsapp_job_insert() from public, anon, authenticated;

create or replace function public.whatsapp_v2_subscription_job_allowed(
  p_job_id uuid,
  p_worker_id text,
  p_lease_token uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_job public.whatsapp_automation_jobs%rowtype;
  v_subscription_job boolean;
begin
  perform public.require_service_role();
  select * into v_job from public.whatsapp_automation_jobs where id = p_job_id for update;
  if not found or v_job.status <> 'PROCESSING'
     or v_job.locked_by is distinct from p_worker_id
     or (p_lease_token is not null and v_job.lease_token is distinct from p_lease_token) then
    return false;
  end if;

  v_subscription_job := v_job.payload ->> 'message_kind' = 'SUBSCRIPTION_CREATED_CLIENT'
    or v_job.payload ->> 'payment_mode' = 'SUBSCRIPTION'
    or (
      v_job.appointment_id is not null
      and v_job.job_type::text not in (
        'REMINDER_T24_CLIENT', 'REMINDER_MORNING_CLIENT', 'REMINDER_T180_CLIENT', 'REMINDER_T45_CLIENT',
        'CANCELLATION_ACK_CLIENT', 'APPOINTMENT_CANCELED_STAFF'
      )
      and not (
        v_job.job_type::text = 'MANUAL_OUTBOUND_TEXT'
        and v_job.payload ->> 'message_kind' in (
          'MANUAL_CONFIRMATION_CLIENT',
          'MANUAL_CONFIRMATION_STAFF',
          'APPOINTMENT_RESCHEDULED_CLIENT',
          'APPOINTMENT_RESCHEDULED_STAFF',
          'APPOINTMENT_RESCHEDULED_AUXILIARY'
        )
      )
      and (
        exists (
          select 1 from public.appointments appointment
          where appointment.id = v_job.appointment_id
            and appointment.organization_id = v_job.organization_id
            and (appointment.subscription_session_id is not null
              or appointment.subscription_bundle_session_id is not null)
        )
        or exists (
          select 1 from public.customer_subscription_sessions session
          where session.appointment_id = v_job.appointment_id
            and session.organization_id = v_job.organization_id
        )
        or exists (
          select 1 from public.subscription_bundle_sessions session
          where session.appointment_id = v_job.appointment_id
            and session.organization_id = v_job.organization_id
        )
      )
    );

  if v_subscription_job then
    if v_job.send_started_at is null then
      update public.whatsapp_automation_jobs
         set status = 'SKIPPED', last_error_code = 'SUBSCRIPTION_WHATSAPP_PAUSED',
             locked_at = null, locked_by = null, lock_expires_at = null,
             lease_token = null, updated_at = now()
       where id = v_job.id;
    end if;
    return false;
  end if;
  return true;
end;
$$;
revoke all on function public.whatsapp_v2_subscription_job_allowed(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_v2_subscription_job_allowed(uuid, text, uuid) to service_role;

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
  v_auxiliary record;
  v_client_consented boolean;
  v_original_start timestamptz;
  v_start timestamptz;
  v_templates jsonb;
  v_payload jsonb;
begin
  if tg_op = 'UPDATE' then
    if new.status <> 'CONFIRMED'
       or old.status <> 'CONFIRMED'
       or (new.service_period is not distinct from old.service_period
           and new.barber_id is not distinct from old.barber_id) then
      return new;
    end if;
    v_original_start := lower(old.service_period);
  else
    if new.status <> 'CONFIRMED' or new.subscription_bundle_session_id is null then
      return new;
    end if;
    select coalesce(session.scheduled_for, session.canceled_from, session.rescheduled_from)
      into v_original_start
      from public.subscription_bundle_sessions session
     where session.id = new.subscription_bundle_session_id
       and session.organization_id = new.organization_id
       and session.deleted_at is null;
    -- Initial bookings have no previous schedule and must keep the regular
    -- booking-confirmation flow rather than receive a reschedule notice.
    if v_original_start is null then return new; end if;
  end if;

  v_start := lower(new.service_period);
  select * into v_connection
    from public.whatsapp_business_connections
   where organization_id = new.organization_id and provider = 'QR_WEB'
     and is_active and status = 'CONNECTED'
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

  v_client_consented := public.whatsapp_v2_consented(new.organization_id, new.customer_id);
  v_templates := public.whatsapp_v2_default_message_templates() || coalesce(v_settings.templates, '{}'::jsonb);
  v_payload := jsonb_build_object(
    'customer_name', v_customer.full_name,
    'barber_name', v_barber.display_name,
    'primary_barber_name', v_barber.display_name,
    'original_starts_at', v_original_start,
    'starts_at', v_start,
    'timezone', v_org.timezone,
    'templates', v_templates
  );

  if v_customer.phone_e164 is not null and v_client_consented then
    insert into public.whatsapp_automation_jobs (
      organization_id, connection_id, appointment_id, appointment_version,
      customer_id, priority, job_type, recipient_e164, payload,
      scheduled_for, next_attempt_at, valid_until, status, dedupe_key
    ) values (
      new.organization_id, v_connection.id, new.id, new.version,
      new.customer_id, 0, 'MANUAL_OUTBOUND_TEXT', v_customer.phone_e164,
      v_payload || jsonb_build_object('message_kind', 'APPOINTMENT_RESCHEDULED_CLIENT'),
      now(), now(), v_start, 'PENDING',
      'v2:' || new.id || ':v' || new.version || ':reschedule-notice:client'
    ) on conflict (organization_id, dedupe_key) do nothing;
  end if;

  if v_settings.staff_notifications_enabled then
    if v_barber.whatsapp_e164 is not null then
      insert into public.whatsapp_automation_jobs (
        organization_id, connection_id, appointment_id, appointment_version,
        customer_id, priority, job_type, recipient_e164, payload,
        scheduled_for, next_attempt_at, valid_until, status, dedupe_key
      ) values (
        new.organization_id, v_connection.id, new.id, new.version,
        new.customer_id, 0, 'MANUAL_OUTBOUND_TEXT', v_barber.whatsapp_e164,
        v_payload || jsonb_build_object('message_kind', 'APPOINTMENT_RESCHEDULED_STAFF'),
        now(), now(), v_start, 'PENDING',
        'v2:' || new.id || ':v' || new.version || ':reschedule-notice:staff'
      ) on conflict (organization_id, dedupe_key) do nothing;
    end if;

    for v_auxiliary in
      select assignment.id, assistant.whatsapp_e164, assistant.display_name
        from public.appointment_auxiliaries assignment
        join public.barbers assistant
          on assistant.id = assignment.assistant_barber_id
         and assistant.organization_id = assignment.organization_id
       where assignment.organization_id = new.organization_id
         and assignment.appointment_id = new.id
    loop
      if v_auxiliary.whatsapp_e164 is null then continue; end if;
      insert into public.whatsapp_automation_jobs (
        organization_id, connection_id, appointment_id, appointment_version,
        customer_id, priority, job_type, recipient_e164, payload,
        scheduled_for, next_attempt_at, valid_until, status, dedupe_key
      ) values (
        new.organization_id, v_connection.id, new.id, new.version,
        new.customer_id, 0, 'MANUAL_OUTBOUND_TEXT', v_auxiliary.whatsapp_e164,
        v_payload || jsonb_build_object(
          'message_kind', 'APPOINTMENT_RESCHEDULED_AUXILIARY',
          'message_audience', 'AUXILIARY',
          'barber_name', v_auxiliary.display_name
        ),
        now(), now(), v_start, 'PENDING',
        'v2:' || new.id || ':v' || new.version || ':reschedule-notice:auxiliary:' || v_auxiliary.id
      ) on conflict (organization_id, dedupe_key) do nothing;
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists zzz_appointments_enqueue_reschedule_whatsapp on public.appointments;
create trigger zzz_appointments_enqueue_reschedule_whatsapp
after update of service_period, barber_id on public.appointments
for each row execute function public.enqueue_appointment_reschedule_whatsapp();
drop trigger if exists zzz_appointments_enqueue_inserted_reschedule_whatsapp on public.appointments;
create trigger zzz_appointments_enqueue_inserted_reschedule_whatsapp
after insert on public.appointments
for each row execute function public.enqueue_appointment_reschedule_whatsapp();
revoke all on function public.enqueue_appointment_reschedule_whatsapp() from public, anon, authenticated;
