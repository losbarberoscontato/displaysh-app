import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { textFor } from "../../supabase/functions/_shared/whatsapp-templates";

const migration = readFileSync(
  "supabase/migrations/20261125151846_appointment_reschedule_whatsapp_notifications.sql",
  "utf8",
);

const basePayload = {
  customer_name: "Julio",
  barber_name: "Adriana",
  original_starts_at: "2026-12-09T17:00:00.000Z",
  starts_at: "2026-12-08T17:00:00.000Z",
  timezone: "America/Sao_Paulo",
};

describe("appointment reschedule WhatsApp notices", () => {
  it("formats the dedicated client, professional, and auxiliary templates with both dates", () => {
    const templates = {
      APPOINTMENT_RESCHEDULED_CLIENT: "Prezado(a) {cliente}, sua sessão do dia {horario_original}, foi reagendada para o dia {horario_novo} com o profissional {profissional}.",
      APPOINTMENT_RESCHEDULED_STAFF: "Sessão reagendada. Cliente: {cliente}, De: {horario_original}, para: {horario_novo}",
      APPOINTMENT_RESCHEDULED_AUXILIARY: "Sessão reagendada. Cliente: {cliente}, De: {horario_original}, para: {horario_novo}",
    };
    const render = (message_kind: keyof typeof templates) => textFor({
      job_type: "MANUAL_OUTBOUND_TEXT",
      payload: { ...basePayload, message_kind, templates },
    });

    expect(render("APPOINTMENT_RESCHEDULED_CLIENT"))
      .toBe("Prezado(a) Julio, sua sessão do dia 09/12/2026, 14:00, foi reagendada para o dia 08/12/2026, 14:00 com o profissional Adriana.");
    expect(render("APPOINTMENT_RESCHEDULED_STAFF"))
      .toBe("Sessão reagendada. Cliente: Julio, De: 09/12/2026, 14:00, para: 08/12/2026, 14:00");
    expect(render("APPOINTMENT_RESCHEDULED_AUXILIARY"))
      .toBe("Sessão reagendada. Cliente: Julio, De: 09/12/2026, 14:00, para: 08/12/2026, 14:00");
  });

  it("enqueues per-recipient reschedule jobs and exempts only these notices from the subscription pause", () => {
    expect(migration).toContain("after update of service_period, barber_id on public.appointments");
    expect(migration).toContain("after insert on public.appointments");
    expect(migration).toContain("APPOINTMENT_RESCHEDULED_CLIENT");
    expect(migration).toContain("APPOINTMENT_RESCHEDULED_STAFF");
    expect(migration).toContain("APPOINTMENT_RESCHEDULED_AUXILIARY");
    expect(migration).toContain("for v_auxiliary in");
    expect(migration).toContain("whatsapp_v2_consented(new.organization_id, new.customer_id)");
    expect(migration).toContain("v_settings.staff_notifications_enabled");
    expect(migration).toContain("reschedule-notice:auxiliary:");
    expect(migration).toContain("reschedule_observation");
  });
});
