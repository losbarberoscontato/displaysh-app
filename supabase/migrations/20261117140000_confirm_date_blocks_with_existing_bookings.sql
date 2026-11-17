create or replace function public.save_organization_date_block_with_conflicts(
  p_organization_id uuid,
  p_id uuid,
  p_block_type text,
  p_name text,
  p_description text,
  p_holiday_scope text,
  p_recurrence text,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time,
  p_confirmed_conflict_ids text[] default null
)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := coalesce(p_id, gen_random_uuid());
  v_timezone text;
  v_from date := p_start_date;
  v_to date := coalesce(p_end_date, p_start_date);
  v_conflict_ids text[];
  v_conflicts jsonb;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization owner required';
  end if;
  perform 1 from public.organizations where id = p_organization_id for update;
  select timezone into strict v_timezone from public.organizations where id = p_organization_id;
  if p_start_date is null or p_block_type is null or p_block_type not in ('HOLIDAY', 'RECESS', 'EVENT')
     or length(btrim(coalesce(p_name, ''))) not between 1 and 160 then
    raise exception using errcode = '22023', message = 'invalid date block';
  end if;
  if (p_block_type = 'HOLIDAY' and (p_holiday_scope is null or p_holiday_scope not in ('MUNICIPAL', 'STATE', 'FEDERAL') or p_recurrence is null or p_recurrence not in ('ANNUAL', 'YEAR') or p_end_date is not null or p_start_time is not null or p_end_time is not null))
    or (p_block_type = 'RECESS' and (p_end_date is null or p_end_date < p_start_date or p_holiday_scope is not null or p_recurrence is not null or p_start_time is not null or p_end_time is not null))
    or (p_block_type = 'EVENT' and (p_holiday_scope is not null or p_recurrence is not null or p_end_date is not null or p_start_time is null or p_end_time is null or p_end_time <= p_start_time)) then
    raise exception using errcode = '22023', message = 'invalid date block';
  end if;
  if p_recurrence = 'ANNUAL' then v_from := (now() at time zone v_timezone)::date; end if;

  select coalesce(array_agg(conflict.conflict_key order by conflict.conflict_key), '{}'::text[])
    into v_conflict_ids
    from (
      select 'APPOINTMENT:' || appointment.id::text conflict_key
        from public.appointments appointment
       where appointment.organization_id = p_organization_id
         and (appointment.status in ('CONFIRMED', 'IN_SERVICE') or (appointment.status in ('HELD', 'PENDING_PAYMENT') and appointment.hold_expires_at > now()))
         and ((p_recurrence = 'ANNUAL' and exists (
                select 1 from generate_series((lower(appointment.service_period) at time zone v_timezone)::date,
                  ((upper(appointment.service_period) - interval '1 microsecond') at time zone v_timezone)::date, interval '1 day') day
                 where day::date >= greatest((now() at time zone v_timezone)::date, p_start_date)
                   and extract(month from day) = extract(month from p_start_date) and extract(day from day) = extract(day from p_start_date)))
           or (p_block_type = 'EVENT' and tstzrange((p_start_date + p_start_time) at time zone v_timezone, (p_start_date + p_end_time) at time zone v_timezone, '[)') && appointment.service_period)
           or (p_recurrence is distinct from 'ANNUAL' and p_block_type <> 'EVENT'
               and (lower(appointment.service_period) at time zone v_timezone)::date <= v_to
               and ((upper(appointment.service_period) - interval '1 microsecond') at time zone v_timezone)::date >= v_from))
      union all
      select 'QUEUE_HOLD:' || hold.id::text conflict_key
        from public.walkin_queue_holds hold
       where hold.organization_id = p_organization_id and hold.consumed_at is null and hold.expires_at > now()
         and ((p_recurrence = 'ANNUAL' and exists (
                select 1 from generate_series((lower(hold.service_period) at time zone v_timezone)::date,
                  ((upper(hold.service_period) - interval '1 microsecond') at time zone v_timezone)::date, interval '1 day') day
                 where day::date >= greatest((now() at time zone v_timezone)::date, p_start_date)
                   and extract(month from day) = extract(month from p_start_date) and extract(day from day) = extract(day from p_start_date)))
           or (p_block_type = 'EVENT' and tstzrange((p_start_date + p_start_time) at time zone v_timezone, (p_start_date + p_end_time) at time zone v_timezone, '[)') && hold.service_period)
           or (p_recurrence is distinct from 'ANNUAL' and p_block_type <> 'EVENT'
               and (lower(hold.service_period) at time zone v_timezone)::date <= v_to
               and ((upper(hold.service_period) - interval '1 microsecond') at time zone v_timezone)::date >= v_from))
    ) conflict;

  select coalesce(jsonb_agg(conflict.detail order by conflict.sort_key), '[]'::jsonb)
    into v_conflicts
    from (
      select appointment.id::text sort_key,
        jsonb_build_object('key', 'APPOINTMENT:' || appointment.id::text, 'kind', 'APPOINTMENT',
          'name', coalesce(customer.full_name, 'Cliente'), 'professional', barber.display_name,
          'starts_at', lower(appointment.service_period)) detail
        from public.appointments appointment
        left join public.customers customer on customer.id = appointment.customer_id and customer.organization_id = appointment.organization_id
        left join public.barbers barber on barber.id = appointment.barber_id and barber.organization_id = appointment.organization_id
       where appointment.organization_id = p_organization_id
         and (appointment.status in ('CONFIRMED', 'IN_SERVICE') or (appointment.status in ('HELD', 'PENDING_PAYMENT') and appointment.hold_expires_at > now()))
         and ((p_recurrence = 'ANNUAL' and exists (
                select 1 from generate_series((lower(appointment.service_period) at time zone v_timezone)::date,
                  ((upper(appointment.service_period) - interval '1 microsecond') at time zone v_timezone)::date, interval '1 day') day
                 where day::date >= greatest((now() at time zone v_timezone)::date, p_start_date)
                   and extract(month from day) = extract(month from p_start_date) and extract(day from day) = extract(day from p_start_date)))
           or (p_block_type = 'EVENT' and tstzrange((p_start_date + p_start_time) at time zone v_timezone, (p_start_date + p_end_time) at time zone v_timezone, '[)') && appointment.service_period)
           or (p_recurrence is distinct from 'ANNUAL' and p_block_type <> 'EVENT'
               and (lower(appointment.service_period) at time zone v_timezone)::date <= v_to
               and ((upper(appointment.service_period) - interval '1 microsecond') at time zone v_timezone)::date >= v_from))
      union all
      select hold.id::text sort_key,
        jsonb_build_object('key', 'QUEUE_HOLD:' || hold.id::text, 'kind', 'QUEUE_HOLD',
          'name', 'Reserva de fila', 'professional', null, 'starts_at', lower(hold.service_period)) detail
        from public.walkin_queue_holds hold
       where hold.organization_id = p_organization_id and hold.consumed_at is null and hold.expires_at > now()
         and ((p_recurrence = 'ANNUAL' and exists (
                select 1 from generate_series((lower(hold.service_period) at time zone v_timezone)::date,
                  ((upper(hold.service_period) - interval '1 microsecond') at time zone v_timezone)::date, interval '1 day') day
                 where day::date >= greatest((now() at time zone v_timezone)::date, p_start_date)
                   and extract(month from day) = extract(month from p_start_date) and extract(day from day) = extract(day from p_start_date)))
           or (p_block_type = 'EVENT' and tstzrange((p_start_date + p_start_time) at time zone v_timezone, (p_start_date + p_end_time) at time zone v_timezone, '[)') && hold.service_period)
           or (p_recurrence is distinct from 'ANNUAL' and p_block_type <> 'EVENT'
               and (lower(hold.service_period) at time zone v_timezone)::date <= v_to
               and ((upper(hold.service_period) - interval '1 microsecond') at time zone v_timezone)::date >= v_from))
    ) conflict;

  if cardinality(v_conflict_ids) > 0
     and (p_confirmed_conflict_ids is null or p_confirmed_conflict_ids is distinct from v_conflict_ids) then
    return jsonb_build_object('saved', false, 'requires_confirmation', true,
      'conflict_ids', to_jsonb(v_conflict_ids), 'conflicts', v_conflicts);
  end if;
  if exists (
    select 1 from public.organization_date_blocks block
    where block.organization_id = p_organization_id and block.id is distinct from p_id
      and ((p_recurrence = 'ANNUAL' and (
          (block.recurrence = 'ANNUAL' and extract(month from block.start_date) = extract(month from p_start_date) and extract(day from block.start_date) = extract(day from p_start_date))
          or (block.block_type <> 'EVENT' and exists (
            select 1 from generate_series(greatest((now() at time zone v_timezone)::date, block.start_date, p_start_date), coalesce(block.end_date,block.start_date), interval '1 day') day
            where extract(month from day) = extract(month from p_start_date) and extract(day from day) = extract(day from p_start_date)))
          or (block.block_type = 'EVENT' and block.start_date >= (now() at time zone v_timezone)::date
            and extract(month from block.start_date) = extract(month from p_start_date) and extract(day from block.start_date) = extract(day from p_start_date))))
        or (p_recurrence is distinct from 'ANNUAL' and block.recurrence = 'ANNUAL' and exists (
          select 1 from generate_series(v_from, v_to, interval '1 day') day
          where day::date >= block.start_date and extract(month from day) = extract(month from block.start_date) and extract(day from day) = extract(day from block.start_date)))
        or (p_recurrence is distinct from 'ANNUAL' and block.recurrence is distinct from 'ANNUAL' and block.start_date <= v_to and coalesce(block.end_date,block.start_date) >= v_from))
  ) then raise exception using errcode = '23P01', message = 'date block overlaps an existing date block'; end if;

  insert into public.organization_date_blocks (id, organization_id, block_type, name, description, holiday_scope, recurrence, start_date, end_date, start_time, end_time, updated_at)
  values (v_id, p_organization_id, p_block_type, btrim(p_name), nullif(btrim(coalesce(p_description,'')),''), p_holiday_scope, p_recurrence, p_start_date, p_end_date, p_start_time, p_end_time, now())
  on conflict (id) do update set block_type = excluded.block_type, name = excluded.name, description = excluded.description,
    holiday_scope = excluded.holiday_scope, recurrence = excluded.recurrence, start_date = excluded.start_date,
    end_date = excluded.end_date, start_time = excluded.start_time, end_time = excluded.end_time, updated_at = now()
  where organization_date_blocks.organization_id = p_organization_id;
  return jsonb_build_object('saved', true, 'requires_confirmation', false, 'id', v_id, 'conflicts', v_conflicts);
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization not found';
end;
$$;

revoke all on function public.save_organization_date_block_with_conflicts(uuid, uuid, text, text, text, text, text, date, date, time, time, text[])
  from public, anon;
grant execute on function public.save_organization_date_block_with_conflicts(uuid, uuid, text, text, text, text, text, date, date, time, time, text[])
  to authenticated;

create or replace function public.list_organization_date_block_conflicts(p_organization_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_timezone text;
  v_result jsonb;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'organization owner required';
  end if;
  select timezone into strict v_timezone from public.organizations where id = p_organization_id;
  select coalesce(jsonb_agg(conflict.detail order by conflict.starts_at), '[]'::jsonb)
    into v_result
    from (
      select lower(appointment.service_period) starts_at,
        jsonb_build_object('block_id', block.id, 'block_name', block.name,
          'booking_id', appointment.id, 'booking_type', 'APPOINTMENT',
          'customer_name', coalesce(customer.full_name, 'Cliente'), 'professional_name', barber.display_name,
          'starts_at', lower(appointment.service_period)) detail
        from public.organization_date_blocks block
        join public.appointments appointment on appointment.organization_id = block.organization_id
        left join public.customers customer on customer.id = appointment.customer_id and customer.organization_id = appointment.organization_id
        left join public.barbers barber on barber.id = appointment.barber_id and barber.organization_id = appointment.organization_id
       where block.organization_id = p_organization_id
         and (appointment.status in ('CONFIRMED', 'IN_SERVICE') or (appointment.status in ('HELD', 'PENDING_PAYMENT') and appointment.hold_expires_at > now()))
         and ((block.recurrence = 'ANNUAL' and exists (
                select 1 from generate_series((lower(appointment.service_period) at time zone v_timezone)::date,
                  ((upper(appointment.service_period) - interval '1 microsecond') at time zone v_timezone)::date, interval '1 day') day
                 where day::date >= (now() at time zone v_timezone)::date
                   and extract(month from day) = extract(month from block.start_date) and extract(day from day) = extract(day from block.start_date)))
           or (block.block_type = 'EVENT' and tstzrange((block.start_date + block.start_time) at time zone v_timezone, (block.start_date + block.end_time) at time zone v_timezone, '[)') && appointment.service_period)
           or (block.recurrence is distinct from 'ANNUAL' and block.block_type <> 'EVENT'
               and (lower(appointment.service_period) at time zone v_timezone)::date <= coalesce(block.end_date, block.start_date)
               and ((upper(appointment.service_period) - interval '1 microsecond') at time zone v_timezone)::date >= block.start_date))
      union all
      select lower(hold.service_period) starts_at,
        jsonb_build_object('block_id', block.id, 'block_name', block.name,
          'booking_id', hold.id, 'booking_type', 'QUEUE_HOLD',
          'customer_name', 'Reserva de fila', 'professional_name', null,
          'starts_at', lower(hold.service_period)) detail
        from public.organization_date_blocks block
        join public.walkin_queue_holds hold on hold.organization_id = block.organization_id
       where block.organization_id = p_organization_id and hold.consumed_at is null and hold.expires_at > now()
         and ((block.recurrence = 'ANNUAL' and exists (
                select 1 from generate_series((lower(hold.service_period) at time zone v_timezone)::date,
                  ((upper(hold.service_period) - interval '1 microsecond') at time zone v_timezone)::date, interval '1 day') day
                 where day::date >= (now() at time zone v_timezone)::date
                   and extract(month from day) = extract(month from block.start_date) and extract(day from day) = extract(day from block.start_date)))
           or (block.block_type = 'EVENT' and tstzrange((block.start_date + block.start_time) at time zone v_timezone, (block.start_date + block.end_time) at time zone v_timezone, '[)') && hold.service_period)
           or (block.recurrence is distinct from 'ANNUAL' and block.block_type <> 'EVENT'
               and (lower(hold.service_period) at time zone v_timezone)::date <= coalesce(block.end_date, block.start_date)
               and ((upper(hold.service_period) - interval '1 microsecond') at time zone v_timezone)::date >= block.start_date))
    ) conflict;
  return v_result;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization not found';
end;
$$;

revoke all on function public.list_organization_date_block_conflicts(uuid) from public, anon;
grant execute on function public.list_organization_date_block_conflicts(uuid) to authenticated;
