// @vitest-environment node

import { readFileSync } from "node:fs";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { PGlite } from "@electric-sql/pglite";

const migration = readFileSync(
  "supabase/migrations/20261126120000_whatsapp_subscription_response_jobs.sql",
  "utf8",
);
const offerMigration = readFileSync(
  "supabase/migrations/20261120183337_subscription_offer_whatsapp_confirmation.sql",
  "utf8",
);
const offerUi = readFileSync(
  "src/components/connected-manager/customers-manager.tsx",
  "utf8",
);

const organizationId = "10000000-0000-4000-8000-000000000001";
const appointmentId = "20000000-0000-4000-8000-000000000001";

let db: PGlite;

beforeAll(async () => {
  db = new PGlite();
  await db.exec(`
    create role anon;
    create role authenticated;
    create role service_role bypassrls;

    create function public.require_service_role() returns void
    language plpgsql as $$
    begin
      if current_setting('request.jwt.claim.role', true) is distinct from 'service_role' then
        raise exception 'SERVICE_REQUIRED';
      end if;
    end;
    $$;

    create table public.appointments (
      id uuid primary key,
      organization_id uuid not null,
      subscription_session_id uuid,
      subscription_bundle_session_id uuid
    );
    create table public.customer_subscription_sessions (
      organization_id uuid not null,
      appointment_id uuid not null
    );
    create table public.subscription_bundle_sessions (
      organization_id uuid not null,
      appointment_id uuid not null
    );
    create table public.whatsapp_automation_jobs (
      id uuid primary key default gen_random_uuid(),
      organization_id uuid not null,
      appointment_id uuid,
      job_type text not null,
      payload jsonb not null default '{}'::jsonb,
      status text not null default 'PENDING',
      locked_at timestamptz,
      locked_by text,
      lock_expires_at timestamptz,
      lease_token uuid,
      send_started_at timestamptz,
      last_error_code text,
      updated_at timestamptz not null default now()
    );
  `);
  await db.exec(migration);
  await db.exec(`
    create trigger subscription_whatsapp_job_insert_paused
    before insert on public.whatsapp_automation_jobs
    for each row execute function public.pause_subscription_whatsapp_job_insert();
  `);
}, 20_000);

afterAll(async () => {
  await db?.close();
});

beforeEach(async () => {
  await db.exec("begin");
  await db.query(
    `insert into public.appointments (
       id, organization_id, subscription_bundle_session_id
     ) values ($1, $2, $3)`,
    [appointmentId, organizationId, "30000000-0000-4000-8000-000000000001"],
  );
  await db.exec("set request.jwt.claim.role = 'service_role'");
});

afterEach(async () => {
  await db?.exec("rollback");
});

async function enqueue(jobType: string, payload: Record<string, unknown> = {}) {
  return (await db.query<{ id: string; status: string; last_error_code: string | null }>(
    `insert into public.whatsapp_automation_jobs (
       organization_id, appointment_id, job_type, payload
     ) values ($1, $2, $3, $4::jsonb)
     returning id, status, last_error_code`,
    [organizationId, appointmentId, jobType, JSON.stringify(payload)],
  )).rows[0];
}

describe("WhatsApp response jobs for subscription appointments", () => {
  it("allows the 1, 2, and 3 reply flows through insert and worker checks", async () => {
    const operationalJobs = [
      ["CONFIRMATION_ACK_CLIENT", {}],
      ["APPOINTMENT_CONFIRMED_STAFF", {}],
      ["APPOINTMENT_CONFIRMED_STAFF", { message_audience: "AUXILIARY" }],
      ["CANCELLATION_ACK_CLIENT", {}],
      ["APPOINTMENT_CANCELED_STAFF", { message_audience: "AUXILIARY" }],
      ["MANUAL_OUTBOUND_TEXT", { message_kind: "ATTENDANT_REQUEST_MANAGER" }],
    ] as const;

    for (const [jobType, payload] of operationalJobs) {
      const job = await enqueue(jobType, payload);
      expect(job.status, jobType).toBe("PENDING");
      await db.query(
        `update public.whatsapp_automation_jobs
            set status = 'PROCESSING', locked_by = 'worker-test'
          where id = $1`,
        [job.id],
      );
      const result = await db.query<{ allowed: boolean }>(
        "select public.whatsapp_v2_subscription_job_allowed($1, 'worker-test', null::uuid) as allowed",
        [job.id],
      );
      expect(result.rows[0].allowed, jobType).toBe(true);
    }
  });

  it("keeps automatic subscription and booking messages paused", async () => {
    for (const [jobType, payload] of [
      ["BOOKING_CREATED_CLIENT", {}],
      ["BOOKING_CREATED_STAFF", {}],
      ["SUBSCRIPTION_CREATED_CLIENT", { message_kind: "SUBSCRIPTION_CREATED_CLIENT" }],
      ["CONFIRMATION_ACK_CLIENT", { payment_mode: "SUBSCRIPTION" }],
      ["MANUAL_OUTBOUND_TEXT", {
        message_kind: "ATTENDANT_REQUEST_MANAGER",
        payment_mode: "SUBSCRIPTION",
      }],
      ["MANUAL_OUTBOUND_TEXT", { message_kind: "UNRELATED_AUTOMATION" }],
    ] as const) {
      const job = await enqueue(jobType, payload);
      expect(job.status, jobType).toBe("SKIPPED");
      expect(job.last_error_code).toBe("SUBSCRIPTION_WHATSAPP_PAUSED");
    }
  });

  it("preserves the manager's explicit subscription offer choice", async () => {
    expect(offerUi).toContain("Apenas criar o plano");
    expect(offerUi).toContain("Enviar Aviso pelo WhatsApp");
    expect(offerUi).toContain("p_send_whatsapp_notice: sendWhatsAppNotice");
    expect(offerMigration).toContain("if p_send_whatsapp_notice then");
    expect(offerMigration).toContain("'explicit_subscription_offer_notice', true");
    expect(offerMigration).toContain("coalesce((v_job.payload ->> 'explicit_subscription_offer_notice')::boolean, false)");

    const notice = await db.query<{ id: string; status: string }>(
      `insert into public.whatsapp_automation_jobs (
         organization_id, job_type, payload
       ) values ($1, 'MANUAL_OUTBOUND_TEXT', $2::jsonb)
       returning id, status`,
      [organizationId, JSON.stringify({
        message_kind: "PROJECT_CONTRACT_CREATED_CLIENT",
        transactional_plan_notice: true,
        explicit_subscription_offer_notice: true,
      })],
    );
    expect(notice.rows[0].status).toBe("PENDING");
  });
});
