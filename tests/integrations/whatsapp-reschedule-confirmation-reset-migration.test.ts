import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  "supabase/migrations/20261126171311_reset_whatsapp_confirmation_on_reschedule.sql",
  "utf8",
);

describe("reagendamento reabre a confirmação de presença", () => {
  it("mantém a reserva confirmada e redefine as respostas do horário anterior", () => {
    expect(migration).toContain("before update of service_period, barber_id on public.appointments");
    expect(migration).toContain("old.status = 'CONFIRMED'");
    expect(migration).toContain("new.status = 'CONFIRMED'");
    expect(migration).toContain("new.whatsapp_response_status := 'PENDING'");
    expect(migration).toContain("new.whatsapp_presence_status := 'PENDING'");
    expect(migration).toContain("new.whatsapp_presence_confirmed_at := null");
    expect(migration).not.toMatch(/new\.status\s*:=/u);
  });

  it("enfileira presença no reagendamento e em um reset explícito da confirmação", () => {
    expect(migration).toContain("after update of service_period, barber_id, whatsapp_response_status");
    expect(migration).toContain("v_rescheduled := old.service_period is distinct from new.service_period");
    expect(migration).toContain("v_confirmation_reset := old.whatsapp_response_status is distinct from new.whatsapp_response_status");
    expect(migration).toContain("perform public.whatsapp_v2_enqueue_presence_reminder(");
    expect(migration).toContain("v_settings.mode <> 'ACTIVE' or v_settings.dispatch_paused");
  });
});
