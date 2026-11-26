import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("supabase/migrations/20261126143830_allow_shared_environment_work_intervals.sql", "utf8");

describe("shared room schedules and manager reschedule availability migration", () => {
  it("removes room exclusivity from work intervals while preserving manager RPC checks", () => {
    expect(migration).toContain("drop constraint if exists work_intervals_environment_no_overlap");
    expect(migration).toContain("mutate_barber_schedule_before_shared_room_schedules");
    expect(migration).toContain("and environment.location_id = v_location_id");
    expect(migration).not.toContain("environment_id = new.environment_id");
    expect(migration).toContain("resolve_appointment_environment");
  });

  it("uses stored appointment selections and excludes only current appointment from reschedule availability", () => {
    expect(migration).toContain("get_manager_appointment_reschedule_slots");
    expect(migration).toContain("preserved_selection_key");
    expect(migration).toContain("appointment.id is distinct from p_appointment_id");
    expect(migration).toContain("appointment.service_period && v_period");
    expect(migration).toContain("hold.service_period && v_period");
    expect(migration).toContain("organization_date_blocked(p_organization_id, v_period)");
  });

  it("re-resolves the environment atomically and ignores the current appointment while rescheduling", () => {
    expect(migration).toContain("create or replace function public.reschedule_appointment(");
    expect(migration).toContain("v_environment_id := public.resolve_appointment_environment(");
    expect(migration).toContain("v_period, null, v_appointment.id");
    expect(migration).toContain("environment_id = v_environment_id");
    expect(migration).toContain("organization_date_blocked(v_appointment.organization_id, v_period)");
  });
});
