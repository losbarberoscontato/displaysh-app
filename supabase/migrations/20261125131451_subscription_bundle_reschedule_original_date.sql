-- Recover the original date from the append-only reschedule history. The
-- appointment sync trigger updates scheduled_for before the manager RPC writes
-- the session row, so reading scheduled_for in that later UPDATE can capture
-- the new date instead of the original one.
with first_reschedule as (
  select distinct on (
    event.organization_id,
    event.metadata ->> 'subscription_bundle_session_id'
  )
    event.organization_id,
    (event.metadata ->> 'subscription_bundle_session_id')::uuid as session_id,
    nullif(event.metadata ->> 'previous_starts_at', '')::timestamptz as original_starts_at
  from public.appointment_status_events event
  where event.reason = 'subscription_bundle_session_rescheduled'
    and nullif(event.metadata ->> 'subscription_bundle_session_id', '') is not null
    and nullif(event.metadata ->> 'previous_starts_at', '') is not null
  order by
    event.organization_id,
    event.metadata ->> 'subscription_bundle_session_id',
    event.created_at,
    event.id
)
update public.subscription_bundle_sessions session
   set rescheduled_from = first_reschedule.original_starts_at
  from first_reschedule
 where session.organization_id = first_reschedule.organization_id
   and session.id = first_reschedule.session_id
   and session.rescheduled_from is distinct from first_reschedule.original_starts_at;

create or replace function public.preserve_subscription_bundle_original_reschedule_date()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_original_starts_at timestamptz;
begin
  if new.scheduled_for is not distinct from old.scheduled_for
     or new.scheduled_for is null then
    return new;
  end if;

  select nullif(event.metadata ->> 'previous_starts_at', '')::timestamptz
    into v_original_starts_at
    from public.appointment_status_events event
   where event.organization_id = old.organization_id
     and event.reason = 'subscription_bundle_session_rescheduled'
     and event.metadata ->> 'subscription_bundle_session_id' = old.id::text
     and nullif(event.metadata ->> 'previous_starts_at', '') is not null
   order by event.created_at, event.id
   limit 1;

  new.rescheduled_from := coalesce(
    v_original_starts_at,
    old.rescheduled_from,
    old.scheduled_for,
    old.canceled_from
  );
  return new;
end;
$$;

revoke all on function public.preserve_subscription_bundle_original_reschedule_date()
  from public, anon, authenticated, service_role;

drop trigger if exists subscription_bundle_sessions_preserve_original_reschedule_date
  on public.subscription_bundle_sessions;
create trigger subscription_bundle_sessions_preserve_original_reschedule_date
  before update of scheduled_for on public.subscription_bundle_sessions
  for each row execute function public.preserve_subscription_bundle_original_reschedule_date();
