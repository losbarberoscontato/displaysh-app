import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { timeIntervalsOverlap } from "../../src/components/connected-manager/format";

const source = readFileSync("src/components/connected-manager/team-manager.tsx", "utf8");

describe("team schedule environment controls", () => {
  it("requires an available environment before adding a work interval", () => {
    expect(source).toContain('name="environment_id" required');
    expect(source).toContain("Nenhum ambiente livre neste dia e horário.");
    expect(source).toContain("environment_id: environmentId");
    expect(source).toContain("selectedBarberOverlappingIntervals");
    expect(source).not.toContain("occupiedEnvironmentIds");
    expect(source).toContain("overlappingRoomIntervals");
    expect(source).toContain("interval.environment_id === environment.id");
  });

  it("blocks overlapping shifts in the same room but allows adjacent shifts", () => {
    expect(timeIntervalsOverlap("09:00", "15:00", "14:00", "22:00")).toBe(true);
    expect(timeIntervalsOverlap("09:00", "14:00", "14:00", "22:00")).toBe(false);
    expect(timeIntervalsOverlap("09:00", "13:00", "14:00", "22:00")).toBe(false);
  });

  it("only asks for environment on available exceptions", () => {
    expect(source).toContain('value="AVAILABLE_OVERRIDE"');
    expect(source).toContain('name="environment_id"');
    expect(source).toContain('p_environment_id: kind === "AVAILABLE_OVERRIDE"');
  });
});
