-- Pause only subscription-originated WhatsApp traffic across all Display products.
-- Appointment traffic without a subscription session stays enabled.

drop trigger if exists subscription_created_whatsapp on public.customer_subscriptions;

create or replace function public.pause_subscription_whatsapp_job_insert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status in ('PENDING', 'RETRY') and (
    new.payload ->> 'message_kind' = 'SUBSCRIPTION_CREATED_CLIENT'
    or (
      new.appointment_id is not null
      and (
        exists (
          select 1 from public.appointments a
          where a.id = new.appointment_id
            and a.organization_id = new.organization_id
            and a.subscription_session_id is not null
        )
        or exists (
          select 1 from public.customer_subscription_sessions s
          where s.appointment_id = new.appointment_id
            and s.organization_id = new.organization_id
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

drop trigger if exists subscription_whatsapp_job_insert_paused
  on public.whatsapp_automation_jobs;
create trigger subscription_whatsapp_job_insert_paused
before insert on public.whatsapp_automation_jobs
for each row execute function public.pause_subscription_whatsapp_job_insert();

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
    or (
      v_job.appointment_id is not null
      and (
        exists (
          select 1 from public.appointments a
          where a.id = v_job.appointment_id
            and a.organization_id = v_job.organization_id
            and a.subscription_session_id is not null
        )
        or exists (
          select 1 from public.customer_subscription_sessions s
          where s.appointment_id = v_job.appointment_id
            and s.organization_id = v_job.organization_id
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

alter function public.whatsapp_runtime_prepare(uuid, uuid)
  rename to whatsapp_runtime_prepare_before_subscription_pause;

revoke all on function public.whatsapp_runtime_prepare_before_subscription_pause(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.whatsapp_runtime_prepare_before_subscription_pause(uuid, uuid)
  to service_role;

create function public.whatsapp_runtime_prepare(p_job_id uuid, p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_job public.whatsapp_automation_jobs%rowtype;
begin
  perform public.require_service_role();
  select * into v_job
    from public.whatsapp_automation_jobs
   where id = p_job_id
   for update;

  if v_job.id is null
     or v_job.status <> 'PROCESSING'
     or v_job.lease_token is distinct from p_token
     or v_job.lock_expires_at <= now() then
    raise exception 'STALE_LEASE';
  end if;

  if not public.whatsapp_v2_subscription_job_allowed(
    v_job.id,
    v_job.locked_by,
    p_token
  ) then
    return jsonb_build_object(
      'ready', false,
      'reason', 'SUBSCRIPTION_WHATSAPP_PAUSED'
    );
  end if;

  return public.whatsapp_runtime_prepare_before_subscription_pause(p_job_id, p_token);
end;
$$;

revoke all on function public.whatsapp_runtime_prepare(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.whatsapp_runtime_prepare(uuid, uuid)
  to service_role;

create or replace function public.pause_subscription_whatsapp_outbox()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status in ('PENDING', 'FAILED', 'PROCESSING') and (
    new.payload ->> 'subscription_session' = 'true'
    or new.payload ->> 'payment_mode' = 'SUBSCRIPTION'
    or (
      new.appointment_id is not null
      and (
        exists (
          select 1 from public.appointments a
          where a.id = new.appointment_id
            and a.organization_id = new.organization_id
            and a.subscription_session_id is not null
        )
        or exists (
          select 1 from public.customer_subscription_sessions s
          where s.appointment_id = new.appointment_id
            and s.organization_id = new.organization_id
        )
      )
    )
  ) then
    new.status := 'CANCELED';
    new.last_error := 'SUBSCRIPTION_WHATSAPP_PAUSED';
    new.claimed_at := null;
    new.claimed_by := null;
    new.lease_expires_at := null;
    new.updated_at := now();
  end if;
  return new;
end;
$$;

revoke all on function public.pause_subscription_whatsapp_outbox()
  from public, anon, authenticated;

drop trigger if exists subscription_whatsapp_outbox_paused
  on public.notification_outbox;
create trigger subscription_whatsapp_outbox_paused
before insert or update on public.notification_outbox
for each row execute function public.pause_subscription_whatsapp_outbox();

update public.notification_outbox n
   set status = 'CANCELED',
       last_error = 'SUBSCRIPTION_WHATSAPP_PAUSED',
       claimed_at = null,
       claimed_by = null,
       lease_expires_at = null,
       updated_at = now()
 where n.status in ('PENDING', 'FAILED', 'PROCESSING')
   and (
     n.payload ->> 'subscription_session' = 'true'
     or n.payload ->> 'payment_mode' = 'SUBSCRIPTION'
     or (
       n.appointment_id is not null
       and (
         exists (
           select 1 from public.appointments a
           where a.id = n.appointment_id
             and a.organization_id = n.organization_id
             and a.subscription_session_id is not null
         )
         or exists (
           select 1 from public.customer_subscription_sessions s
           where s.appointment_id = n.appointment_id
             and s.organization_id = n.organization_id
         )
       )
     )
   );

create or replace function public.begin_notification_send(
  p_outbox_id uuid,
  p_worker_id text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_service_role();

  update public.notification_outbox n
     set status = 'CANCELED',
         last_error = 'SUBSCRIPTION_WHATSAPP_PAUSED',
         claimed_at = null,
         claimed_by = null,
         lease_expires_at = null,
         updated_at = now()
   where n.id = p_outbox_id
     and n.status = 'PROCESSING'
     and n.claimed_by = p_worker_id
     and n.lease_expires_at > now()
     and (
       n.payload ->> 'subscription_session' = 'true'
       or n.payload ->> 'payment_mode' = 'SUBSCRIPTION'
       or (
         n.appointment_id is not null
         and (
           exists (
             select 1 from public.appointments a
             where a.id = n.appointment_id
               and a.organization_id = n.organization_id
               and a.subscription_session_id is not null
           )
           or exists (
             select 1 from public.customer_subscription_sessions s
             where s.appointment_id = n.appointment_id
               and s.organization_id = n.organization_id
           )
         )
       )
     );
  if found then
    return false;
  end if;

  update public.notification_outbox n
     set status = 'SENDING'
   where n.id = p_outbox_id
     and n.status = 'PROCESSING'
     and n.claimed_by = p_worker_id
     and n.lease_expires_at > now()
     and not (
       n.payload ->> 'subscription_session' = 'true'
       or n.payload ->> 'payment_mode' = 'SUBSCRIPTION'
       or (
         n.appointment_id is not null
         and (
           exists (
             select 1 from public.appointments a
             where a.id = n.appointment_id
               and a.organization_id = n.organization_id
               and a.subscription_session_id is not null
           )
           or exists (
             select 1 from public.customer_subscription_sessions s
             where s.appointment_id = n.appointment_id
               and s.organization_id = n.organization_id
           )
         )
       )
     )
     and exists (
       select 1
         from public.appointments a
         join public.customers c
           on c.id = a.customer_id and c.organization_id = a.organization_id
         join lateral (
           select ce.action
             from public.consent_events ce
            where ce.organization_id = c.organization_id
              and ce.customer_id = c.id
              and ce.kind = 'WHATSAPP_TRANSACTIONAL'
            order by ce.occurred_at desc, ce.created_at desc, ce.id desc
            limit 1
         ) latest_consent on latest_consent.action = 'GRANTED'
        where a.id = n.appointment_id
          and a.organization_id = n.organization_id
          and c.phone_e164 = n.recipient_e164
     );

  return found;
end;
$$;

revoke all on function public.begin_notification_send(uuid, text)
  from public, anon, authenticated;
grant execute on function public.begin_notification_send(uuid, text)
  to service_role;

create or replace function public.pause_subscription_whatsapp_confirmation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'PENDING' and (
    exists (
      select 1 from public.appointments a
      where a.id = new.appointment_id
        and a.organization_id = new.organization_id
        and a.subscription_session_id is not null
    )
    or exists (
      select 1 from public.customer_subscription_sessions s
      where s.appointment_id = new.appointment_id
        and s.organization_id = new.organization_id
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

drop trigger if exists subscription_whatsapp_confirmation_paused
  on public.whatsapp_confirmation_requests_v2;
create trigger subscription_whatsapp_confirmation_paused
before insert or update on public.whatsapp_confirmation_requests_v2
for each row execute function public.pause_subscription_whatsapp_confirmation();

update public.whatsapp_confirmation_requests_v2 r
   set status = 'EXPIRED',
       updated_at = now()
 where r.status = 'PENDING'
   and (
     exists (
       select 1 from public.appointments a
       where a.id = r.appointment_id
         and a.organization_id = r.organization_id
         and a.subscription_session_id is not null
     )
     or exists (
       select 1 from public.customer_subscription_sessions s
       where s.appointment_id = r.appointment_id
         and s.organization_id = r.organization_id
     )
   );

create or replace function public.pause_subscription_whatsapp_action_token()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (
    exists (
      select 1 from public.appointments a
      where a.id = new.appointment_id
        and a.organization_id = new.organization_id
        and a.subscription_session_id is not null
    )
    or exists (
      select 1 from public.customer_subscription_sessions s
      where s.appointment_id = new.appointment_id
        and s.organization_id = new.organization_id
    )
  ) then
    new.consumed_at := coalesce(new.consumed_at, now());
  end if;
  return new;
end;
$$;

revoke all on function public.pause_subscription_whatsapp_action_token()
  from public, anon, authenticated;

drop trigger if exists subscription_whatsapp_action_token_paused
  on public.customer_action_tokens;
create trigger subscription_whatsapp_action_token_paused
before insert or update on public.customer_action_tokens
for each row execute function public.pause_subscription_whatsapp_action_token();

update public.customer_action_tokens t
   set consumed_at = coalesce(t.consumed_at, now())
 where t.consumed_at is null
   and t.expires_at > now()
   and (
     exists (
       select 1 from public.appointments a
       where a.id = t.appointment_id
         and a.organization_id = t.organization_id
         and a.subscription_session_id is not null
     )
     or exists (
       select 1 from public.customer_subscription_sessions s
       where s.appointment_id = t.appointment_id
         and s.organization_id = t.organization_id
     )
   );
