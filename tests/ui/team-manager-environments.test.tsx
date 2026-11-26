import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const source = readFileSync("src/components/connected-manager/team-manager.tsx", "utf8");

describe("team schedule environment controls", () => {
  it("requires an available environment before adding a work interval", () => {
    expect(source).toContain('name="environment_id" required');
    expect(source).toContain("Nenhum ambiente permitido para este profissional nesta faixa.");
    expect(source).toContain("environment_id: environmentId");
    expect(source).toContain("selectedBarberOverlappingIntervals");
    expect(source).not.toContain("occupiedEnvironmentIds");
  });

  it("only asks for environment on available exceptions", () => {
    expect(source).toContain('value="AVAILABLE_OVERRIDE"');
    expect(source).toContain('name="environment_id"');
    expect(source).toContain('p_environment_id: kind === "AVAILABLE_OVERRIDE"');
  });
});
