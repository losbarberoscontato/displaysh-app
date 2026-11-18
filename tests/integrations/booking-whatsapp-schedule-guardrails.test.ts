import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  resolve(
    process.cwd(),
    "supabase/migrations/20261118145132_booking_whatsapp_schedule_guardrails.sql",
  ),
  "utf8",
);

function functionDefinition(name: string): string {
  const definition = migration.match(
    new RegExp(
      `create (?:or replace )?function public\\.${name}\\([\\s\\S]*?\\$\\$;`,
      "i",
    ),
  );
  return definition?.[0] ?? "";
}

describe("proteções de agendamento e WhatsApp", () => {
  it("só agenda lembrete de presença após a confirmação operacional", () => {
    const scheduler = functionDefinition("schedule_whatsapp_v2_for_appointment");

    expect(scheduler).toMatch(/v_start\s*>\s*now\(\)\s+and\s+v_confirmed_transition/iu);
  });

  it("expira pedidos de confirmação quando a reserva fica terminal, inclusive EXPIRED", () => {
    const scheduler = functionDefinition("schedule_whatsapp_v2_for_appointment");

    expect(scheduler).toMatch(/new\.status\s+in\s*\([^)]*'EXPIRED'[^)]*\)[\s\S]*?update public\.whatsapp_confirmation_requests_v2[\s\S]*?set status\s*=\s*'EXPIRED'/iu);
  });

  it("revalida a escala excluindo a própria reserva que está sendo confirmada", () => {
    const scheduleGuard = functionDefinition("enforce_appointment_schedule_lock");

    expect(functionDefinition("is_barber_available_for_appointment")).not.toBe("");
    expect(scheduleGuard).toMatch(/security definer/iu);
    expect(scheduleGuard).toMatch(/is_barber_available_for_appointment\(\s*new\.organization_id,\s*new\.barber_id,\s*new\.service_period,\s*new\.id\s*\)/iu);
  });

  it("limpa lembretes pendentes de reservas existentes sem confirmação", () => {
    expect(migration).toMatch(/update public\.whatsapp_automation_jobs job[\s\S]*?appointment\.status <> 'CONFIRMED'[\s\S]*?job\.status in \('PENDING', 'RETRY'\)/iu);
  });
});
