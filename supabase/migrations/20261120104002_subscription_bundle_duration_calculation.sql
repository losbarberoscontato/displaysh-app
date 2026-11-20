-- Store bundle plan duration in the existing version column and derive the
-- number of sessions from four weeks per contract month.
create or replace function public.save_subscription_bundle_plan(
  p_organization_id uuid,
  p_plan_id uuid,
  p_name text,
  p_description text,
  p_service_id uuid,
  p_scheduling_mode text,
  p_sessions_per_week smallint,
  p_session_duration_minutes smallint,
  p_total_sessions smallint,
  p_price_per_session_cents bigint,
  p_entry_cents bigint,
  p_payment_method text,
  p_installment_count smallint,
  p_discount_type text,
  p_discount_value bigint
)
returns public.subscription_plans
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_plan public.subscription_plans%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_version_number integer;
  v_total bigint;
  v_min_installment bigint;
  v_contract_duration_months smallint;
  v_payment_method public.subscription_payment_method;
  v_service public.services%rowtype;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription plan denied';
  end if;
  if not public.organization_module_enabled(p_organization_id, 'subscription_plans') then
    raise exception using errcode = '42501', message = 'subscription module disabled';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 120
     or p_scheduling_mode not in ('FREE', 'FIXED')
     or p_sessions_per_week is null or p_sessions_per_week not between 1 and 21
     or p_session_duration_minutes not between 5 and 180
     or p_total_sessions is null or p_total_sessions not between 1 and 300
     or p_price_per_session_cents <= 0
     or p_entry_cents < 0
     or p_installment_count not between 1 and 24
     or p_discount_type not in ('NONE', 'FIXED', 'PERCENT')
     or p_discount_value < 0 then
    raise exception using errcode = '22023', message = 'invalid subscription bundle plan';
  end if;
  if p_total_sessions % (p_sessions_per_week * 4) <> 0 then
    raise exception using errcode = '22023', message = 'total sessions must match weekly sessions and contract duration';
  end if;
  v_contract_duration_months := (p_total_sessions / (p_sessions_per_week * 4))::smallint;
  if v_contract_duration_months not between 1 and 24 then
    raise exception using errcode = '22023', message = 'subscription bundle contract duration must be between 1 and 24 months';
  end if;
  if p_discount_type = 'NONE' and p_discount_value <> 0
     or p_discount_type = 'PERCENT' and p_discount_value not between 1 and 9999
     or p_discount_type = 'FIXED' and p_discount_value <= 0 then
    raise exception using errcode = '22023', message = 'invalid subscription bundle discount';
  end if;
  v_total := p_price_per_session_cents * p_total_sessions;
  v_min_installment := floor(v_total::numeric / p_installment_count)::bigint;
  if v_min_installment < 1 then
    raise exception using errcode = '22023', message = 'subscription total must cover every installment';
  end if;
  if p_discount_type = 'FIXED' and p_discount_value >= v_min_installment then
    raise exception using errcode = '22023', message = 'installment discount exceeds installment value';
  end if;
  if p_discount_type = 'PERCENT'
     and round(v_min_installment::numeric * p_discount_value / 10000)::bigint >= v_min_installment then
    raise exception using errcode = '22023', message = 'installment discount results in a zero or negative amount';
  end if;
  if upper(p_payment_method) not in ('ONLINE', 'CARD', 'PIX', 'BOLETO', 'CASH', 'CRYPTO') then
    raise exception using errcode = '22023', message = 'invalid subscription bundle payment method';
  end if;
  v_payment_method := upper(p_payment_method)::public.subscription_payment_method;
  select * into strict v_service from public.services
   where id = p_service_id and organization_id = p_organization_id and active and accepts_subscription;

  if p_plan_id is null then
    insert into public.subscription_plans(organization_id, name, description, created_by)
    values (p_organization_id, btrim(p_name), nullif(btrim(p_description), ''), auth.uid())
    returning * into v_plan;
    v_version_number := 1;
  else
    select * into strict v_plan from public.subscription_plans
     where id = p_plan_id and organization_id = p_organization_id and archived_at is null
     for update;
    update public.subscription_plans set name = btrim(p_name),
      description = nullif(btrim(p_description), ''), updated_at = now()
     where id = v_plan.id returning * into v_plan;
    select coalesce(max(version), 0) + 1 into v_version_number
      from public.subscription_plan_versions where plan_id = v_plan.id;
  end if;

  insert into public.subscription_plan_versions(
    organization_id, plan_id, version, price_cents, billing_period, duration_months,
    sessions_per_cycle, cancellation_policy, session_cancellation_policy,
    contract_version, payment_method, model, bundle_scheduling_mode,
    bundle_service_id, bundle_sessions_per_week, bundle_session_duration_minutes,
    bundle_total_sessions, bundle_price_per_session_cents, bundle_entry_cents,
    bundle_installment_count, bundle_discount_type, bundle_discount_value, created_by
  ) values (
    p_organization_id, v_plan.id, v_version_number, v_total, 'MONTHLY', v_contract_duration_months, 1,
    'Plano contratado por sessões.', 'Cancelamento de sessões conforme disponibilidade do plano.',
    'v1', v_payment_method, 'SESSION_BUNDLE_V1', p_scheduling_mode,
    v_service.id, p_sessions_per_week, p_session_duration_minutes, p_total_sessions,
    p_price_per_session_cents, p_entry_cents, p_installment_count,
    p_discount_type, p_discount_value, auth.uid()
  ) returning * into v_version;

  insert into public.subscription_plan_services(
    organization_id, plan_version_id, service_id, position, service_name_snapshot,
    list_price_cents_snapshot, duration_minutes_snapshot
  ) values (
    p_organization_id, v_version.id, v_service.id, 0, v_service.name,
    v_service.price_cents, p_session_duration_minutes
  );
  return v_plan;
end;
$$;
revoke all on function public.save_subscription_bundle_plan(uuid,uuid,text,text,uuid,text,smallint,smallint,smallint,bigint,bigint,text,smallint,text,bigint)
  from public, anon;
grant execute on function public.save_subscription_bundle_plan(uuid,uuid,text,text,uuid,text,smallint,smallint,smallint,bigint,bigint,text,smallint,text,bigint)
  to authenticated;
