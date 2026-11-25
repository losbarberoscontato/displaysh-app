import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const migration = () => readFileSync(
  resolve(process.cwd(), "supabase/migrations/20261125225454_booking_attendee_duplicate_guard.sql"),
  "utf8",
);

describe("migration de bloqueio de agendamentos por pessoa atendida", () => {
  it("impede sobreposição para titular e dependente, mantendo exceção entre pessoas diferentes", () => {
    const sql = migration();
    expect(sql).toContain("appointments_no_customer_attendee_overlap");
    expect(sql).toContain("appointments_no_dependent_attendee_overlap");
    expect(sql).toMatch(/attendee_dependent_id is null[\s\S]*status in \('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE'\)[\s\S]*deleted_at is null/u);
    expect(sql).toMatch(/attendee_dependent_id is not null[\s\S]*status in \('HELD', 'PENDING_PAYMENT', 'CONFIRMED', 'IN_SERVICE'\)[\s\S]*deleted_at is null/u);
  });

  it("leva a pessoa atendida ao hold antes de criar o agendamento", () => {
    const sql = migration();
    expect(sql).toContain("create or replace function public.create_customer_booking_hold(");
    expect(sql).toContain("p_attendee_dependent_id uuid");
    expect(sql).toContain("app.customer_booking_attendee_dependent_id");
    expect(sql).toContain("attendee_name_snapshot");
    expect(sql).toContain("'attendee_dependent_id', v_attendee_dependent_id");
    expect(sql).toContain("a.attendee_dependent_id is not distinct from v_attendee_dependent_id");
  });

  it("permite limpar uma reserva confirmada e não paga sem enviar cancelamento", () => {
    const sql = migration();
    expect(sql).toContain("delete_unpaid_customer_appointment");
    expect(sql).toContain("status = 'CANCELED'");
    expect(sql).toContain("deleted_at = v_cancelled_at");
    expect(sql).toContain("when (new.deleted_at is null)");
    expect(sql).toContain("outbound_notifications_suppressed");
    expect(sql).toContain("owner_requested_unpaid_customer_booking_cleanup");
  });

  it("mantém holds expirados fora das agendas e do contador", () => {
    const manager = readFileSync(resolve(process.cwd(), "src/components/connected-manager/server.ts"), "utf8");
    const barber = readFileSync(resolve(process.cwd(), "src/lib/barber-server.ts"), "utf8");
    const count = readFileSync(resolve(process.cwd(), "src/lib/agenda-count.ts"), "utf8");
    expect(manager).toContain('.not("status", "in", "(HELD,EXPIRED)")');
    expect(barber).toContain('.not("status", "in", "(HELD,EXPIRED)")');
    expect(count).toContain("(CANCELED,NO_SHOW,EXPIRED,HELD)");
  });
});
