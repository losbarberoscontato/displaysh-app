-- A declined provisional subscription can cancel many future sessions in one
-- transaction. Keep staff notices per appointment, but do not send the same
-- cancellation acknowledgement to the client once per session.
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

  -- The appointment status event is written in the same transaction as the
  -- cancellation. It is visible by the time a queued job can be claimed.
  if j.job_type = 'CANCELLATION_ACK_CLIENT' and exists (
    select 1
      from public.appointment_status_events event
     where event.organization_id = j.organization_id
       and event.appointment_id = j.appointment_id
       and event.to_status = 'CANCELED'
       and event.reason = 'subscription_offer_declined'
  ) then
    reason := 'SUBSCRIPTION_OFFER_DECLINED';
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
