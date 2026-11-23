-- Re-enable configured WhatsApp presence reminders for active subscription
-- sessions. Keep subscription booking announcements paused; only reminder jobs
-- may pass the subscription guards.

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

revoke all on function public.pause_subscription_whatsapp_job_insert()
  from public, anon, authenticated;

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

  select * into v_job
    from public.whatsapp_automation_jobs
   where id = p_job_id
   for update;

  if not found
     or v_job.status <> 'PROCESSING'
     or v_job.locked_by is distinct from p_worker_id
     or (p_lease_token is not null and v_job.lease_token is distinct from p_lease_token) then
    return false;
  end if;

  v_subscription_job := v_job.payload ->> 'message_kind' = 'SUBSCRIPTION_CREATED_CLIENT'
    or v_job.payload ->> 'payment_mode' = 'SUBSCRIPTION'
    or (
      v_job.appointment_id is not null
      and v_job.job_type::text not in (
        'REMINDER_T24_CLIENT',
        'REMINDER_MORNING_CLIENT',
        'REMINDER_T180_CLIENT',
        'REMINDER_T45_CLIENT'
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
         set status = 'SKIPPED',
             last_error_code = 'SUBSCRIPTION_WHATSAPP_PAUSED',
             locked_at = null,
             locked_by = null,
             lock_expires_at = null,
             lease_token = null,
             updated_at = now()
       where id = v_job.id;
    end if;
    return false;
  end if;

  return true;
end;
$$;

revoke all on function public.whatsapp_v2_subscription_job_allowed(uuid, text, uuid)
  from public, anon, authenticated;
grant execute on function public.whatsapp_v2_subscription_job_allowed(uuid, text, uuid)
  to service_role;

-- A confirmation request is valid only when it belongs to one of the reminder
-- jobs the manager configured. Other subscription-linked confirmation flows
-- remain paused.
create or replace function public.pause_subscription_whatsapp_confirmation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'PENDING'
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
     and not exists (
       select 1 from public.whatsapp_automation_jobs job
       where job.id = new.job_id
         and job.organization_id = new.organization_id
         and job.appointment_id = new.appointment_id
         and job.appointment_version = new.appointment_version
         and job.job_type::text in (
           'REMINDER_T24_CLIENT',
           'REMINDER_MORNING_CLIENT',
           'REMINDER_T180_CLIENT',
           'REMINDER_T45_CLIENT'
         )
     ) then
    new.status := 'EXPIRED';
    new.updated_at := now();
  end if;
  return new;
end;
$$;

revoke all on function public.pause_subscription_whatsapp_confirmation()
  from public, anon, authenticated;

create or replace function public.pause_bundle_subscription_whatsapp_confirmation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'PENDING'
     and exists (
       select 1 from public.appointments appointment
       where appointment.id = new.appointment_id
         and appointment.organization_id = new.organization_id
         and appointment.subscription_bundle_session_id is not null
     )
     and not exists (
       select 1 from public.whatsapp_automation_jobs job
       where job.id = new.job_id
         and job.organization_id = new.organization_id
         and job.appointment_id = new.appointment_id
         and job.appointment_version = new.appointment_version
         and job.job_type::text in (
           'REMINDER_T24_CLIENT',
           'REMINDER_MORNING_CLIENT',
           'REMINDER_T180_CLIENT',
           'REMINDER_T45_CLIENT'
         )
     ) then
    new.status := 'EXPIRED';
    new.updated_at := now();
  end if;
  return new;
end;
$$;

revoke all on function public.pause_bundle_subscription_whatsapp_confirmation()
  from public, anon, authenticated;

-- The pause migration already marked queued subscription reminders as SKIPPED.
-- Rebuild only future sessions that had a paused reminder, using a stable
-- suffix so migration retries cannot enqueue duplicates.
do $$
declare
  v_candidate record;
begin
  for v_candidate in
    with linked_sessions as (
      select session.organization_id, session.appointment_id, session.subscription_id
        from public.customer_subscription_sessions session
       where session.appointment_id is not null
         and session.status = 'SCHEDULED'
      union
      select session.organization_id, session.appointment_id, session.subscription_id
        from public.subscription_bundle_sessions session
       where session.appointment_id is not null
         and session.status = 'SCHEDULED'
    )
    select distinct
      appointment.organization_id,
      appointment.id as appointment_id,
      connection.id as connection_id,
      settings.templates
    from linked_sessions linked
    join public.appointments appointment
      on appointment.id = linked.appointment_id
     and appointment.organization_id = linked.organization_id
    join public.customer_subscriptions subscription
      on subscription.id = linked.subscription_id
     and subscription.organization_id = linked.organization_id
    join public.whatsapp_automation_settings_v2 settings
      on settings.organization_id = appointment.organization_id
    join lateral (
      select business_connection.id
        from public.whatsapp_business_connections business_connection
       where business_connection.organization_id = appointment.organization_id
         and business_connection.provider = 'QR_WEB'
         and business_connection.is_active
       order by business_connection.updated_at desc, business_connection.id desc
       limit 1
    ) connection on true
    where appointment.status = 'CONFIRMED'
      and lower(appointment.service_period) > now()
      and subscription.status in ('ACTIVE', 'PENDING_PAYMENT')
      and (subscription.contract_accepted_at is not null
        or subscription.manager_activated_provisionally_at is not null)
      and settings.mode = 'ACTIVE'
      and not settings.dispatch_paused
      and (settings.reminder_t24_enabled
        or settings.reminder_morning_enabled
        or settings.reminder_t180_enabled
        or settings.reminder_t45_enabled)
      and exists (
        select 1 from public.whatsapp_automation_jobs paused_job
        where paused_job.organization_id = appointment.organization_id
          and paused_job.appointment_id = appointment.id
          and paused_job.appointment_version = appointment.version
          and paused_job.job_type::text in (
            'REMINDER_T24_CLIENT',
            'REMINDER_MORNING_CLIENT',
            'REMINDER_T180_CLIENT',
            'REMINDER_T45_CLIENT'
          )
          and paused_job.status = 'SKIPPED'
          and paused_job.last_error_code = 'SUBSCRIPTION_WHATSAPP_PAUSED'
          and paused_job.scheduled_for > now()
          and (
            (settings.reminder_t24_enabled
              and paused_job.job_type::text = 'REMINDER_T24_CLIENT')
            or (not settings.reminder_t24_enabled and settings.reminder_morning_enabled
              and paused_job.job_type::text = 'REMINDER_MORNING_CLIENT')
            or (not settings.reminder_t24_enabled and not settings.reminder_morning_enabled
              and settings.reminder_t180_enabled
              and paused_job.job_type::text = 'REMINDER_T180_CLIENT')
            or (not settings.reminder_t24_enabled and not settings.reminder_morning_enabled
              and not settings.reminder_t180_enabled and settings.reminder_t45_enabled
              and paused_job.job_type::text = 'REMINDER_T45_CLIENT')
          )
      )
      and not exists (
        select 1 from public.whatsapp_automation_jobs active_job
        where active_job.organization_id = appointment.organization_id
          and active_job.appointment_id = appointment.id
          and active_job.appointment_version = appointment.version
          and active_job.job_type::text in (
            'REMINDER_T24_CLIENT',
            'REMINDER_MORNING_CLIENT',
            'REMINDER_T180_CLIENT',
            'REMINDER_T45_CLIENT'
          )
          and active_job.status in ('PENDING', 'RETRY', 'PROCESSING')
      )
  loop
    perform public.whatsapp_v2_enqueue_presence_reminder(
      v_candidate.organization_id,
      v_candidate.appointment_id,
      v_candidate.connection_id,
      v_candidate.templates,
      ':subscription-reminders-reactivated'
    );
  end loop;
end;
$$;
