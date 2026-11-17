-- Fixed subscription patterns are versioned with the plan. Existing subscriptions
-- keep their already selected single-slot schedule and continue through the
-- legacy scheduling path.
alter table public.subscription_plan_versions
  add column fixed_schedule_pattern text;

update public.subscription_plan_versions version
   set fixed_schedule_pattern = case
     when version.scheduling_mode <> 'FIXED' then null
     when version.sessions_per_cycle = 1 then 'CYCLE_1'
     when version.sessions_per_cycle = 2 then 'CYCLE_2'
     when version.sessions_per_cycle = 4 then 'WEEKLY_1'
     when version.sessions_per_cycle = 8 then 'WEEKLY_2'
     when version.sessions_per_cycle = 12 then 'WEEKLY_3'
     when version.sessions_per_cycle = 20 then 'WEEKDAYS'
     when version.sessions_per_cycle = 24 then 'MON_SAT'
     else 'CYCLE_1'
   end;

alter table public.subscription_plan_versions
  add constraint subscription_plan_versions_fixed_pattern_check check (
    (scheduling_mode = 'FREE' and fixed_schedule_pattern is null)
    or (scheduling_mode = 'FIXED' and fixed_schedule_pattern is not null and (
      (fixed_schedule_pattern = 'CYCLE_1' and sessions_per_cycle = 1)
      or (fixed_schedule_pattern = 'CYCLE_2' and sessions_per_cycle = 2)
      or (billing_period = 'MONTHLY' and fixed_schedule_pattern = 'WEEKLY_1' and sessions_per_cycle = 4)
      or (billing_period = 'MONTHLY' and fixed_schedule_pattern = 'WEEKLY_2' and sessions_per_cycle = 8)
      or (billing_period = 'MONTHLY' and fixed_schedule_pattern = 'WEEKLY_3' and sessions_per_cycle = 12)
      or (billing_period = 'MONTHLY' and fixed_schedule_pattern = 'WEEKDAYS' and sessions_per_cycle = 20)
      or (billing_period = 'MONTHLY' and fixed_schedule_pattern = 'MON_SAT' and sessions_per_cycle = 24)
    ))
  );

create or replace function public.default_subscription_fixed_schedule_pattern()
returns trigger language plpgsql set search_path = pg_temp as $$
begin
  if new.scheduling_mode = 'FREE' then
    new.fixed_schedule_pattern := null;
  elsif new.fixed_schedule_pattern is null then
    new.fixed_schedule_pattern := case
      when new.sessions_per_cycle = 1 then 'CYCLE_1'
      when new.sessions_per_cycle = 2 then 'CYCLE_2'
      when new.billing_period = 'MONTHLY' and new.sessions_per_cycle = 4 then 'WEEKLY_1'
      when new.billing_period = 'MONTHLY' and new.sessions_per_cycle = 8 then 'WEEKLY_2'
      when new.billing_period = 'MONTHLY' and new.sessions_per_cycle = 12 then 'WEEKLY_3'
      when new.billing_period = 'MONTHLY' and new.sessions_per_cycle = 20 then 'WEEKDAYS'
      when new.billing_period = 'MONTHLY' and new.sessions_per_cycle = 24 then 'MON_SAT'
      else null
    end;
  end if;
  return new;
end;
$$;

create trigger subscription_plan_versions_fixed_pattern_default
  before insert or update of scheduling_mode, billing_period, sessions_per_cycle, fixed_schedule_pattern
  on public.subscription_plan_versions
  for each row execute function public.default_subscription_fixed_schedule_pattern();

revoke all on function public.default_subscription_fixed_schedule_pattern() from public, anon, authenticated, service_role;

alter table public.customer_subscriptions
  add column fixed_schedule_slots jsonb check (
    fixed_schedule_slots is null
    or jsonb_typeof(fixed_schedule_slots) = 'array'
  );

alter table public.customer_subscription_cycles
  add column planned_session_count smallint not null default 0 check (planned_session_count >= 0);

alter table public.customer_subscription_sessions
  add column cycle_amount_share_cents bigint check (cycle_amount_share_cents >= 0);

update public.customer_subscription_cycles cycle
   set planned_session_count = counts.session_count
  from (
    select session.cycle_id, count(*)::smallint session_count
      from public.customer_subscription_sessions session
     group by session.cycle_id
  ) counts
 where counts.cycle_id = cycle.id;

create or replace function public.save_subscription_plan(
  p_organization_id uuid,
  p_plan_id uuid,
  p_name text,
  p_description text,
  p_price_cents bigint,
  p_billing_period public.subscription_billing_period,
  p_duration_months smallint,
  p_sessions_per_cycle smallint,
  p_payment_method public.subscription_payment_method,
  p_cancellation_policy text,
  p_session_cancellation_policy text,
  p_services jsonb,
  p_scheduling_mode text,
  p_fixed_schedule_cadence_weeks smallint,
  p_fixed_schedule_pattern text
)
returns public.subscription_plans
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_plan public.subscription_plans;
  v_version_id uuid;
begin
  if (p_scheduling_mode = 'FREE' and p_fixed_schedule_pattern is not null)
     or (p_scheduling_mode = 'FIXED' and p_fixed_schedule_pattern is null) then
    raise exception using errcode = '22023', message = 'invalid subscription plan fixed pattern';
  end if;
  v_plan := public.save_subscription_plan(
    p_organization_id, p_plan_id, p_name, p_description, p_price_cents,
    p_billing_period, p_duration_months, p_sessions_per_cycle, p_payment_method,
    p_cancellation_policy, p_session_cancellation_policy, p_services,
    p_scheduling_mode, p_fixed_schedule_cadence_weeks
  );
  select version.id into strict v_version_id
    from public.subscription_plan_versions version
   where version.organization_id = p_organization_id and version.plan_id = v_plan.id
   order by version.version desc limit 1;
  update public.subscription_plan_versions
     set fixed_schedule_pattern = p_fixed_schedule_pattern
   where id = v_version_id and organization_id = p_organization_id;
  return v_plan;
end;
$$;

revoke all on function public.save_subscription_plan(
  uuid, uuid, text, text, bigint, public.subscription_billing_period,
  smallint, smallint, public.subscription_payment_method, text, text, jsonb, text, smallint, text
) from public, anon;
grant execute on function public.save_subscription_plan(
  uuid, uuid, text, text, bigint, public.subscription_billing_period,
  smallint, smallint, public.subscription_payment_method, text, text, jsonb, text, smallint, text
) to authenticated;

create or replace function public.fixed_subscription_pattern_occurrences_for_cycle(
  p_pattern text,
  p_cycle_start date,
  p_cycle_end date,
  p_slots jsonb
)
returns jsonb
language plpgsql immutable set search_path = pg_temp as $$
declare
  v_date date;
  v_slot jsonb;
  v_result jsonb := '[]'::jsonb;
  v_weekday integer;
  v_offset integer;
begin
  if p_pattern in ('CYCLE_1', 'CYCLE_2') then
    for v_slot in select value from jsonb_array_elements(p_slots)
    loop
      v_offset := (v_slot ->> 'day_offset')::integer;
      v_date := least(p_cycle_start + v_offset, p_cycle_end);
      v_result := v_result || jsonb_build_array(jsonb_build_object(
        'local_date', v_date,
        'local_time', v_slot ->> 'local_time',
        'environment_id', v_slot ->> 'environment_id'
      ));
    end loop;
  else
    for v_date in select d::date from generate_series(p_cycle_start, p_cycle_end, interval '1 day') d
    loop
      v_weekday := extract(dow from v_date)::integer;
      for v_slot in select value from jsonb_array_elements(p_slots)
      loop
        if (v_slot ->> 'weekday')::integer = v_weekday then
          v_result := v_result || jsonb_build_array(jsonb_build_object(
            'local_date', v_date,
            'local_time', v_slot ->> 'local_time',
            'environment_id', v_slot ->> 'environment_id'
          ));
        end if;
      end loop;
    end loop;
  end if;
  select coalesce(jsonb_agg(value order by value ->> 'local_date', value ->> 'local_time'), '[]'::jsonb)
    into v_result from jsonb_array_elements(v_result);
  return v_result;
end;
$$;

create or replace function public.fixed_subscription_pattern_schedule_preview(
  p_organization_id uuid,
  p_plan_version_id uuid,
  p_barber_id uuid,
  p_start_date date,
  p_slots jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_plan public.subscription_plan_versions%rowtype;
  v_org public.organizations%rowtype;
  v_barber public.barbers%rowtype;
  v_items jsonb;
  v_resolution jsonb;
  v_duration integer;
  v_occupied integer;
  v_cycles integer;
  v_cycle_start date;
  v_cycle_end date;
  v_occurrences jsonb;
  v_occurrence jsonb;
  v_local_date date;
  v_local_time time;
  v_environment_id uuid;
  v_start timestamptz;
  v_period tstzrange;
  v_result jsonb := '[]'::jsonb;
  v_schedulable jsonb := '[]'::jsonb;
  i integer;
begin
  if p_start_date is null or jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then
    raise exception using errcode = '22023', message = 'invalid fixed subscription schedule';
  end if;
  select * into strict v_org from public.organizations where id = p_organization_id;
  select * into strict v_plan from public.subscription_plan_versions
   where id = p_plan_version_id and organization_id = p_organization_id;
  if v_plan.scheduling_mode <> 'FIXED' or v_plan.fixed_schedule_pattern is null then
    raise exception using errcode = '22023', message = 'subscription plan does not use fixed pattern scheduling';
  end if;
  if v_plan.billing_period = 'BIWEEKLY'
     and v_plan.fixed_schedule_pattern not in ('CYCLE_1', 'CYCLE_2') then
    raise exception using errcode = '22023', message = 'fixed schedule pattern requires monthly billing';
  end if;
  if jsonb_array_length(p_slots) <> (case v_plan.fixed_schedule_pattern
    when 'CYCLE_1' then 1 when 'CYCLE_2' then 2
    when 'WEEKLY_1' then 1 when 'WEEKLY_2' then 2 when 'WEEKLY_3' then 3
    when 'WEEKDAYS' then 5 when 'MON_SAT' then 6 else 0 end) then
    raise exception using errcode = '22023', message = 'fixed schedule pattern has an invalid number of slots';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_slots) item
     where nullif(item ->> 'local_time', '') is null
        or (item ->> 'local_time')::time is null
        or nullif(item ->> 'environment_id', '') is null
        or (v_plan.fixed_schedule_pattern in ('CYCLE_1', 'CYCLE_2')
            and ((item ->> 'day_offset')::integer < 0
              or (item ->> 'day_offset')::integer > case when v_plan.billing_period = 'BIWEEKLY' then 14 else 30 end))
        or (v_plan.fixed_schedule_pattern not in ('CYCLE_1', 'CYCLE_2')
            and coalesce((item ->> 'weekday')::integer, -1) not between 0 and 6)
  ) then
    raise exception using errcode = '22023', message = 'fixed schedule slot is invalid';
  end if;
  if v_plan.fixed_schedule_pattern in ('WEEKDAYS', 'MON_SAT') and exists (
    select 1 from jsonb_array_elements(p_slots) item
     where (item ->> 'weekday')::integer < 1
        or (item ->> 'weekday')::integer > case when v_plan.fixed_schedule_pattern = 'WEEKDAYS' then 5 else 6 end
  ) then
    raise exception using errcode = '22023', message = 'weekday pattern contains an invalid weekday';
  end if;
  if v_plan.fixed_schedule_pattern not in ('CYCLE_1', 'CYCLE_2') and (
    select count(distinct (item ->> 'weekday')::integer) from jsonb_array_elements(p_slots) item
  ) <> jsonb_array_length(p_slots) then
    raise exception using errcode = '22023', message = 'fixed schedule cannot repeat a weekday';
  end if;
  if v_plan.fixed_schedule_pattern in ('CYCLE_1', 'CYCLE_2') and (
    select count(distinct (item ->> 'day_offset')::integer) from jsonb_array_elements(p_slots) item
  ) <> jsonb_array_length(p_slots) then
    raise exception using errcode = '22023', message = 'fixed schedule cannot repeat a cycle date';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_slots) item
    left join public.agenda_environments environment
      on environment.id = (item ->> 'environment_id')::uuid
     and environment.organization_id = p_organization_id and environment.active
    where environment.id is null
  ) then
    raise exception using errcode = '22023', message = 'fixed schedule environment is inactive';
  end if;
  select * into strict v_barber from public.barbers
   where id = p_barber_id and organization_id = p_organization_id and active;
  select coalesce(jsonb_agg(jsonb_build_object('type', 'SERVICE', 'service_id', service_id, 'quantity', 1) order by position), '[]'::jsonb)
    into v_items from public.subscription_plan_services
   where organization_id = p_organization_id and plan_version_id = v_plan.id;
  if jsonb_array_length(v_items) = 0 then
    raise exception using errcode = '22023', message = 'fixed subscription plan has no services';
  end if;
  v_resolution := public.resolve_booking_selection(p_organization_id, p_barber_id, v_items, null);
  v_duration := (v_resolution ->> 'duration_minutes')::integer;
  v_occupied := ceil(v_duration::numeric / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes;
  v_cycles := case when v_plan.billing_period = 'BIWEEKLY' then v_plan.duration_months * 2 else v_plan.duration_months end;
  for i in 1..v_cycles loop
    v_cycle_start := case when v_plan.billing_period = 'BIWEEKLY'
      then p_start_date + ((i - 1) * 15)
      else (p_start_date + ((i - 1) || ' months')::interval)::date end;
    v_cycle_end := case when v_plan.billing_period = 'BIWEEKLY'
      then v_cycle_start + 14 else (v_cycle_start + interval '1 month' - interval '1 day')::date end;
    v_occurrences := public.fixed_subscription_pattern_occurrences_for_cycle(
      v_plan.fixed_schedule_pattern, v_cycle_start, v_cycle_end, p_slots
    );
    for v_occurrence in select value from jsonb_array_elements(v_occurrences)
    loop
      v_local_date := (v_occurrence ->> 'local_date')::date;
      v_local_time := (v_occurrence ->> 'local_time')::time;
      v_environment_id := (v_occurrence ->> 'environment_id')::uuid;
      v_start := (v_local_date + v_local_time) at time zone v_org.timezone;
      v_period := tstzrange(v_start, v_start + make_interval(mins => v_occupied), '[)');
      if v_start <= now() or public.organization_date_blocked(p_organization_id, v_period) then
        v_result := v_result || jsonb_build_array(v_occurrence || jsonb_build_object('bookable', false));
        continue;
      end if;
      if not public.is_barber_available(p_organization_id, p_barber_id, v_period)
         or public.resolve_appointment_environment(
           p_organization_id, p_barber_id, v_barber.location_id, v_period, v_environment_id
         ) is null then
        raise exception using errcode = '23P01', message = 'fixed_schedule_conflict: escolha outra data, horário, sala ou profissional';
      end if;
      if exists (
        select 1 from jsonb_array_elements(v_schedulable) previous
         where (previous ->> 'local_date')::date = v_local_date
           and tstzrange(
             ((previous ->> 'local_date')::date + (previous ->> 'local_time')::time) at time zone v_org.timezone,
             (((previous ->> 'local_date')::date + (previous ->> 'local_time')::time) at time zone v_org.timezone) + make_interval(mins => v_occupied), '[)'
           ) && v_period
      ) then
        raise exception using errcode = '23P01', message = 'fixed_schedule_conflict: sessões da mesma série se sobrepõem';
      end if;
      v_schedulable := v_schedulable || jsonb_build_array(v_occurrence);
      v_result := v_result || jsonb_build_array(v_occurrence || jsonb_build_object('bookable', true));
    end loop;
  end loop;
  return jsonb_build_object('occurrences', v_result, 'bookable_count', jsonb_array_length(v_schedulable));
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization, plan, barber or environment not found';
end;
$$;

revoke all on function public.fixed_subscription_pattern_schedule_preview(uuid, uuid, uuid, date, jsonb)
  from public, anon, authenticated, service_role;

create or replace function public.request_customer_fixed_subscription_pattern(
  p_organization_id uuid,
  p_customer_id uuid,
  p_plan_id uuid,
  p_start_date date,
  p_barber_id uuid,
  p_slots jsonb,
  p_acceptance_source text default 'CLIENT',
  p_accept_contract boolean default true
)
returns public.customer_subscriptions
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_plan public.subscription_plan_versions%rowtype;
  v_sub public.customer_subscriptions%rowtype;
  v_timezone text;
  v_first_slot jsonb;
begin
  select * into strict v_plan from public.subscription_plan_versions
   where organization_id = p_organization_id and plan_id = p_plan_id
   order by version desc limit 1;
  if v_plan.scheduling_mode <> 'FIXED' or v_plan.fixed_schedule_pattern is null then
    raise exception using errcode = '22023', message = 'subscription plan does not use fixed pattern scheduling';
  end if;
  perform public.fixed_subscription_pattern_schedule_preview(
    p_organization_id, v_plan.id, p_barber_id, p_start_date, p_slots
  );
  v_sub := public.request_customer_subscription(
    p_organization_id, p_customer_id, p_plan_id, p_acceptance_source, p_accept_contract
  );
  select value into strict v_first_slot from jsonb_array_elements(p_slots) order by
    coalesce(value ->> 'day_offset', value ->> 'weekday'), value ->> 'local_time' limit 1;
  select timezone into strict v_timezone from public.organizations where id = p_organization_id;
  update public.customer_subscriptions
     set fixed_schedule_cadence_weeks = 1,
         fixed_schedule_start_date = p_start_date,
         fixed_schedule_local_time = (v_first_slot ->> 'local_time')::time,
         fixed_schedule_barber_id = p_barber_id,
         fixed_schedule_environment_id = (v_first_slot ->> 'environment_id')::uuid,
         fixed_schedule_timezone = v_timezone,
         fixed_schedule_slots = p_slots,
         updated_at = now()
   where id = v_sub.id and organization_id = p_organization_id
  returning * into v_sub;
  return v_sub;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization, subscription plan or barber not found';
end;
$$;

revoke all on function public.request_customer_fixed_subscription_pattern(uuid, uuid, uuid, date, uuid, jsonb, text, boolean)
  from public, anon;
grant execute on function public.request_customer_fixed_subscription_pattern(uuid, uuid, uuid, date, uuid, jsonb, text, boolean)
  to authenticated;

alter function public.schedule_fixed_subscription_sessions(uuid, uuid)
  rename to schedule_fixed_subscription_sessions_legacy;

create or replace function public.schedule_fixed_subscription_sessions(
  p_organization_id uuid,
  p_subscription_id uuid
)
returns integer
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_plan public.subscription_plan_versions%rowtype;
  v_cycle public.customer_subscription_cycles%rowtype;
  v_session public.customer_subscription_sessions%rowtype;
  v_occurrences jsonb;
  v_occurrence jsonb;
  v_slots jsonb;
  v_items jsonb;
  v_org public.organizations%rowtype;
  v_barber public.barbers%rowtype;
  v_resolution jsonb;
  v_occupied integer;
  v_start timestamptz;
  v_period tstzrange;
  v_appointment_id uuid;
  v_actual_count integer;
  v_index integer;
  v_session_count integer := 0;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription schedule generation denied';
  end if;
  select * into strict v_sub from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id for update;
  select * into strict v_plan from public.subscription_plan_versions
   where id = v_sub.plan_version_id and organization_id = p_organization_id;
  if v_plan.scheduling_mode <> 'FIXED' then return 0; end if;
  if v_sub.fixed_schedule_slots is null then
    return public.schedule_fixed_subscription_sessions_legacy(p_organization_id, p_subscription_id);
  end if;
  if v_sub.status <> 'ACTIVE' or v_sub.fixed_schedule_created_at is not null then return 0; end if;
  perform 1 from public.organizations where id = p_organization_id for update;
  if not public.organization_accepts_new_bookings(p_organization_id) then
    raise exception using errcode = '22023', message = 'organization is not accepting new bookings';
  end if;
  select * into strict v_org from public.organizations where id = p_organization_id;
  select * into strict v_barber from public.barbers
   where id = v_sub.fixed_schedule_barber_id and organization_id = p_organization_id and active;
  select coalesce(jsonb_agg(jsonb_build_object('type', 'SERVICE', 'service_id', service_id, 'quantity', 1) order by position), '[]'::jsonb)
    into v_items from public.subscription_plan_services
   where organization_id = p_organization_id and plan_version_id = v_plan.id;
  v_resolution := public.resolve_booking_selection(p_organization_id, v_sub.fixed_schedule_barber_id, v_items, null);
  v_occupied := ceil((v_resolution ->> 'duration_minutes')::numeric / v_org.slot_interval_minutes)::integer * v_org.slot_interval_minutes;
  v_slots := v_sub.fixed_schedule_slots;
  for v_cycle in
    select cycle.* from public.customer_subscription_cycles cycle
     where cycle.organization_id = p_organization_id and cycle.subscription_id = p_subscription_id
     order by cycle.cycle_number for update
  loop
    v_occurrences := public.fixed_subscription_pattern_occurrences_for_cycle(
      v_plan.fixed_schedule_pattern, v_cycle.starts_on, v_cycle.ends_on, v_slots
    );
    v_actual_count := jsonb_array_length(v_occurrences);
    if v_actual_count = 0 then
      raise exception using errcode = '22023', message = 'fixed schedule produced no sessions in a billing cycle';
    end if;
    if v_actual_count > (select count(*) from public.customer_subscription_sessions session
      where session.organization_id = p_organization_id and session.cycle_id = v_cycle.id) then
      insert into public.customer_subscription_sessions(organization_id, subscription_id, cycle_id, session_number, available_until)
      select p_organization_id, p_subscription_id, v_cycle.id, numbers.session_number, v_cycle.ends_on
        from generate_series(
          (select coalesce(max(session.session_number), 0) + 1 from public.customer_subscription_sessions session
            where session.organization_id = p_organization_id and session.cycle_id = v_cycle.id),
          v_actual_count
        ) numbers(session_number);
    elsif v_actual_count < (select count(*) from public.customer_subscription_sessions session
      where session.organization_id = p_organization_id and session.cycle_id = v_cycle.id) then
      update public.customer_subscription_sessions
         set status = 'CANCELED', canceled_at = now(), cycle_amount_share_cents = null
       where organization_id = p_organization_id and cycle_id = v_cycle.id
         and session_number > v_actual_count and status = 'AVAILABLE' and appointment_id is null;
    end if;
    update public.customer_subscription_cycles cycle
       set planned_session_count = v_actual_count
     where cycle.id = v_cycle.id and cycle.organization_id = p_organization_id;
    update public.customer_subscription_sessions session
       set cycle_amount_share_cents = case
         when session.session_number = v_actual_count
           then v_cycle.amount_cents - (v_cycle.amount_cents / v_actual_count) * (v_actual_count - 1)
         else v_cycle.amount_cents / v_actual_count
       end
     where session.organization_id = p_organization_id and session.cycle_id = v_cycle.id
       and session.session_number <= v_actual_count and session.status <> 'CANCELED';
    v_index := 0;
    for v_occurrence in select value from jsonb_array_elements(v_occurrences)
    loop
      v_index := v_index + 1;
      select * into strict v_session from public.customer_subscription_sessions session
       where session.organization_id = p_organization_id and session.cycle_id = v_cycle.id
         and session.session_number = v_index for update;
      v_start := (((v_occurrence ->> 'local_date')::date + (v_occurrence ->> 'local_time')::time) at time zone v_org.timezone);
      v_period := tstzrange(v_start, v_start + make_interval(mins => v_occupied), '[)');
      if v_start <= now() or public.organization_date_blocked(p_organization_id, v_period) then
        continue;
      end if;
      begin
        v_appointment_id := public.create_manual_appointment(
          p_organization_id, v_sub.customer_id, v_sub.fixed_schedule_barber_id,
          v_start, v_items, null, 'Sessão de plano de assinatura',
          (v_occurrence ->> 'environment_id')::uuid
        );
      exception
        when exclusion_violation or check_violation or invalid_parameter_value then
          raise exception using errcode = '23P01', message = 'fixed_schedule_conflict: escolha outra data, horário, sala ou profissional';
      end;
      update public.appointments appointment
         set subscription_session_id = v_session.id,
             payment_mode = 'SUBSCRIPTION', total_cents_snapshot = 0,
             list_total_cents_snapshot = 0, deposit_required_cents_snapshot = 0,
             amount_waived_cents = 0, hold_expires_at = null,
             notes = concat_ws(E'\n', appointment.notes, 'Sessão assinatura')
       where appointment.id = v_appointment_id and appointment.organization_id = p_organization_id;
      update public.customer_subscription_sessions session
         set status = 'SCHEDULED', appointment_id = v_appointment_id
       where session.id = v_session.id and session.organization_id = p_organization_id and session.status = 'AVAILABLE';
      if not found then
        raise exception using errcode = '40001', message = 'subscription session changed while scheduling';
      end if;
      v_session_count := v_session_count + 1;
    end loop;
  end loop;
  update public.customer_subscriptions
     set fixed_schedule_created_at = now(), updated_at = now()
   where id = p_subscription_id and organization_id = p_organization_id;
  return v_session_count;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription, plan, barber or cycle not found';
end;
$$;

revoke all on function public.schedule_fixed_subscription_sessions(uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function public.ensure_subscription_session_commission(p_session_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_session public.customer_subscription_sessions%rowtype;
  v_cycle public.customer_subscription_cycles%rowtype;
  v_plan public.subscription_plan_versions%rowtype;
  v_appointment public.appointments%rowtype;
  v_base_cents bigint;
  v_commission bigint;
begin
  select * into v_session from public.customer_subscription_sessions where id=p_session_id for update;
  if v_session.id is null or v_session.status<>'COMPLETED' or v_session.appointment_id is null
     or v_session.commission_mode_snapshot is null then return; end if;
  select * into strict v_cycle from public.customer_subscription_cycles
   where id=v_session.cycle_id and organization_id=v_session.organization_id;
  if v_cycle.status<>'PAID' then return; end if;
  select * into strict v_appointment from public.appointments
   where id=v_session.appointment_id and organization_id=v_session.organization_id;
  if v_appointment.status<>'COMPLETED' then return; end if;
  select version.* into strict v_plan from public.customer_subscriptions subscription
  join public.subscription_plan_versions version on version.id=subscription.plan_version_id and version.organization_id=subscription.organization_id
  where subscription.id=v_session.subscription_id and subscription.organization_id=v_session.organization_id;
  v_base_cents := coalesce(v_session.cycle_amount_share_cents,
    case when v_session.session_number=v_plan.sessions_per_cycle
      then v_cycle.amount_cents-(v_cycle.amount_cents/v_plan.sessions_per_cycle)*(v_plan.sessions_per_cycle-1)
      else v_cycle.amount_cents/v_plan.sessions_per_cycle end);
  v_commission := case v_session.commission_mode_snapshot
    when 'PERCENT' then round(v_base_cents::numeric*v_session.commission_percentage_bps_snapshot/10000)::bigint
    when 'FIXED' then v_session.commission_fixed_cents_snapshot
    else 0 end;
  if v_commission<=0 then return; end if;
  insert into public.commission_ledger(organization_id,barber_id,appointment_id,subscription_session_id,kind,amount_cents,idempotency_key,earned_at,created_by)
  values(v_session.organization_id,v_appointment.barber_id,v_appointment.id,v_session.id,'EARNED',v_commission,
    'subscription-session-earned:'||v_session.id,now(),auth.uid()) on conflict (organization_id,idempotency_key) do nothing;
exception when no_data_found then return;
end $$;
revoke all on function public.ensure_subscription_session_commission(uuid) from public,anon,authenticated,service_role;

create or replace view public.commission_service_details with (security_invoker=true) as
select appointment_detail.organization_id,appointment_detail.appointment_id,appointment_detail.appointment_item_id,
  appointment_detail.customer_id,appointment_detail.customer_name,appointment_detail.barber_id,
  appointment_detail.service_id,appointment_detail.service_name,appointment_detail.location_id,appointment_detail.service_date,
  appointment_detail.service_value_paid_cents,appointment_detail.financial_account_names,appointment_detail.commission_cents,
  appointment_detail.paid_commission_cents,appointment_detail.payable_commission_cents,appointment_detail.received_on,
  appointment_detail.project_session_id,appointment_detail.project_engagement_id,appointment_detail.project_id,
  appointment_detail.is_project,'APPOINTMENT'::text source_type,null::uuid internal_service_id
from public.commission_service_appointment_details appointment_detail
union all
select internal_service.organization_id,null::uuid,null::uuid,null::uuid,null::text,internal_service.barber_id,
  internal_service.service_id,internal_service.service_name,null::uuid,internal_service.delivery_on,
  0::bigint,null::text,coalesce(ledger_totals.commission_cents,0)::bigint,
  coalesce(paid_totals.paid_commission_cents,0)::bigint,
  greatest(coalesce(ledger_totals.commission_cents,0)-coalesce(paid_totals.paid_commission_cents,0),0)::bigint,
  null::date,null::uuid,internal_service.engagement_id,internal_service.project_id,true,
  'PROJECT_INTERNAL'::text,internal_service.id
from public.project_engagement_internal_services internal_service
left join lateral (select sum(ledger.amount_cents)::bigint commission_cents from public.commission_ledger ledger
  where ledger.organization_id=internal_service.organization_id and ledger.project_internal_service_id=internal_service.id) ledger_totals on true
left join lateral (select greatest(sum(settlement.amount_cents-coalesce(reversals.amount_cents,0)),0)::bigint paid_commission_cents
  from public.commission_payout_items payout_item join public.commission_payout_settlements settlement
    on settlement.organization_id=payout_item.organization_id and settlement.payout_id=payout_item.payout_id
  left join (select organization_id,settlement_id,sum(amount_cents)::bigint amount_cents from public.commission_payout_settlement_reversals group by organization_id,settlement_id) reversals
    on reversals.organization_id=settlement.organization_id and reversals.settlement_id=settlement.id
  join public.commission_ledger ledger on ledger.organization_id=payout_item.organization_id and ledger.id=payout_item.ledger_entry_id
  where payout_item.organization_id=internal_service.organization_id and ledger.project_internal_service_id=internal_service.id) paid_totals on true
where internal_service.status='COMPLETED'
union all
select session.organization_id,appointment.id,null::uuid,appointment.customer_id,customer.full_name,appointment.barber_id,
  item.service_id,'Sessão de assinatura · '||plan.name,appointment.location_id,
  coalesce(completed.service_date,(lower(appointment.service_period) at time zone organization.timezone)::date),
  coalesce(session.cycle_amount_share_cents,
    case when session.session_number=version.sessions_per_cycle
      then cycle.amount_cents-(cycle.amount_cents/version.sessions_per_cycle)*(version.sessions_per_cycle-1)
      else cycle.amount_cents/version.sessions_per_cycle end),'Fatura de assinatura recebida'::text,
  coalesce(ledger_totals.commission_cents,0)::bigint,coalesce(paid_totals.paid_commission_cents,0)::bigint,
  greatest(coalesce(ledger_totals.commission_cents,0)-coalesce(paid_totals.paid_commission_cents,0),0)::bigint,
  (cycle.paid_at at time zone organization.timezone)::date,null::uuid,null::uuid,null::uuid,false,
  'SUBSCRIPTION_SESSION'::text,session.id
from public.customer_subscription_sessions session
join public.customer_subscription_cycles cycle on cycle.id=session.cycle_id and cycle.organization_id=session.organization_id
join public.customer_subscriptions subscription on subscription.id=session.subscription_id and subscription.organization_id=session.organization_id
join public.subscription_plans plan on plan.id=subscription.plan_id and plan.organization_id=subscription.organization_id
join public.subscription_plan_versions version on version.id=subscription.plan_version_id and version.organization_id=subscription.organization_id
join public.appointments appointment on appointment.id=session.appointment_id and appointment.organization_id=session.organization_id
join public.customers customer on customer.id=appointment.customer_id and customer.organization_id=appointment.organization_id
join lateral (select appointment_item.service_id from public.appointment_items appointment_item
  where appointment_item.organization_id=appointment.organization_id and appointment_item.appointment_id=appointment.id
  order by appointment_item.position limit 1) item on true
join public.organizations organization on organization.id=session.organization_id
left join lateral (select min((event.created_at at time zone organization.timezone)::date) service_date
  from public.appointment_status_events event where event.organization_id=appointment.organization_id
    and event.appointment_id=appointment.id and event.to_status='COMPLETED') completed on true
left join lateral (select sum(ledger.amount_cents)::bigint commission_cents from public.commission_ledger ledger
  where ledger.organization_id=session.organization_id and ledger.subscription_session_id=session.id) ledger_totals on true
left join lateral (select greatest(sum(settlement.amount_cents-coalesce(reversals.amount_cents,0)),0)::bigint paid_commission_cents
  from public.commission_payout_items payout_item join public.commission_payout_settlements settlement
    on settlement.organization_id=payout_item.organization_id and settlement.payout_id=payout_item.payout_id
  left join (select organization_id,settlement_id,sum(amount_cents)::bigint amount_cents from public.commission_payout_settlement_reversals group by organization_id,settlement_id) reversals
    on reversals.organization_id=settlement.organization_id and reversals.settlement_id=settlement.id
  join public.commission_ledger ledger on ledger.organization_id=payout_item.organization_id and ledger.id=payout_item.ledger_entry_id
  where payout_item.organization_id=session.organization_id and ledger.subscription_session_id=session.id) paid_totals on true
where session.status='COMPLETED' and appointment.status='COMPLETED' and cycle.status='PAID'
  and coalesce(ledger_totals.commission_cents,0)>0;
grant select on public.commission_service_details to authenticated;

create or replace function public.get_fixed_subscription_schedule_slot_options(
  p_organization_id uuid,
  p_customer_id uuid,
  p_plan_version_id uuid,
  p_barber_id uuid,
  p_local_date date,
  p_local_time time
)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_org public.organizations%rowtype;
  v_barber public.barbers%rowtype;
  v_plan public.subscription_plan_versions%rowtype;
  v_items jsonb;
  v_resolution jsonb;
  v_minutes integer;
  v_period tstzrange;
  v_result jsonb;
begin
  if not (public.is_organization_owner(p_organization_id)
    or public.is_organization_customer(p_organization_id, p_customer_id)) then
    raise exception using errcode = '42501', message = 'fixed subscription schedule options denied';
  end if;
  if not public.organization_module_enabled(p_organization_id, 'subscription_plans') then
    raise exception using errcode = '42501', message = 'subscription module disabled';
  end if;
  select * into strict v_org from public.organizations where id = p_organization_id;
  select * into strict v_plan from public.subscription_plan_versions
   where id = p_plan_version_id and organization_id = p_organization_id and scheduling_mode = 'FIXED';
  select * into strict v_barber from public.barbers
   where id = p_barber_id and organization_id = p_organization_id and active;
  select coalesce(jsonb_agg(jsonb_build_object('type', 'SERVICE', 'service_id', service_id, 'quantity', 1) order by position), '[]'::jsonb)
    into v_items from public.subscription_plan_services
   where organization_id = p_organization_id and plan_version_id = p_plan_version_id;
  if jsonb_array_length(v_items) = 0 then
    raise exception using errcode = '22023', message = 'fixed subscription plan has no services';
  end if;
  v_resolution := public.resolve_booking_selection(p_organization_id, p_barber_id, v_items, null);
  v_minutes := ceil((v_resolution ->> 'duration_minutes')::numeric / v_org.slot_interval_minutes)::integer
    * v_org.slot_interval_minutes;
  v_period := tstzrange(
    (p_local_date + p_local_time) at time zone v_org.timezone,
    ((p_local_date + p_local_time) at time zone v_org.timezone) + make_interval(mins => v_minutes), '[)'
  );
  if not public.is_barber_available(p_organization_id, p_barber_id, v_period)
     or public.organization_date_blocked(p_organization_id, v_period) then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', environment.id, 'name', environment.name) order by environment.sort_order, environment.name), '[]'::jsonb)
    into v_result
    from public.agenda_environments environment
   where environment.organization_id = p_organization_id
     and environment.location_id = v_barber.location_id
     and environment.active
     and public.resolve_appointment_environment(
       p_organization_id, p_barber_id, v_barber.location_id, v_period, environment.id
     ) is not null;
  return v_result;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'organization, plan, barber or customer not found';
end;
$$;

revoke all on function public.get_fixed_subscription_schedule_slot_options(uuid, uuid, uuid, uuid, date, time)
  from public, anon;
grant execute on function public.get_fixed_subscription_schedule_slot_options(uuid, uuid, uuid, uuid, date, time)
  to authenticated;
