create table app_private.barber_schedule_batch_requests (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  barber_id uuid not null,
  request_id uuid not null,
  weekday smallint not null check (weekday between 0 and 6),
  environment_id uuid not null,
  start_times text[] not null check (cardinality(start_times) between 1 and 14),
  response jsonb,
  created_at timestamptz not null default now(),
  primary key (organization_id, barber_id, request_id),
  foreign key (barber_id, organization_id)
    references public.barbers(id, organization_id) on delete cascade,
  foreign key (environment_id, organization_id)
    references public.agenda_environments(id, organization_id) on delete cascade
);

alter table app_private.barber_schedule_batch_requests enable row level security;
revoke all on app_private.barber_schedule_batch_requests from public, anon, authenticated, service_role;
comment on table app_private.barber_schedule_batch_requests is
  'Idempotency records for atomic weekly schedule interval batches submitted by professionals.';

create or replace function app_private.add_my_barber_schedule_intervals(
  p_organization_id uuid,
  p_barber_id uuid,
  p_weekday smallint,
  p_environment_id uuid,
  p_start_times text[],
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_start_times text[];
  v_start_text text;
  v_start_time time;
  v_existing app_private.barber_schedule_batch_requests%rowtype;
  v_response jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_organization_id is null or p_barber_id is null or p_environment_id is null or p_request_id is null then
    raise exception using errcode = '22023', message = 'organization, professional, environment, and request are required';
  end if;
  if p_weekday is null or p_weekday not between 0 and 6 then
    raise exception using errcode = '22023', message = 'valid weekday required';
  end if;
  if p_start_times is null or cardinality(p_start_times) not between 1 and 14 then
    raise exception using errcode = '22023', message = 'select at least one available time';
  end if;
  if exists (
    select 1
    from unnest(p_start_times) as requested(start_time)
    where requested.start_time is null
      or requested.start_time !~ '^(0[8-9]|1[0-9]|2[01]):00$'
  ) then
    raise exception using errcode = '22023', message = 'select valid one-hour times between 08:00 and 22:00';
  end if;

  select array_agg(distinct requested.start_time order by requested.start_time)
  into v_start_times
  from unnest(p_start_times) as requested(start_time);
  if cardinality(v_start_times) <> cardinality(p_start_times) then
    raise exception using errcode = '22023', message = 'duplicate schedule times are not allowed';
  end if;

  select barber.location_id into v_location_id
  from public.barbers barber
  where barber.id = p_barber_id
    and barber.organization_id = p_organization_id
    and barber.auth_user_id = auth.uid()
    and barber.active
    and barber.app_access_enabled;
  if not found then
    raise exception using errcode = '42501', message = 'barber schedule access denied';
  end if;
  if not exists (
    select 1
    from public.agenda_environments environment
    where environment.id = p_environment_id
      and environment.organization_id = p_organization_id
      and environment.location_id = v_location_id
      and environment.active
  ) then
    raise exception using errcode = '22023', message = 'select an active agenda environment';
  end if;

  insert into app_private.barber_schedule_batch_requests (
    organization_id, barber_id, request_id, weekday, environment_id, start_times
  ) values (
    p_organization_id, p_barber_id, p_request_id, p_weekday, p_environment_id, v_start_times
  ) on conflict (organization_id, barber_id, request_id) do nothing;

  if not found then
    select request.* into v_existing
    from app_private.barber_schedule_batch_requests request
    where request.organization_id = p_organization_id
      and request.barber_id = p_barber_id
      and request.request_id = p_request_id
    for update;
    if not found then
      raise exception using errcode = '40001', message = 'schedule request could not be locked; retry';
    end if;
    if v_existing.weekday is distinct from p_weekday
       or v_existing.environment_id is distinct from p_environment_id
       or v_existing.start_times is distinct from v_start_times then
      raise exception using errcode = '22023', message = 'request ID was already used for a different schedule';
    end if;
    if v_existing.response is null then
      raise exception using errcode = '40001', message = 'schedule request is still processing; retry';
    end if;
    return v_existing.response;
  end if;

  for v_start_text in
    select requested.start_time
    from unnest(v_start_times) as requested(start_time)
    order by requested.start_time
  loop
    v_start_time := v_start_text::time;
    perform public.mutate_barber_schedule(
      p_organization_id,
      p_barber_id,
      'ADD_INTERVAL',
      p_weekday => p_weekday,
      p_starts_at => v_start_time,
      p_ends_at => v_start_time + interval '1 hour',
      p_environment_id => p_environment_id
    );
  end loop;

  v_response := jsonb_build_object(
    'count', cardinality(v_start_times),
    'start_times', to_jsonb(v_start_times),
    'message', case
      when cardinality(v_start_times) = 1 then '1 horário adicionado à escala.'
      else format('%s horários adicionados à escala.', cardinality(v_start_times))
    end
  );
  update app_private.barber_schedule_batch_requests request
  set response = v_response
  where request.organization_id = p_organization_id
    and request.barber_id = p_barber_id
    and request.request_id = p_request_id;

  return v_response;
end;
$$;

revoke all on function app_private.add_my_barber_schedule_intervals(uuid, uuid, smallint, uuid, text[], uuid)
  from public, anon, authenticated, service_role;
grant usage on schema app_private to authenticated;
grant execute on function app_private.add_my_barber_schedule_intervals(uuid, uuid, smallint, uuid, text[], uuid)
  to authenticated;

create or replace function public.add_my_barber_schedule_intervals(
  p_organization_id uuid,
  p_barber_id uuid,
  p_weekday smallint,
  p_environment_id uuid,
  p_start_times text[],
  p_request_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.add_my_barber_schedule_intervals(
    p_organization_id, p_barber_id, p_weekday, p_environment_id, p_start_times, p_request_id
  );
$$;

revoke all on function public.add_my_barber_schedule_intervals(uuid, uuid, smallint, uuid, text[], uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.add_my_barber_schedule_intervals(uuid, uuid, smallint, uuid, text[], uuid)
  to authenticated;
