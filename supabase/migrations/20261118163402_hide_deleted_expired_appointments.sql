-- Keep expired appointments and their financial/audit references while hiding
-- them from customer, professional, and manager product views.
alter table public.appointments
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by_user_id uuid,
  add constraint appointments_deletion_metadata_check
    check ((deleted_at is null) = (deleted_by_user_id is null)),
  add constraint appointments_deleted_only_when_expired
    check (deleted_at is null or status = 'EXPIRED');

comment on column public.appointments.deleted_at is
  'Irreversible product-level deletion timestamp for expired appointments. The row and financial/audit references are retained.';
comment on column public.appointments.deleted_by_user_id is
  'Authenticated organization owner who removed the expired appointment from product views.';

create or replace function public.prevent_appointment_deletion_undo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.deleted_at is not null then
    if new.deleted_at is distinct from old.deleted_at
       or new.deleted_by_user_id is distinct from old.deleted_by_user_id then
      raise exception using errcode = '22023', message = 'appointment deletion is irreversible';
    end if;
    return new;
  end if;

  if new.deleted_at is not null then
    if old.status <> 'EXPIRED' then
      raise exception using errcode = '22023', message = 'only expired appointments can be deleted';
    end if;
    if auth.uid() is null
       or new.deleted_by_user_id is distinct from auth.uid()
       or not public.is_organization_owner(old.organization_id, auth.uid()) then
      raise exception using errcode = '42501', message = 'organization owner required to delete appointment';
    end if;
  elsif new.deleted_by_user_id is not null then
    raise exception using errcode = '22023', message = 'appointment deletion metadata is invalid';
  end if;

  return new;
end;
$$;

revoke all on function public.prevent_appointment_deletion_undo() from public, anon, authenticated;

drop trigger if exists appointments_prevent_deletion_undo on public.appointments;
create trigger appointments_prevent_deletion_undo
  before update of deleted_at, deleted_by_user_id on public.appointments
  for each row execute function public.prevent_appointment_deletion_undo();

create or replace function public.delete_expired_appointment(
  p_organization_id uuid,
  p_appointment_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appointment public.appointments%rowtype;
begin
  if p_organization_id is null or p_appointment_id is null then
    raise exception using errcode = '22023', message = 'organization and appointment are required';
  end if;
  if auth.uid() is null or not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization owner required';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id and organization_id = p_organization_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'appointment not found';
  end if;
  if v_appointment.deleted_at is not null then
    return jsonb_build_object('appointment_id', v_appointment.id, 'deleted', true, 'already_deleted', true);
  end if;
  if v_appointment.status <> 'EXPIRED' then
    raise exception using errcode = '22023', message = 'only expired appointments can be deleted';
  end if;

  -- A timed-out reservation must not leave a plan session looking booked.
  update public.customer_subscription_sessions
  set status = 'AVAILABLE', appointment_id = null, canceled_at = null, consumed_at = null
  where organization_id = p_organization_id
    and appointment_id = p_appointment_id
    and status = 'SCHEDULED';

  update public.project_engagement_sessions
  set status = 'OPEN', appointment_id = null, service_id = null, barber_id = null, updated_at = clock_timestamp()
  where organization_id = p_organization_id
    and appointment_id = p_appointment_id
    and status = 'BOOKED';

  update public.appointments
  set deleted_at = clock_timestamp(), deleted_by_user_id = auth.uid()
  where id = p_appointment_id and organization_id = p_organization_id;

  return jsonb_build_object('appointment_id', p_appointment_id, 'deleted', true, 'already_deleted', false);
end;
$$;

revoke all on function public.delete_expired_appointment(uuid, uuid) from public, anon;
grant execute on function public.delete_expired_appointment(uuid, uuid) to authenticated;

-- RLS is the shared visibility boundary for all Display products using this DB.
drop policy if exists appointments_owner_select on public.appointments;
create policy appointments_owner_select on public.appointments
  for select to authenticated
  using (deleted_at is null and public.can_access_organization(organization_id));

drop policy if exists appointments_customer_select on public.appointments;
create policy appointments_customer_select on public.appointments
  for select to authenticated
  using (deleted_at is null and public.is_organization_customer(organization_id, customer_id));

drop policy if exists appointments_barber_select on public.appointments;
create policy appointments_barber_select on public.appointments
  for select to authenticated
  using (deleted_at is null and public.can_operate_barber_agenda(organization_id, barber_id));
