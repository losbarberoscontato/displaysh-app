-- A time or professional change invalidates any confirmation for the previous
-- appointment version. Keep the appointment operationally confirmed, but ask
-- the client to confirm presence again for the new schedule.
create or replace function public.reset_whatsapp_confirmation_after_reschedule()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'CONFIRMED'
     and new.status = 'CONFIRMED'
     and (old.service_period is distinct from new.service_period
       or old.barber_id is distinct from new.barber_id) then
    new.whatsapp_response_status := 'PENDING'::public.appointment_whatsapp_response_status;
    new.whatsapp_presence_status := 'PENDING'::public.whatsapp_presence_status;
    new.whatsapp_presence_confirmed_at := null;
  end if;

  return new;
end;
$$;

revoke all on function public.reset_whatsapp_confirmation_after_reschedule()
  from public, anon, authenticated, service_role;

drop trigger if exists appointments_reset_whatsapp_confirmation_after_reschedule
  on public.appointments;
create trigger appointments_reset_whatsapp_confirmation_after_reschedule
  before update of service_period, barber_id on public.appointments
  for each row execute function public.reset_whatsapp_confirmation_after_reschedule();

-- Existing scheduling logic sends presence reminders on initial confirmation,
-- but not when an already-confirmed appointment gets a new time or professional.
create or replace function public.enqueue_whatsapp_presence_after_reschedule()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_settings public.whatsapp_automation_settings_v2%rowtype;
  v_connection_id uuid;
  v_rescheduled boolean;
  v_confirmation_reset boolean;
begin
  if new.status <> 'CONFIRMED' then return new; end if;

  v_rescheduled := old.service_period is distinct from new.service_period
    or old.barber_id is distinct from new.barber_id;
  v_confirmation_reset := old.whatsapp_response_status is distinct from new.whatsapp_response_status
    and new.whatsapp_response_status = 'PENDING';
  if not v_rescheduled and not v_confirmation_reset then return new; end if;

  select * into v_settings
  from public.whatsapp_automation_settings_v2
  where organization_id = new.organization_id;
  if not found or v_settings.mode <> 'ACTIVE' or v_settings.dispatch_paused then
    return new;
  end if;

  select connection.id into v_connection_id
  from public.whatsapp_business_connections as connection
  where connection.organization_id = new.organization_id
    and connection.provider = 'QR_WEB'
    and connection.is_active
    and connection.status = 'CONNECTED'
  order by connection.updated_at desc
  limit 1;
  if v_connection_id is null then return new; end if;

  perform public.whatsapp_v2_enqueue_presence_reminder(
    new.organization_id,
    new.id,
    v_connection_id,
    v_settings.templates
  );

  return new;
end;
$$;

revoke all on function public.enqueue_whatsapp_presence_after_reschedule()
  from public, anon, authenticated, service_role;

drop trigger if exists zzzz_appointments_enqueue_presence_after_reschedule
  on public.appointments;
create trigger zzzz_appointments_enqueue_presence_after_reschedule
  after update of service_period, barber_id, whatsapp_response_status on public.appointments
  for each row execute function public.enqueue_whatsapp_presence_after_reschedule();
