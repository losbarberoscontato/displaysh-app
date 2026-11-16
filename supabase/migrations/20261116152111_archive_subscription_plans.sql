alter table public.subscription_plans
  add column archived_at timestamptz,
  add column archived_by uuid references auth.users(id) on delete set null;

drop index public.subscription_plans_name_active;
create unique index subscription_plans_name_active
  on public.subscription_plans(organization_id, lower(name))
  where active and archived_at is null;

create or replace function public.archive_subscription_plan(
  p_organization_id uuid,
  p_plan_id uuid
)
returns public.subscription_plans
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.subscription_plans;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription plan denied';
  end if;

  select * into v_plan
    from public.subscription_plans
   where id = p_plan_id and organization_id = p_organization_id
   for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'subscription plan not found';
  end if;

  if v_plan.archived_at is null then
    update public.subscription_plans
       set archived_at = now(), archived_by = auth.uid(), updated_at = now()
     where id = p_plan_id and organization_id = p_organization_id
     returning * into v_plan;
  end if;

  return v_plan;
end;
$$;

revoke all on function public.archive_subscription_plan(uuid, uuid) from public, anon;
grant execute on function public.archive_subscription_plan(uuid, uuid) to authenticated;

create or replace function public.prevent_archived_subscription_plan_enrollment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_archived_at timestamptz;
begin
  select p.archived_at into v_archived_at
    from public.subscription_plans p
   where p.id = new.plan_id
     and p.organization_id = new.organization_id
   for share;

  if v_archived_at is not null then
    raise exception using errcode = '22023', message = 'subscription plan is archived';
  end if;

  return new;
end;
$$;

revoke all on function public.prevent_archived_subscription_plan_enrollment() from public, anon, authenticated;

create trigger customer_subscriptions_reject_archived_plan_insert
before insert on public.customer_subscriptions
for each row execute function public.prevent_archived_subscription_plan_enrollment();

create trigger customer_subscriptions_reject_archived_plan_change
before update of organization_id, plan_id on public.customer_subscriptions
for each row execute function public.prevent_archived_subscription_plan_enrollment();

drop policy subscription_plans_customer_select on public.subscription_plans;
create policy subscription_plans_customer_select on public.subscription_plans
  for select to authenticated using (
    active
    and public.organization_module_enabled(organization_id, 'subscription_plans')
    and exists (
      select 1 from public.customers c
       where c.organization_id = public.subscription_plans.organization_id
         and c.auth_user_id = (select auth.uid())
         and c.active
         and c.merged_into_customer_id is null
    )
    and (
      archived_at is null
      or exists (
        select 1 from public.customer_subscriptions s
         where s.organization_id = public.subscription_plans.organization_id
           and s.plan_id = public.subscription_plans.id
           and public.is_organization_customer(s.organization_id, s.customer_id)
      )
    )
  );

drop policy subscription_plan_versions_customer_select on public.subscription_plan_versions;
create policy subscription_plan_versions_customer_select on public.subscription_plan_versions
  for select to authenticated using (
    exists (
      select 1 from public.subscription_plans p
       where p.id = public.subscription_plan_versions.plan_id
         and p.organization_id = public.subscription_plan_versions.organization_id
         and p.active
         and public.organization_module_enabled(p.organization_id, 'subscription_plans')
         and (
           p.archived_at is null
           or exists (
             select 1 from public.customer_subscriptions s
              where s.organization_id = p.organization_id
                and s.plan_id = p.id
                and public.is_organization_customer(s.organization_id, s.customer_id)
           )
         )
    )
    and exists (
      select 1 from public.customers c
       where c.organization_id = public.subscription_plan_versions.organization_id
         and c.auth_user_id = (select auth.uid())
         and c.active
         and c.merged_into_customer_id is null
    )
  );

drop policy subscription_plan_services_customer_select on public.subscription_plan_services;
create policy subscription_plan_services_customer_select on public.subscription_plan_services
  for select to authenticated using (
    exists (
      select 1
        from public.subscription_plan_versions v
        join public.subscription_plans p
          on p.id = v.plan_id and p.organization_id = v.organization_id
       where v.id = public.subscription_plan_services.plan_version_id
         and v.organization_id = public.subscription_plan_services.organization_id
         and p.active
         and public.organization_module_enabled(p.organization_id, 'subscription_plans')
         and (
           p.archived_at is null
           or exists (
             select 1 from public.customer_subscriptions s
              where s.organization_id = p.organization_id
                and s.plan_id = p.id
                and public.is_organization_customer(s.organization_id, s.customer_id)
           )
         )
    )
    and exists (
      select 1 from public.customers c
       where c.organization_id = public.subscription_plan_services.organization_id
         and c.auth_user_id = (select auth.uid())
         and c.active
         and c.merged_into_customer_id is null
    )
  );
