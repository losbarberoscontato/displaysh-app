create or replace function public.get_client_manager_notification_phone(
  p_organization_id uuid
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select settings.manager_notification_phone_e164
  from public.whatsapp_automation_settings_v2 as settings
  where settings.organization_id = p_organization_id
    and (select auth.uid()) is not null
    and exists (
      select 1
      from public.customers as customer
      join public.appointments as appointment
        on appointment.organization_id = customer.organization_id
       and appointment.customer_id = customer.id
      where customer.organization_id = settings.organization_id
        and customer.auth_user_id = (select auth.uid())
        and customer.active
        and customer.merged_into_customer_id is null
        and appointment.status in ('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE')
        and lower(appointment.service_period) >= now()
    )
  limit 1;
$$;

revoke all on function public.get_client_manager_notification_phone(uuid) from public, anon;
grant execute on function public.get_client_manager_notification_phone(uuid) to authenticated;
