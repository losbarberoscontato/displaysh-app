alter table public.subscription_bundle_contracts
  alter column entry_due_on drop not null;

alter table public.subscription_bundle_contracts
  add constraint subscription_bundle_contracts_entry_due_requires_amount_check
  check (entry_cents = 0 or entry_due_on is not null) not valid;

alter table public.subscription_bundle_contracts
  validate constraint subscription_bundle_contracts_entry_due_requires_amount_check;

create or replace function public.create_subscription_bundle_offer(
  p_organization_id uuid,
  p_customer_id uuid,
  p_plan_id uuid,
  p_first_session_date date,
  p_entry_due_on date,
  p_first_installment_due_on date,
  p_fixed_slots jsonb,
  p_idempotency_key text
)
returns public.customer_subscriptions
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_slots jsonb;
  v_financial jsonb;
  v_existing_subscription_id uuid;
  v_sub public.customer_subscriptions%rowtype;
  v_contract public.subscription_bundle_contracts%rowtype;
  v_helper_entry_due_on date;
  v_total_sessions smallint;
  v_price_per_session_cents bigint;
  v_total_price_numeric numeric;
  v_total_price_cents bigint;
  v_entry_cents bigint;
  v_installment_count smallint;
  v_discount_type text;
  v_discount_value bigint;
  v_payment_method_text text;
  v_payment_method public.subscription_payment_method;
  v_min_installment bigint;
  v_discount_cents bigint;
begin
  v_helper_entry_due_on := p_entry_due_on;

  if jsonb_typeof(p_fixed_slots) = 'object' then
    if not (p_fixed_slots ? 'slots') then
      raise exception using errcode = '22023', message = 'subscription offer payload is invalid';
    end if;
    v_slots := p_fixed_slots->'slots';
    v_financial := p_fixed_slots->'financial';
    if jsonb_typeof(v_financial) is distinct from 'object' then
      raise exception using errcode = '22023', message = 'subscription financial terms are invalid';
    end if;
  else
    -- Existing callers that pass only the schedule continue to use plan defaults.
    v_slots := p_fixed_slots;
  end if;

  if char_length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 200 then
    raise exception using errcode = '22023', message = 'subscription idempotency key is invalid';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || btrim(p_idempotency_key), 0));

  if v_financial is not null then
    if v_financial->>'total_sessions' is null
       or v_financial->>'price_per_session_cents' is null
       or v_financial->>'entry_cents' is null
       or v_financial->>'installment_count' is null
       or v_financial->>'discount_type' is null
       or v_financial->>'discount_value' is null
       or v_financial->>'payment_method' is null then
      raise exception using errcode = '22023', message = 'subscription financial terms are incomplete';
    end if;

    v_total_sessions := (v_financial->>'total_sessions')::smallint;
    v_price_per_session_cents := (v_financial->>'price_per_session_cents')::bigint;
    v_entry_cents := (v_financial->>'entry_cents')::bigint;
    v_installment_count := (v_financial->>'installment_count')::smallint;
    v_discount_type := upper(v_financial->>'discount_type');
    v_discount_value := (v_financial->>'discount_value')::bigint;
    v_payment_method_text := upper(v_financial->>'payment_method');

    if v_total_sessions not between 1 and 300
       or v_price_per_session_cents <= 0
       or v_entry_cents < 0
       or v_installment_count not between 1 and 24
       or v_discount_type not in ('NONE', 'FIXED', 'PERCENT')
       or v_discount_value < 0
       or v_payment_method_text not in ('ONLINE', 'CARD', 'PIX', 'BOLETO', 'CASH', 'CRYPTO') then
      raise exception using errcode = '22023', message = 'subscription financial terms are invalid';
    end if;

    v_total_price_numeric := v_price_per_session_cents::numeric * v_total_sessions;
    if v_total_price_numeric > 9223372036854775807 then
      raise exception using errcode = '22003', message = 'subscription total exceeds the supported amount';
    end if;
    v_total_price_cents := v_total_price_numeric::bigint;
    v_min_installment := floor(v_total_price_cents::numeric / v_installment_count)::bigint;
    if v_min_installment < 1
       or (v_discount_type = 'NONE' and v_discount_value <> 0)
       or (v_discount_type = 'FIXED' and (v_discount_value <= 0 or v_discount_value >= v_min_installment))
       or (v_discount_type = 'PERCENT' and v_discount_value not between 1 and 9999) then
      raise exception using errcode = '22023', message = 'subscription discount or installment amount is invalid';
    end if;
    v_discount_cents := case v_discount_type
      when 'FIXED' then v_discount_value
      when 'PERCENT' then round(v_min_installment::numeric * v_discount_value / 10000)::bigint
      else 0
    end;
    if v_discount_cents >= v_min_installment then
      raise exception using errcode = '22023', message = 'installment discount results in a zero or negative amount';
    end if;
    if v_entry_cents = 0 then
      -- The legacy helper requires an entry date; use the first installment date internally,
      -- then persist NULL because no entry is charged.
      v_helper_entry_due_on := p_first_installment_due_on;
    elsif p_entry_due_on is null then
      raise exception using errcode = '22023', message = 'entry due date is required when an entry is charged';
    end if;
    v_payment_method := v_payment_method_text::public.subscription_payment_method;
  end if;

  select contract.subscription_id into v_existing_subscription_id
    from public.subscription_bundle_contracts contract
   where contract.organization_id = p_organization_id
     and contract.idempotency_key = btrim(p_idempotency_key)
   for update;

  v_sub := public.create_subscription_bundle_offer_with_plan_defaults(
    p_organization_id,
    p_customer_id,
    p_plan_id,
    p_first_session_date,
    v_helper_entry_due_on,
    p_first_installment_due_on,
    v_slots,
    p_idempotency_key
  );

  if v_financial is null then
    return v_sub;
  end if;

  if v_existing_subscription_id is not null then
    select * into strict v_contract
      from public.subscription_bundle_contracts contract
     where contract.organization_id = p_organization_id
       and contract.subscription_id = v_existing_subscription_id
     for update;
    if v_contract.total_sessions = v_total_sessions
       and v_contract.price_per_session_cents = v_price_per_session_cents
       and v_contract.total_price_cents = v_total_price_cents
       and v_contract.entry_cents = v_entry_cents
       and v_contract.installment_count = v_installment_count
       and v_contract.discount_type = v_discount_type
       and v_contract.discount_value = v_discount_value
       and v_sub.payment_method = v_payment_method then
      return v_sub;
    end if;
    raise exception using errcode = '23505', message = 'subscription idempotency key was already used with different financial terms';
  end if;

  update public.subscription_bundle_contracts
     set entry_due_on = case when v_entry_cents > 0 then p_entry_due_on else null end,
         total_sessions = v_total_sessions,
         price_per_session_cents = v_price_per_session_cents,
         total_price_cents = v_total_price_cents,
         entry_cents = v_entry_cents,
         installment_count = v_installment_count,
         discount_type = v_discount_type,
         discount_value = v_discount_value
   where organization_id = p_organization_id
     and subscription_id = v_sub.id
     and accepted_at is null
   returning * into strict v_contract;

  update public.customer_subscriptions
     set payment_method = v_payment_method
   where id = v_sub.id and organization_id = p_organization_id
   returning * into strict v_sub;
  return v_sub;
end;
$$;

revoke all on function public.create_subscription_bundle_offer(uuid, uuid, uuid, date, date, date, jsonb, text)
  from public, anon;
grant execute on function public.create_subscription_bundle_offer(uuid, uuid, uuid, date, date, date, jsonb, text)
  to authenticated;
