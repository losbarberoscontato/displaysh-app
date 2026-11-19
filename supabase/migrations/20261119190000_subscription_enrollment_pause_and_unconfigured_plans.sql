-- New subscription versions stay unconfigured until the replacement booking flow exists.
-- Existing plan versions keep their FREE/FIXED values and remain usable by current subscriptions.
alter table public.subscription_plan_versions
  drop constraint if exists subscription_plan_versions_scheduling_mode_check;

alter table public.subscription_plan_versions
  add constraint subscription_plan_versions_scheduling_mode_check
  check (scheduling_mode in ('FREE', 'FIXED', 'UNCONFIGURED'));

alter table public.subscription_plan_versions
  drop constraint if exists subscription_plan_versions_fixed_cadence_check;

alter table public.subscription_plan_versions
  add constraint subscription_plan_versions_fixed_cadence_check
  check (
    (scheduling_mode = 'FREE' and fixed_schedule_cadence_weeks is null)
    or (scheduling_mode = 'FIXED' and fixed_schedule_cadence_weeks is not null
        and fixed_schedule_cadence_weeks in (1, 2))
    or (scheduling_mode = 'UNCONFIGURED' and fixed_schedule_cadence_weeks is null)
  );

alter table public.subscription_plan_versions
  drop constraint if exists subscription_plan_versions_fixed_pattern_check;

alter table public.subscription_plan_versions
  add constraint subscription_plan_versions_fixed_pattern_check
  check (
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
    or (scheduling_mode = 'UNCONFIGURED' and fixed_schedule_pattern is null)
  );

create or replace function public.default_subscription_fixed_schedule_pattern()
returns trigger
language plpgsql
set search_path = pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    new.scheduling_mode := 'UNCONFIGURED';
    new.fixed_schedule_cadence_weeks := null;
    new.fixed_schedule_pattern := null;
  else
    -- Plan versions are immutable. Ignore legacy callers that try to change a version's mode.
    new.scheduling_mode := old.scheduling_mode;
    new.fixed_schedule_cadence_weeks := old.fixed_schedule_cadence_weeks;
    new.fixed_schedule_pattern := old.fixed_schedule_pattern;
  end if;
  return new;
end;
$$;

drop trigger if exists subscription_plan_versions_fixed_pattern_default
  on public.subscription_plan_versions;

create trigger subscription_plan_versions_fixed_pattern_default
  before insert or update of scheduling_mode, billing_period, sessions_per_cycle,
    fixed_schedule_cadence_weeks, fixed_schedule_pattern
  on public.subscription_plan_versions
  for each row execute function public.default_subscription_fixed_schedule_pattern();

revoke all on function public.default_subscription_fixed_schedule_pattern()
  from public, anon, authenticated, service_role;

create or replace function public.prevent_new_customer_subscription_enrollment()
returns trigger
language plpgsql
set search_path = pg_temp
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'subscription_enrollments_paused',
    detail = 'New subscription enrollments are temporarily paused.';
end;
$$;

revoke all on function public.prevent_new_customer_subscription_enrollment()
  from public, anon, authenticated, service_role;

drop trigger if exists customer_subscriptions_pause_new_enrollments
  on public.customer_subscriptions;

create trigger customer_subscriptions_pause_new_enrollments
  before insert on public.customer_subscriptions
  for each row execute function public.prevent_new_customer_subscription_enrollment();
