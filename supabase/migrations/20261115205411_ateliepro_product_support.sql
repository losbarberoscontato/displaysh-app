-- Add AteliePro to the existing shared product model. Tenant boundaries,
-- appointment flows, and billing state transitions remain unchanged.

alter table public.platform_product_identity_drafts
  drop constraint if exists platform_product_identity_drafts_product_key_check;
alter table public.platform_product_identity_drafts
  add constraint platform_product_identity_drafts_product_key_check
  check (product_key in ('los-barberos', 'le-gras', 'pro-stetic', 'music-pro', 'ateliepro'));

alter table public.platform_product_identities
  drop constraint if exists platform_product_identities_product_key_check;
alter table public.platform_product_identities
  add constraint platform_product_identities_product_key_check
  check (product_key in ('los-barberos', 'le-gras', 'pro-stetic', 'music-pro', 'ateliepro'));

alter table public.organization_product_assignments
  drop constraint if exists organization_product_assignments_product_key_check;
alter table public.organization_product_assignments
  add constraint organization_product_assignments_product_key_check
  check (product_key in ('los-barberos', 'le-gras', 'pro-stetic', 'music-pro', 'ateliepro'));

insert into public.platform_product_identities (product_key, config)
values (
  'ateliepro',
  jsonb_build_object(
    'brand', jsonb_build_object(
      'name', 'AteliePro',
      'tagline', 'Gestão para ateliês de costura',
      'mark', 'AP',
      'logoUrl', '/ateliepro/mark.png'
    ),
    'colors', jsonb_build_object(
      'primary', '#4A3024', 'secondary', '#78543C', 'accent', '#A87860',
      'background', '#F4ECE4', 'surface', '#FFFCF9', 'text', '#35261F',
      'muted', '#806C60', 'border', '#DDCFC4', 'success', '#526C53',
      'danger', '#9B5147', 'primarySoft', '#E9DDD3', 'accentSoft', '#F1E1DA',
      'accentDeep', '#78543C', 'accentHover', '#906048', 'accentTint', '#F6EAE4',
      'focusRing', '#A87860'
    ),
    'fonts', jsonb_build_object('interface', 'Inter', 'display', 'Baskerville'),
    'vocabulary', jsonb_build_object(
      'organization', 'ateliê', 'organizationPlural', 'ateliês',
      'professional', 'costureira', 'professionalPlural', 'costureiras',
      'teamApp', 'App da Costureira', 'organizationPicker', 'Meus ateliês',
      'customer', 'cliente', 'customerPlural', 'clientes',
      'service', 'serviço de costura', 'servicePlural', 'serviços de costura'
    )
  )
)
on conflict (product_key) do nothing;

insert into public.platform_product_identity_drafts (product_key, config)
select product_key, config
from public.platform_product_identities
where product_key = 'ateliepro'
on conflict (product_key) do nothing;

create or replace function public.onboard_organization(
  p_name text,
  p_slug text,
  p_location_name text,
  p_timezone text default 'America/Sao_Paulo',
  p_product_key text default 'los-barberos'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_location_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_product_key not in ('los-barberos', 'le-gras', 'pro-stetic', 'music-pro', 'ateliepro') then
    raise exception using errcode = '22023', message = 'unsupported product';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  if exists (
    select 1
    from public.organization_memberships m
    join public.organization_product_assignments a using (organization_id)
    where m.user_id = v_user_id
      and m.active
      and m.role = 'OWNER'
      and a.product_key = p_product_key
  ) then
    raise exception using errcode = '23514',
      message = 'user already owns an active organization for this product';
  end if;
  if not exists (select 1 from pg_timezone_names where name = p_timezone) then
    raise exception using errcode = '22023', message = 'invalid IANA timezone';
  end if;

  insert into public.profiles (id) values (v_user_id) on conflict (id) do nothing;
  insert into public.organizations (name, slug, timezone, created_by)
  values (btrim(p_name), lower(btrim(p_slug)), p_timezone, v_user_id)
  returning id into v_organization_id;
  insert into public.locations (organization_id, name)
  values (v_organization_id, btrim(p_location_name))
  returning id into v_location_id;
  insert into public.organization_memberships (organization_id, user_id, role)
  values (v_organization_id, v_user_id, 'OWNER');
  insert into public.saas_subscriptions (organization_id, status)
  values (v_organization_id, 'PROVISIONING');
  insert into public.organization_product_assignments (organization_id, product_key)
  values (v_organization_id, p_product_key);
  insert into public.organization_access_events (
    organization_id, to_status, reason, actor_user_id
  ) values (
    v_organization_id, 'PROVISIONING', 'organization_onboarded', v_user_id
  );
  insert into public.audit_events (
    organization_id, actor_user_id, actor_kind, action, entity_type, entity_id
  ) values (
    v_organization_id, v_user_id, 'USER', 'organization.onboarded',
    'organization', v_organization_id::text
  );

  return jsonb_build_object(
    'organization_id', v_organization_id,
    'location_id', v_location_id,
    'subscription_status', 'PROVISIONING',
    'product_key', p_product_key
  );
exception
  when unique_violation then
    raise exception using errcode = '23505', message = 'organization slug already exists';
end;
$$;

revoke all on function public.onboard_organization(text, text, text, text, text) from public, anon, service_role;
grant execute on function public.onboard_organization(text, text, text, text, text) to authenticated;

alter table public.platform_kanban_price_versions
  drop constraint if exists platform_kanban_price_versions_product_key_check;
alter table public.platform_kanban_price_versions
  add constraint platform_kanban_price_versions_product_key_check
  check (product_key in ('los-barberos', 'le-gras', 'pro-stetic', 'music-pro', 'ateliepro'));

create or replace function public.publish_platform_kanban_price(
  p_product_key text,
  p_monthly_price_cents bigint,
  p_stripe_test_price_id text,
  p_stripe_live_price_id text,
  p_contract_version text,
  p_contract_body text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception using errcode = '42501', message = 'platform admin required';
  end if;
  if p_product_key not in ('los-barberos', 'le-gras', 'pro-stetic', 'music-pro', 'ateliepro')
     or p_monthly_price_cents <= 0
     or left(coalesce(p_stripe_test_price_id, ''), 6) <> 'price_'
     or left(coalesce(p_stripe_live_price_id, ''), 6) <> 'price_'
     or char_length(btrim(coalesce(p_contract_body, ''))) < 20 then
    raise exception using errcode = '22023', message = 'complete Kanban price, Stripe IDs and addendum required';
  end if;
  update public.platform_kanban_price_versions
  set retired_at = now()
  where product_key = p_product_key and retired_at is null;
  insert into public.platform_kanban_price_versions (
    product_key, monthly_price_cents, stripe_test_price_id, stripe_live_price_id,
    contract_version, contract_body, created_by
  ) values (
    p_product_key, p_monthly_price_cents, btrim(p_stripe_test_price_id),
    btrim(p_stripe_live_price_id), btrim(p_contract_version),
    btrim(p_contract_body), auth.uid()
  ) returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.publish_platform_kanban_price(text, bigint, text, text, text, text) from public, anon;
grant execute on function public.publish_platform_kanban_price(text, bigint, text, text, text, text) to authenticated;

-- The checkout price remains product-specific and is configured through the
-- existing server-side Stripe secret management process.

alter function public.whatsapp_v2_default_message_templates_for_product(text)
  rename to whatsapp_v2_default_message_templates_for_product_base;

create function public.whatsapp_v2_default_message_templates_for_product(p_product_key text)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_templates jsonb;
  v_confirmation text := E'Responda somente com um número:\n1 — Confirmar\n2 — Cancelar\n3 — Falar com atendente';
begin
  if p_product_key <> 'ateliepro' then
    return public.whatsapp_v2_default_message_templates_for_product_base(p_product_key);
  end if;
  v_templates := public.whatsapp_v2_default_message_templates_for_product_base('los-barberos');
  return v_templates || jsonb_build_object(
    'BOOKING_CREATED_CLIENT', '{cliente}, seu atendimento de costura no ateliê foi confirmado para {horario}.',
    'BOOKING_CREATED_STAFF', 'Novo atendimento de costura no ateliê: {cliente}, {horario}.',
    'REMINDER_T24_CLIENT', E'Lembrete: seu atendimento de costura está marcado para {horario} (daqui a 24 horas).\n\n' || v_confirmation,
    'REMINDER_MORNING_CLIENT', E'Lembrete: seu atendimento de costura é {horario}.\n\n' || v_confirmation,
    'REMINDER_T180_CLIENT', E'Lembrete: seu atendimento de costura está marcado para {horario}.\n\n' || v_confirmation,
    'REMINDER_T45_CLIENT', E'Lembrete: seu atendimento de costura está marcado para {horario}.\n\n' || v_confirmation,
    'CONFIRMATION_ACK_CLIENT', 'Presença no atendimento confirmada. Até {horario}.',
    'CANCELLATION_ACK_CLIENT', 'Cancelamento confirmado. Se precisar, fale com o ateliê para marcar novo horário.',
    'APPOINTMENT_CONFIRMED_STAFF', '{cliente} confirmou presença no atendimento pelo WhatsApp para {horario}.',
    'APPOINTMENT_CANCELED_STAFF', '{cliente} cancelou o atendimento pelo WhatsApp.',
    'ATTENDANT_REQUEST_MANAGER', E'Cliente deseja falar com o ateliê.\n\nCliente: {cliente}\nWhatsApp: {telefone}\nData e hora: {horario}\nCostureira: {profissional}\nServiço de costura: {servico}',
    'MANUAL_CONFIRMATION_CLIENT', '{cliente}, seu atendimento foi confirmado pelo ateliê para {horario}.',
    'MANUAL_CONFIRMATION_STAFF', 'Atendimento confirmado manualmente: {cliente}, {horario}.',
    'RESERVATION_CHOICE', E'Encontrei mais de um atendimento. Responda com o número correspondente:\n\n{reservas}',
    'BOOKING_CREATED_AUXILIARY', 'Você foi escalada como auxiliar no atendimento de {cliente} em {horario}.',
    'APPOINTMENT_CONFIRMED_AUXILIARY', '{cliente} confirmou presença no atendimento em {horario}. Você está escalada como auxiliar.',
    'APPOINTMENT_CANCELED_AUXILIARY', '{cliente} cancelou o atendimento.',
    'MANUAL_CONFIRMATION_AUXILIARY', 'O gestor confirmou manualmente o atendimento de {cliente} em {horario}. Você está escalada como auxiliar.'
  );
end;
$$;

revoke all on function public.whatsapp_v2_default_message_templates_for_product_base(text) from public, anon, authenticated;
grant execute on function public.whatsapp_v2_default_message_templates_for_product_base(text) to service_role;
revoke all on function public.whatsapp_v2_default_message_templates_for_product(text) from public, anon, authenticated;
grant execute on function public.whatsapp_v2_default_message_templates_for_product(text) to service_role;

update public.whatsapp_automation_settings_v2 s
set templates = public.whatsapp_v2_localize_message_templates_for_product(a.product_key, s.templates)
from public.organization_product_assignments a
where a.organization_id = s.organization_id
  and a.product_key = 'ateliepro'
  and s.templates is distinct from public.whatsapp_v2_localize_message_templates_for_product(a.product_key, s.templates);
