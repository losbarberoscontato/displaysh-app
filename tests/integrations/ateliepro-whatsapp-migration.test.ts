// @vitest-environment node

import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { PGlite } from "@electric-sql/pglite";
import { whatsappDatabase } from "../helpers/whatsapp-database";

let db: PGlite;

beforeAll(async () => {
  db = await whatsappDatabase();
  const migration = readFileSync(
    "supabase/migrations/20261115205411_ateliepro_product_support.sql",
    "utf8",
  );
  const start = migration.indexOf(
    "alter function public.whatsapp_v2_default_message_templates_for_product(text)",
  );
  if (start < 0) throw new Error("AteliePro WhatsApp defaults are missing from migration");
  await db.exec(migration.slice(start));
}, 60_000);

afterAll(async () => { await db?.close(); });

describe("AteliePro WhatsApp migration", () => {
  it("adds sewing copy to new settings and preserves manager customizations", async () => {
    const organizationId = "50000000-0000-4000-8000-000000000017";
    await db.exec(`
      insert into public.organizations(id) values ('${organizationId}');
      insert into public.organization_product_assignments(organization_id, product_key)
      values ('${organizationId}', 'ateliepro');
      insert into public.whatsapp_automation_settings_v2(organization_id, templates)
      values ('${organizationId}', jsonb_build_object('BOOKING_CREATED_STAFF', 'Texto personalizado da gestão.'));
    `);

    const result = await db.query<{ templates: Record<string, string> }>(
      `select templates from public.whatsapp_automation_settings_v2 where organization_id = '${organizationId}'`,
    );
    expect(result.rows[0].templates.BOOKING_CREATED_CLIENT).toContain("atendimento de costura");
    expect(result.rows[0].templates.BOOKING_CREATED_STAFF).toBe("Texto personalizado da gestão.");
    expect(result.rows[0].templates.ATTENDANT_REQUEST_MANAGER).toContain("Costureira: {profissional}");
    expect(result.rows[0].templates.ATTENDANT_REQUEST_MANAGER).toContain("Serviço de costura: {servico}");
  });

  it("keeps the existing product defaults unchanged", async () => {
    const result = await db.query<{ client_message: string }>(
      `select public.whatsapp_v2_default_message_templates_for_product('music-pro') ->> 'BOOKING_CREATED_CLIENT' as client_message`,
    );
    expect(result.rows[0].client_message).toContain("aula na escola");
  });
});
