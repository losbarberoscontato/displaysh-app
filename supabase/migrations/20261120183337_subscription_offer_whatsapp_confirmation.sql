-- Create a subscription offer and, only when explicitly requested by its owner,
-- enqueue the existing "Mensagens de contratos" WhatsApp template atomically.
create or replace function public.create_subscription_bundle_offer_with_notice(
  p_organization_id uuid,
  p_customer_id uuid,
  p_plan_id uuid,
  p_first_session_date date,
  p_entry_due_on date,
  p_first_installment_due_on date,
  p_fixed_slots jsonb,
  p_idempotency_key text,
  p_send_whatsapp_notice boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_subscription public.customer_subscriptions%rowtype;
  v_notice_job_id uuid;
  v_notice_queued boolean := false;
  v_notice_dedupe_key text;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception using errcode = '42501', message = 'subscription offer denied';
  end if;

  v_subscription := public.create_subscription_bundle_offer(
    p_organization_id,
    p_customer_id,
    p_plan_id,
    p_first_session_date,
    p_entry_due_on,
    p_first_installment_due_on,
    p_fixed_slots,
    p_idempotency_key
  );

  if p_send_whatsapp_notice then
    perform public.whatsapp_enqueue_manager_plan_created_notice(
      p_organization_id,
      p_customer_id,
      v_subscription.id,
      'PROJECT_CONTRACT_CREATED_CLIENT'
    );

    v_notice_dedupe_key := 'manager-plan-created:PROJECT_CONTRACT_CREATED_CLIENT:' || v_subscription.id::text;
    update public.whatsapp_automation_jobs job
       set payload = coalesce(job.payload, '{}'::jsonb)
         || jsonb_build_object('explicit_subscription_offer_notice', true),
           updated_at = now()
     where job.organization_id = p_organization_id
       and job.dedupe_key = v_notice_dedupe_key
    returning job.id into v_notice_job_id;
    v_notice_queued := v_notice_job_id is not null;

    if not v_notice_queued then
      raise exception using errcode = '55000', message = 'Não foi possível colocar o aviso na fila do WhatsApp. Verifique o consentimento do cliente, o telefone, a conexão ativa e a mensagem de contratos, ou escolha apenas criar o plano.';
    end if;
  end if;

  return jsonb_build_object(
    'subscription_id', v_subscription.id,
    'whatsapp_notice_queued', v_notice_queued
  );
end;
$$;

revoke all on function public.create_subscription_bundle_offer_with_notice(uuid, uuid, uuid, date, date, date, jsonb, text, boolean)
  from public, anon, service_role;
grant execute on function public.create_subscription_bundle_offer_with_notice(uuid, uuid, uuid, date, date, date, jsonb, text, boolean)
  to authenticated;

-- The subscription runtime pause remains in place for automatic notices and
-- session traffic. Only the manager-confirmed contract-template job may pass
-- validation while the WhatsApp V2 dispatcher is active.
create or replace function public.whatsapp_v2_validate_plan_notice_dispatch(
  p_job_id uuid,
  p_worker_id text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_job public.whatsapp_automation_jobs%rowtype;
  v_customer public.customers%rowtype;
  v_reason text;
  v_customer_app_url text;
begin
  perform public.require_service_role();
  select * into v_job from public.whatsapp_automation_jobs where id = p_job_id for update;
  if not found or v_job.status <> 'PROCESSING' or v_job.locked_by is distinct from p_worker_id
    or v_job.lock_expires_at <= now() then
    raise exception 'STALE_LEASE';
  end if;
  if v_job.job_type <> 'MANUAL_OUTBOUND_TEXT'
    or coalesce((v_job.payload ->> 'transactional_plan_notice')::boolean, false) is not true
    or v_job.payload ->> 'message_kind' not in ('PROJECT_CONTRACT_CREATED_CLIENT', 'SUBSCRIPTION_CREATED_CLIENT') then
    raise exception 'INVALID_PLAN_NOTICE_JOB';
  end if;

  select 'https://displaysh-app.vercel.app/b/' || coalesce(o.booking_public_id::text, o.slug)
    into v_customer_app_url
  from public.organizations o
  where o.id = v_job.organization_id;
  if v_customer_app_url is null then
    v_reason := 'ORGANIZATION_UNAVAILABLE';
  end if;

  if not exists (
    select 1
    from public.whatsapp_automation_settings_v2 s
    join public.whatsapp_business_connections w
      on w.id = v_job.connection_id and w.organization_id = s.organization_id
    where s.organization_id = v_job.organization_id
      and s.mode = 'ACTIVE' and not s.dispatch_paused
      and (s.runtime_engine <> 'ACTIVE' or (
        v_job.payload ->> 'message_kind' = 'PROJECT_CONTRACT_CREATED_CLIENT'
        and coalesce((v_job.payload ->> 'explicit_subscription_offer_notice')::boolean, false)
      ))
      and w.provider = 'QR_WEB' and w.is_active and w.status = 'CONNECTED'
  ) then
    v_reason := coalesce(v_reason, 'CONNECTION_OR_AUTOMATION_PAUSED');
  end if;

  select * into v_customer from public.customers
  where id = v_job.customer_id and organization_id = v_job.organization_id for share;
  if v_customer.id is null or not v_customer.active
    or not public.whatsapp_v2_consented(v_job.organization_id, v_job.customer_id) then
    v_reason := coalesce(v_reason, 'TRANSACTIONAL_REVOKED');
  elsif v_customer.phone_e164 is distinct from v_job.recipient_e164 then
    v_reason := coalesce(v_reason, 'RECIPIENT_CHANGED');
  end if;

  if v_reason is not null then
    update public.whatsapp_automation_jobs
    set status = 'SKIPPED', last_error_code = v_reason, locked_by = null,
        lock_expires_at = null, updated_at = now()
    where id = v_job.id;
    return false;
  end if;

  update public.whatsapp_automation_jobs
  set payload = coalesce(payload, '{}'::jsonb) || jsonb_build_object('customer_app_url', v_customer_app_url),
      updated_at = now()
  where id = v_job.id;
  return true;
end;
$$;

revoke all on function public.whatsapp_v2_validate_plan_notice_dispatch(uuid, text)
  from public, anon, authenticated;
grant execute on function public.whatsapp_v2_validate_plan_notice_dispatch(uuid, text)
  to service_role;
