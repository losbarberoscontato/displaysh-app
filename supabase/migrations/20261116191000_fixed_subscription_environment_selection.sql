alter table public.customer_subscriptions
  add column if not exists fixed_schedule_environment_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'customer_subscriptions_fixed_schedule_environment_fk'
      and conrelid = 'public.customer_subscriptions'::regclass
  ) then
    alter table public.customer_subscriptions
      add constraint customer_subscriptions_fixed_schedule_environment_fk
      foreign key (fixed_schedule_environment_id, organization_id)
      references public.agenda_environments (id, organization_id);
  end if;
end;
$$;

create or replace function public.fixed_subscription_schedule_preview(
  p_organization_id uuid,
  p_plan_version_id uuid,
  p_barber_id uuid,
  p_start_date date,
  p_local_time time,
  p_cadence_weeks smallint,
  p_timezone text,
  p_environment_id uuid
)
returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_schedule jsonb;
  v_occurrence jsonb;
  v_plan public.subscription_plan_versions%rowtype;
  v_org public.organizations%rowtype;
  v_barber public.barbers%rowtype;
  v_items jsonb;
  v_resolution jsonb;
  v_occupied_minutes integer;
  v_start timestamptz;
  v_period tstzrange;
begin
  if p_environment_id is null then
    raise exception using errcode = '22023', message = 'fixed subscription environment is required';
  end if;
  v_schedule := public.fixed_subscription_schedule_preview(
    p_organization_id, p_plan_version_id, p_barber_id, p_start_date,
    p_local_time, p_cadence_weeks, p_timezone
  );
  select * into strict v_org from public.organizations where id = p_organization_id;
  select * into strict v_plan from public.subscription_plan_versions
   where id = p_plan_version_id and organization_id = p_organization_id;
  select * into strict v_barber from public.barbers
   where id = p_barber_id and organization_id = p_organization_id and active;
  select coalesce(jsonb_agg(jsonb_build_object('type', 'SERVICE', 'service_id', service_id, 'quantity', 1) order by position), '[]'::jsonb)
    into v_items
    from public.subscription_plan_services
   where organization_id = p_organization_id and plan_version_id = v_plan.id;
  v_resolution := public.resolve_booking_selection(p_organization_id, p_barber_id, v_items, null);
  v_occupied_minutes := ceil((v_resolution ->> 'duration_minutes')::numeric / v_org.slot_interval_minutes)::integer
    * v_org.slot_interval_minutes;
  for v_occurrence in select value from jsonb_array_elements(v_schedule)
  loop
    v_start := (v_occurrence ->> 'starts_at')::timestamptz;
    v_period := tstzrange(v_start, v_start + make_interval(mins => v_occupied_minutes), '[)');
    if public.resolve_appointment_environment(
      p_organization_id, p_barber_id, v_barber.location_id, v_period, p_environment_id
    ) is null then
      raise exception using errcode = '23P01', message = 'fixed_schedule_conflict: sala escolhida não está disponível em uma das sessões';
    end if;
  end loop;
  return v_schedule;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization, plan or barber not found';
end;
$$;

revoke all on function public.fixed_subscription_schedule_preview(uuid, uuid, uuid, date, time, smallint, text, uuid)
  from public, anon, authenticated, service_role;

create or replace function public.request_customer_fixed_subscription(
  p_organization_id uuid,
  p_customer_id uuid,
  p_plan_id uuid,
  p_cadence_weeks smallint,
  p_start_date date,
  p_local_time time,
  p_barber_id uuid,
  p_environment_id uuid,
  p_acceptance_source text default 'CLIENT',
  p_accept_contract boolean default true
)
returns public.customer_subscriptions
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_plan public.subscription_plan_versions%rowtype;
  v_timezone text;
begin
  v_sub := public.request_customer_fixed_subscription(
    p_organization_id, p_customer_id, p_plan_id, p_cadence_weeks,
    p_start_date, p_local_time, p_barber_id, p_acceptance_source, p_accept_contract
  );
  select * into strict v_plan from public.subscription_plan_versions
   where plan_id = p_plan_id and organization_id = p_organization_id
   order by version desc limit 1;
  select timezone into strict v_timezone from public.organizations where id = p_organization_id;
  perform public.fixed_subscription_schedule_preview(
    p_organization_id, v_plan.id, p_barber_id, p_start_date,
    p_local_time, p_cadence_weeks, v_timezone, p_environment_id
  );
  update public.customer_subscriptions
     set fixed_schedule_environment_id = p_environment_id
   where id = v_sub.id and organization_id = p_organization_id
  returning * into v_sub;
  return v_sub;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization or subscription plan not found';
end;
$$;

revoke all on function public.request_customer_fixed_subscription(uuid, uuid, uuid, smallint, date, time, uuid, uuid, text, boolean)
  from public, anon;
grant execute on function public.request_customer_fixed_subscription(uuid, uuid, uuid, smallint, date, time, uuid, uuid, text, boolean)
  to authenticated;

create or replace function public.update_customer_fixed_subscription_schedule(
  p_organization_id uuid,
  p_subscription_id uuid,
  p_cadence_weeks smallint,
  p_start_date date,
  p_local_time time,
  p_barber_id uuid,
  p_environment_id uuid
)
returns public.customer_subscriptions
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
begin
  v_sub := public.update_customer_fixed_subscription_schedule(
    p_organization_id, p_subscription_id, p_cadence_weeks,
    p_start_date, p_local_time, p_barber_id
  );
  perform public.fixed_subscription_schedule_preview(
    p_organization_id, v_sub.plan_version_id, p_barber_id, p_start_date,
    p_local_time, p_cadence_weeks, v_sub.fixed_schedule_timezone, p_environment_id
  );
  update public.customer_subscriptions
     set fixed_schedule_environment_id = p_environment_id
   where id = p_subscription_id and organization_id = p_organization_id
  returning * into v_sub;
  return v_sub;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription, plan or barber not found';
end;
$$;

revoke all on function public.update_customer_fixed_subscription_schedule(uuid, uuid, smallint, date, time, uuid, uuid)
  from public, anon;
grant execute on function public.update_customer_fixed_subscription_schedule(uuid, uuid, smallint, date, time, uuid, uuid)
  to authenticated;

create or replace function public.schedule_fixed_subscription_sessions(
  p_organization_id uuid,
  p_subscription_id uuid
)
returns integer
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_plan public.subscription_plan_versions%rowtype;
  v_session public.customer_subscription_sessions%rowtype;
  v_schedule jsonb;
  v_items jsonb;
  v_appointment_id uuid;
  v_count integer := 0;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription schedule generation denied';
  end if;
  select * into strict v_sub from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id for update;
  select * into strict v_plan from public.subscription_plan_versions
   where id = v_sub.plan_version_id and organization_id = p_organization_id;
  if v_plan.scheduling_mode <> 'FIXED' then return 0; end if;
  if v_sub.status <> 'ACTIVE' or v_sub.fixed_schedule_created_at is not null then return 0; end if;
  if v_sub.fixed_schedule_cadence_weeks is null then
    raise exception using errcode = '22023', message = 'fixed subscription schedule is missing';
  end if;
  perform 1 from public.organizations where id = p_organization_id for update;
  if not public.organization_accepts_new_bookings(p_organization_id) then
    raise exception using errcode = '22023', message = 'organization is not accepting new bookings';
  end if;
  if v_sub.fixed_schedule_environment_id is null then
    v_schedule := public.fixed_subscription_schedule_preview(
      p_organization_id, v_plan.id, v_sub.fixed_schedule_barber_id,
      v_sub.fixed_schedule_start_date, v_sub.fixed_schedule_local_time,
      v_sub.fixed_schedule_cadence_weeks, v_sub.fixed_schedule_timezone
    );
  else
    v_schedule := public.fixed_subscription_schedule_preview(
      p_organization_id, v_plan.id, v_sub.fixed_schedule_barber_id,
      v_sub.fixed_schedule_start_date, v_sub.fixed_schedule_local_time,
      v_sub.fixed_schedule_cadence_weeks, v_sub.fixed_schedule_timezone,
      v_sub.fixed_schedule_environment_id
    );
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('type', 'SERVICE', 'service_id', service_id, 'quantity', 1) order by position), '[]'::jsonb)
    into v_items
    from public.subscription_plan_services
   where organization_id = p_organization_id and plan_version_id = v_plan.id;
  for v_session in
    select session.*
      from public.customer_subscription_sessions session
      join public.customer_subscription_cycles cycle
        on cycle.id = session.cycle_id and cycle.organization_id = session.organization_id
     where session.organization_id = p_organization_id
       and session.subscription_id = p_subscription_id
       and session.status = 'AVAILABLE'
     order by cycle.cycle_number, session.session_number
     for update of session
  loop
    begin
      v_appointment_id := public.create_manual_appointment(
        p_organization_id, v_sub.customer_id, v_sub.fixed_schedule_barber_id,
        (v_schedule -> (v_count) ->> 'starts_at')::timestamptz,
        v_items, null, 'Sessão de plano de assinatura', v_sub.fixed_schedule_environment_id
      );
    exception
      when exclusion_violation or check_violation then
        raise exception using errcode = '23P01', message = 'fixed_schedule_conflict: escolha outra data, horário, sala ou profissional';
      when invalid_parameter_value then
        raise exception using errcode = '23P01', message = 'fixed_schedule_conflict: escolha outra data, horário, sala ou profissional';
    end;
    update public.appointments
       set subscription_session_id = v_session.id,
           payment_mode = 'SUBSCRIPTION', total_cents_snapshot = 0,
           list_total_cents_snapshot = 0, deposit_required_cents_snapshot = 0,
           amount_waived_cents = 0, hold_expires_at = null,
           notes = concat_ws(E'\n', notes, 'Sessão assinatura')
     where id = v_appointment_id and organization_id = p_organization_id;
    update public.customer_subscription_sessions
       set status = 'SCHEDULED', appointment_id = v_appointment_id
     where id = v_session.id and organization_id = p_organization_id and status = 'AVAILABLE';
    if not found then
      raise exception using errcode = '40001', message = 'subscription session changed while scheduling';
    end if;
    v_count := v_count + 1;
  end loop;
  if v_count <> jsonb_array_length(v_schedule) then
    raise exception using errcode = '40001', message = 'fixed subscription session count changed';
  end if;
  update public.customer_subscriptions
     set fixed_schedule_created_at = now(), updated_at = now()
   where id = p_subscription_id and organization_id = p_organization_id;
  return v_count;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription or plan not found';
end;
$$;

revoke all on function public.schedule_fixed_subscription_sessions(uuid, uuid)
  from public, anon, authenticated;
