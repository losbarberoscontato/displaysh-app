import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("supabase/migrations/20261126155903_prevent_overlapping_room_schedules.sql", "utf8");

describe("environment work interval conflict migration", () => {
  it("serializes writes per room and rejects only overlapping schedules in that room", () => {
    expect(migration).toContain("work_intervals_z_guard_room_schedule_conflict");
    expect(migration).toContain("for update");
    expect(migration).toContain("interval_row.environment_id = new.environment_id");
    expect(migration).toContain("interval_row.weekday = new.weekday");
    expect(migration).toContain("interval_row.starts_at < new.ends_at");
    expect(migration).toContain("interval_row.ends_at > new.starts_at");
    expect(migration).toContain("environment already has a work interval in this period");
  });

  it("auto-assigns only rooms without another active schedule in the requested range", () => {
    expect(migration).toContain("and interval_row.environment_id = environment.id");
    expect(migration).toContain("and interval_row.active");
    expect(migration).toContain("and interval_row.starts_at < p_ends_at");
    expect(migration).toContain("and interval_row.ends_at > p_starts_at");
    expect(migration).toContain("mutate_barber_schedule_before_shared_room_schedules");
  });
});
