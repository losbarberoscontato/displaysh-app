create policy agenda_environments_barber_read
  on public.agenda_environments
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.barbers b
      where b.organization_id = agenda_environments.organization_id
        and b.auth_user_id = (select auth.uid())
        and b.active
        and b.app_access_enabled
        and (
          b.agenda_access_scope = 'FULL'
          or b.location_id = agenda_environments.location_id
        )
    )
  );
