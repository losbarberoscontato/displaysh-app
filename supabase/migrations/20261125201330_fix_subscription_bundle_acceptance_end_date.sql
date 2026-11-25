create or replace function public.accept_customer_subscription_offer(
  p_organization_id uuid, p_subscription_id uuid
)
returns public.customer_subscriptions
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_sub public.customer_subscriptions%rowtype;
  v_version public.subscription_plan_versions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_today date;
  v_was_provisional boolean;
begin
  select * into strict v_sub from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id for update;
  if not public.is_organization_customer(p_organization_id, v_sub.customer_id) then
    raise exception using errcode = '42501', message = 'subscription offer acceptance denied';
  end if;
  select * into strict v_version from public.subscription_plan_versions
   where id = v_sub.plan_version_id and organization_id = p_organization_id;
  if v_version.model <> 'SESSION_BUNDLE_V1' then
    return public.accept_customer_subscription_offer_before_bundle_control(p_organization_id, p_subscription_id);
  end if;
  if v_sub.status = 'ACTIVE' and v_sub.contract_accepted_at is not null then
    perform public.provision_subscription_bundle_contract(p_organization_id, v_sub.id, auth.uid());
    select * into strict v_sub from public.customer_subscriptions
     where id = p_subscription_id and organization_id = p_organization_id;
    return v_sub;
  end if;
  v_was_provisional := v_sub.status = 'ACTIVE'
    and v_sub.manager_activated_provisionally_at is not null
    and v_sub.contract_accepted_at is null;
  if not v_was_provisional and (v_sub.status <> 'REQUESTED' or v_sub.contract_accepted_at is not null) then
    raise exception using errcode = '22023', message = 'subscription bundle offer is not awaiting acceptance';
  end if;
  if not public.organization_module_enabled(p_organization_id, 'subscription_plans') then
    raise exception using errcode = '42501', message = 'subscription module disabled';
  end if;
  select * into strict v_contract from public.subscription_bundle_contracts
   where subscription_id = v_sub.id and organization_id = p_organization_id for update;
  select (now() at time zone organization.timezone)::date into strict v_today
    from public.organizations organization where organization.id = p_organization_id;
  if not v_was_provisional and (v_contract.first_session_date < v_today or v_contract.first_installment_due_on < v_today
     or (v_contract.entry_cents > 0 and v_contract.entry_due_on < v_today)) then
    raise exception using errcode = '22023', message = 'subscription offer dates have expired; ask the manager to update the offer';
  end if;
  perform set_config('app.subscription_bundle_accept', '1', true);
  update public.customer_subscriptions set status = 'ACTIVE', contract_accepted_at = now(),
    contract_accepted_by = auth.uid(), start_date = v_contract.first_session_date,
    end_date = v_contract.first_session_date,
    first_due_date = v_contract.first_installment_due_on,
    due_day = extract(day from v_contract.first_installment_due_on)::smallint, updated_at = now()
   where id = v_sub.id and organization_id = p_organization_id returning * into v_sub;
  update public.subscription_bundle_contracts set accepted_at = now()
   where id = v_contract.id and organization_id = p_organization_id;
  insert into public.subscription_contract_acceptances(
    organization_id, subscription_id, contract_version, accepted_by, acceptance_source, metadata
  ) values (p_organization_id, v_sub.id, v_sub.contract_version, auth.uid(), 'CLIENT',
    jsonb_build_object('model', 'SESSION_BUNDLE_V1', 'accepted_at', now()))
  on conflict (subscription_id, contract_version) do nothing;
  update public.customer_in_app_notifications set read_at = coalesce(read_at, now())
   where organization_id = p_organization_id and customer_id = v_sub.customer_id
     and subscription_id = v_sub.id;
  perform public.provision_subscription_bundle_contract(p_organization_id, v_sub.id, auth.uid());
  select * into strict v_sub from public.customer_subscriptions
   where id = p_subscription_id and organization_id = p_organization_id;
  insert into public.subscription_events(
    organization_id, subscription_id, event_type, actor_user_id, idempotency_key, metadata
  ) values (p_organization_id, v_sub.id, 'BUNDLE_ACCEPTED', auth.uid(),
    'bundle-accepted:' || v_sub.id,
    jsonb_build_object('model', 'SESSION_BUNDLE_V1', 'after_provisional_activation', v_was_provisional))
  on conflict (organization_id, idempotency_key) do nothing;
  return v_sub;
exception when no_data_found then
  raise exception using errcode = 'P0002', message = 'subscription bundle offer not found';
end;
$$;

revoke all on function public.accept_customer_subscription_offer(uuid, uuid) from public, anon;
grant execute on function public.accept_customer_subscription_offer(uuid, uuid) to authenticated;
