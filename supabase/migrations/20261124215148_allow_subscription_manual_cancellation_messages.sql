-- Cancellation notices are operational messages. Subscription sessions must
-- still notify each available recipient when a manager cancels an appointment.
-- Keep automatic subscription booking notices paused.

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
          'MANUAL_CONFIRMATION_STAFF'
        )
      )
      and (
        exists (
          select 1
          from public.appointments appointment
          where appointment.id = new.appointment_id
            and appointment.organization_id = new.organization_id
            and (appointment.subscription_session_id is not null
              or appointment.subscription_bundle_session_id is not null)
        )
        or exists (
          select 1
          from public.customer_subscription_sessions session
          where session.appointment_id = new.appointment_id
            and session.organization_id = new.organization_id
        )
        or exists (
          select 1
          from public.subscription_bundle_sessions session
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
      and v_job.job_type::text not in (
        'CANCELLATION_ACK_CLIENT',
        'APPOINTMENT_CANCELED_STAFF'
      )
      and not (
        v_job.job_type::text = 'MANUAL_OUTBOUND_TEXT'
        and v_job.payload ->> 'message_kind' in (
          'MANUAL_CONFIRMATION_CLIENT',
          'MANUAL_CONFIRMATION_STAFF'
        )
      )
      and (
        exists (
          select 1
          from public.appointments appointment
          where appointment.id = v_job.appointment_id
            and appointment.organization_id = v_job.organization_id
            and (appointment.subscription_session_id is not null
              or appointment.subscription_bundle_session_id is not null)
        )
        or exists (
          select 1
          from public.customer_subscription_sessions session
          where session.appointment_id = v_job.appointment_id
            and session.organization_id = v_job.organization_id
        )
        or exists (
          select 1
          from public.subscription_bundle_sessions session
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
