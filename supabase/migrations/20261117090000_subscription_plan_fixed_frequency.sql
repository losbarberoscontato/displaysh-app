alter table public.subscription_plan_versions
  add column fixed_schedule_cadence_weeks smallint;

update public.subscription_plan_versions
   set fixed_schedule_cadence_weeks = case
     when scheduling_mode = 'FIXED' then 1
     else null
   end;

alter table public.subscription_plan_versions
  add constraint subscription_plan_versions_fixed_cadence_check
  check (
    (scheduling_mode = 'FREE' and fixed_schedule_cadence_weeks is null)
    or (scheduling_mode = 'FIXED' and fixed_schedule_cadence_weeks is not null
        and fixed_schedule_cadence_weeks in (1, 2))
  );

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
  p_scheduling_mode text
)
returns public.subscription_plans
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_plan public.subscription_plans;
begin
  if p_scheduling_mode not in ('FREE', 'FIXED') then
    raise exception using errcode = '22023', message = 'invalid subscription scheduling mode';
  end if;
  v_plan := public.save_subscription_plan(
    p_organization_id, p_plan_id, p_name, p_description, p_price_cents,
    p_billing_period, p_duration_months, p_sessions_per_cycle, p_payment_method,
    p_cancellation_policy, p_session_cancellation_policy, p_services
  );
  update public.subscription_plan_versions
     set scheduling_mode = p_scheduling_mode,
         fixed_schedule_cadence_weeks = case
           when p_scheduling_mode = 'FIXED'
             then coalesce(fixed_schedule_cadence_weeks, 1)
           else null
         end
   where id = (
     select version.id from public.subscription_plan_versions version
      where version.organization_id = p_organization_id and version.plan_id = v_plan.id
      order by version.version desc limit 1
   );
  return v_plan;
end;
$$;

revoke all on function public.save_subscription_plan(
  uuid, uuid, text, text, bigint, public.subscription_billing_period,
  smallint, smallint, public.subscription_payment_method, text, text, jsonb, text
) from public, anon;
grant execute on function public.save_subscription_plan(
  uuid, uuid, text, text, bigint, public.subscription_billing_period,
  smallint, smallint, public.subscription_payment_method, text, text, jsonb, text
) to authenticated;

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
  p_fixed_schedule_cadence_weeks smallint
)
returns public.subscription_plans
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_plan public.subscription_plans;
begin
  if p_scheduling_mode not in ('FREE', 'FIXED') then
    raise exception using errcode = '22023', message = 'invalid subscription scheduling mode';
  end if;
  if (p_scheduling_mode = 'FIXED' and (p_fixed_schedule_cadence_weeks is null or p_fixed_schedule_cadence_weeks not in (1, 2)))
    or (p_scheduling_mode = 'FREE' and p_fixed_schedule_cadence_weeks is not null) then
    raise exception using errcode = '22023', message = 'invalid subscription plan fixed frequency';
  end if;
  v_plan := public.save_subscription_plan(
    p_organization_id, p_plan_id, p_name, p_description, p_price_cents,
    p_billing_period, p_duration_months, p_sessions_per_cycle, p_payment_method,
    p_cancellation_policy, p_session_cancellation_policy, p_services, p_scheduling_mode
  );
  update public.subscription_plan_versions
     set fixed_schedule_cadence_weeks = p_fixed_schedule_cadence_weeks
   where id = (
     select version.id from public.subscription_plan_versions version
      where version.organization_id = p_organization_id and version.plan_id = v_plan.id
      order by version.version desc limit 1
   );
  return v_plan;
end;
$$;

revoke all on function public.save_subscription_plan(
  uuid, uuid, text, text, bigint, public.subscription_billing_period,
  smallint, smallint, public.subscription_payment_method, text, text, jsonb, text, smallint
) from public, anon;
grant execute on function public.save_subscription_plan(
  uuid, uuid, text, text, bigint, public.subscription_billing_period,
  smallint, smallint, public.subscription_payment_method, text, text, jsonb, text, smallint
) to authenticated;

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
  select * into strict v_plan from public.subscription_plan_versions
   where plan_id = p_plan_id and organization_id = p_organization_id
   order by version desc limit 1;
  if v_plan.scheduling_mode <> 'FIXED' or v_plan.fixed_schedule_cadence_weeks not in (1, 2) then
    raise exception using errcode = '22023', message = 'subscription plan fixed frequency is missing';
  end if;
  select timezone into strict v_timezone from public.organizations where id = p_organization_id;
  v_sub := public.request_customer_fixed_subscription(
    p_organization_id, p_customer_id, p_plan_id, v_plan.fixed_schedule_cadence_weeks,
    p_start_date, p_local_time, p_barber_id, p_acceptance_source, p_accept_contract
  );
  perform public.fixed_subscription_schedule_preview(
    p_organization_id, v_plan.id, p_barber_id, p_start_date,
    p_local_time, v_plan.fixed_schedule_cadence_weeks, v_timezone, p_environment_id
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
  p_barber_id uuid
)
returns public.customer_subscriptions
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_plan public.subscription_plan_versions%rowtype;
  v_timezone text;
  v_cadence_weeks smallint;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription schedule update denied';
  end if;
  select * into strict v_sub from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id for update;
  if v_sub.status not in ('REQUESTED', 'PENDING_PAYMENT') or v_sub.fixed_schedule_created_at is not null then
    raise exception using errcode = '22023', message = 'fixed subscription schedule is no longer editable';
  end if;
  select * into strict v_plan from public.subscription_plan_versions
   where id = v_sub.plan_version_id and organization_id = p_organization_id;
  v_cadence_weeks := coalesce(v_sub.fixed_schedule_cadence_weeks, v_plan.fixed_schedule_cadence_weeks, p_cadence_weeks);
  if v_cadence_weeks not in (1, 2) then
    raise exception using errcode = '22023', message = 'fixed subscription schedule frequency is missing';
  end if;
  select timezone into strict v_timezone from public.organizations where id = p_organization_id;
  perform public.fixed_subscription_schedule_preview(
    p_organization_id, v_plan.id, p_barber_id, p_start_date, p_local_time,
    v_cadence_weeks, v_timezone
  );
  update public.customer_subscriptions
     set fixed_schedule_cadence_weeks = v_cadence_weeks,
         fixed_schedule_start_date = p_start_date,
         fixed_schedule_local_time = p_local_time,
         fixed_schedule_barber_id = p_barber_id,
         fixed_schedule_timezone = v_timezone,
         updated_at = now()
   where id = v_sub.id and organization_id = p_organization_id
  returning * into v_sub;
  return v_sub;
exception
  when no_data_found then
    raise exception using errcode = 'P0002', message = 'subscription, plan or barber not found';
end;
$$;

revoke all on function public.update_customer_fixed_subscription_schedule(uuid, uuid, smallint, date, time, uuid)
  from public, anon;
grant execute on function public.update_customer_fixed_subscription_schedule(uuid, uuid, smallint, date, time, uuid)
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
    p_local_time, v_sub.fixed_schedule_cadence_weeks, v_sub.fixed_schedule_timezone, p_environment_id
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
