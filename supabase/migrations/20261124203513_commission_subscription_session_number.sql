-- Expose the session index for both legacy and bundle subscription commissions.
-- Keep the existing commission rows and RLS behavior unchanged.

create or replace view public.commission_service_details
with (security_invoker = true) as
select existing_details.*,
  legacy_session.session_number::integer as subscription_session_number
from public.commission_service_details_before_bundle_v2 existing_details
left join public.customer_subscription_sessions legacy_session
  on existing_details.source_type = 'SUBSCRIPTION_SESSION'
  and legacy_session.id = existing_details.internal_service_id
  and legacy_session.organization_id = existing_details.organization_id

union all

select session.organization_id,
  appointment.id,
  null::uuid,
  appointment.customer_id,
  customer.full_name,
  appointment.barber_id,
  contract.service_id,
  'Sessão do plano · ' || plan.name,
  appointment.location_id,
  (lower(appointment.service_period) at time zone organization.timezone)::date,
  contract.price_per_session_cents,
  'Recebimento do plano'::text,
  coalesce(ledger_totals.commission_cents, 0)::bigint,
  coalesce(paid_totals.paid_commission_cents, 0)::bigint,
  greatest(coalesce(ledger_totals.commission_cents, 0) - coalesce(paid_totals.paid_commission_cents, 0), 0)::bigint,
  (installment.paid_at at time zone organization.timezone)::date,
  null::uuid,
  null::uuid,
  null::uuid,
  false,
  'SUBSCRIPTION_BUNDLE_SESSION'::text,
  session.id,
  session.session_number::integer
from public.subscription_bundle_sessions session
join public.customer_subscriptions subscription
  on subscription.id = session.subscription_id and subscription.organization_id = session.organization_id
join public.subscription_plans plan
  on plan.id = subscription.plan_id and plan.organization_id = subscription.organization_id
join public.subscription_bundle_contracts contract
  on contract.subscription_id = session.subscription_id and contract.organization_id = session.organization_id
join public.subscription_bundle_installments installment
  on installment.subscription_id = session.subscription_id
  and installment.organization_id = session.organization_id
  and installment.installment_number = session.installment_number
join public.appointments appointment
  on appointment.id = session.appointment_id and appointment.organization_id = session.organization_id
join public.customers customer
  on customer.id = appointment.customer_id and customer.organization_id = appointment.organization_id
join public.organizations organization on organization.id = session.organization_id
left join lateral (
  select sum(ledger.amount_cents)::bigint as commission_cents
  from public.commission_ledger ledger
  where ledger.organization_id = session.organization_id
    and ledger.subscription_bundle_session_id = session.id
) ledger_totals on true
left join lateral (
  select greatest(sum(settlement.amount_cents - coalesce(reversals.amount_cents, 0)), 0)::bigint as paid_commission_cents
  from public.commission_payout_items payout_item
  join public.commission_payout_settlements settlement
    on settlement.organization_id = payout_item.organization_id and settlement.payout_id = payout_item.payout_id
  left join (
    select organization_id, settlement_id, sum(amount_cents)::bigint as amount_cents
    from public.commission_payout_settlement_reversals
    group by organization_id, settlement_id
  ) reversals
    on reversals.organization_id = settlement.organization_id and reversals.settlement_id = settlement.id
  join public.commission_ledger ledger
    on ledger.organization_id = payout_item.organization_id and ledger.id = payout_item.ledger_entry_id
  where payout_item.organization_id = session.organization_id
    and ledger.subscription_bundle_session_id = session.id
) paid_totals on true
where session.status = 'COMPLETED'
  and appointment.status = 'COMPLETED'
  and installment.status = 'PAID'
  and coalesce(ledger_totals.commission_cents, 0) > 0;

grant select on public.commission_service_details to authenticated;
