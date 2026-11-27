create or replace function public.get_barber_manual_appointment_slots(
  p_organization_id uuid,
  p_barber_id uuid,
  p_local_date date,
  p_selections jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org public.organizations%rowtype;
  v_location_id uuid;
  v_availability jsonb;
  v_slot jsonb;
  v_environment record;
  v_period tstzrange;
  v_resolved_environment_id uuid;
  v_starts_at timestamptz;
  v_slots jsonb := '[]'::jsonb;
  v_seen_starts timestamptz[] := array[]::timestamptz[];
  v_today date;
begin
  if auth.uid() is null or not public.can_operate_barber_agenda(p_organization_id, p_barber_id) then
    raise exception using errcode = '42501', message = 'barber agenda access denied';
  end if;
  if p_local_date is null then
    raise exception using errcode = '22023', message = 'availability date is required';
  end if;
  if jsonb_typeof(p_selections) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'selections must be a JSON array';
  end if;
  if jsonb_array_length(p_selections) = 0 then
    raise exception using errcode = '22023', message = 'selections must be a non-empty JSON array';
  end if;

  select organization.* into strict v_org
  from public.organizations organization
  where organization.id = p_organization_id;
  select barber.location_id into strict v_location_id
  from public.barbers barber
  where barber.id = p_barber_id
    and barber.organization_id = p_organization_id
    and barber.active;

  v_today := (now() at time zone v_org.timezone)::date;
  if p_local_date < v_today or p_local_date > v_today + 180 then
    raise exception using errcode = '22023', message = 'availability date outside allowed window';
  end if;

  if p_local_date <= v_today + 15 then
    v_availability := public.get_available_slots(v_org.slug, p_barber_id, p_local_date, p_selections);
  else
    v_availability := public.get_available_slots_legacy_window(v_org.slug, p_barber_id, p_local_date, p_selections);
  end if;

  for v_slot in
    select value
    from jsonb_array_elements(coalesce(v_availability -> 'slots', '[]'::jsonb))
  loop
    v_starts_at := (v_slot ->> 'starts_at')::timestamptz;
    v_period := tstzrange(v_starts_at, (v_slot ->> 'ends_at')::timestamptz, '[)');
    if public.organization_date_blocked(p_organization_id, v_period) then
      continue;
    end if;

    for v_environment in
      select environment.id
      from public.agenda_environments environment
      where environment.organization_id = p_organization_id
        and environment.location_id = v_location_id
        and environment.active
      order by environment.sort_order, environment.name, environment.id
    loop
      begin
        v_resolved_environment_id := public.resolve_appointment_environment(
          p_organization_id,
          p_barber_id,
          v_location_id,
          v_period,
          v_environment.id,
          null
        );
      exception
        when sqlstate '22023' or sqlstate '23P01' then
          continue;
      end;

      if v_resolved_environment_id = v_environment.id then
        if not (v_starts_at = any(v_seen_starts)) then
          v_slots := v_slots || jsonb_build_array(jsonb_build_object(
            'starts_at', v_slot -> 'starts_at',
            'ends_at', v_slot -> 'ends_at'
          ));
          v_seen_starts := array_append(v_seen_starts, v_starts_at);
        end if;
        exit;
      end if;
    end loop;
  end loop;

  return jsonb_build_object('slots', v_slots);
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization or active barber not found';
end;
$$;

revoke all on function public.get_barber_manual_appointment_slots(uuid, uuid, date, jsonb) from public, anon;
grant execute on function public.get_barber_manual_appointment_slots(uuid, uuid, date, jsonb) to authenticated;
