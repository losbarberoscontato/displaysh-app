import {
  eventIdentity,
  normalizeEvolutionMessages,
  normalizeEvolutionEventName,
} from "../_shared/whatsapp-normalize.ts";
import { requiredEnv } from "../_shared/env.ts";
import { endpoint, json } from "../_shared/http.ts";
import { providerFetch } from "../_shared/provider-http.ts";
import {
  IntegrationError,
  sha256Hex,
  verifySharedSecretHeader,
} from "../_shared/security.ts";
import { rpc } from "../_shared/supabase.ts";

type EvolutionPayload = {
  event?: unknown;
  instance?: unknown;
  data?: unknown;
};
type InstanceInfo = {
  ownerJid?: unknown;
  number?: unknown;
  instance?: { ownerJid?: unknown; number?: unknown };
};
type EdgeRuntimeWithWaitUntil = { waitUntil(promise: Promise<unknown>): void };

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function phone(value: unknown): string | null {
  const match = /^(\d{10,15})(?::\d+)?(?:@(s\.whatsapp\.net|c\.us))?$/iu.exec(
    typeof value === "string" ? value : "",
  );
  return match ? `+${match[1]}` : null;
}

async function syncConnectedPhone(
  instanceName: string,
  input?: unknown,
): Promise<void> {
  try {
    const values = Array.isArray(input) ? input : [input];
    let found: string | null = null;
    for (const value of values) {
      const row = value as InstanceInfo | undefined;
      found = phone(row?.ownerJid) ?? phone(row?.number) ??
        phone(row?.instance?.ownerJid) ?? phone(row?.instance?.number);
      if (found) break;
    }
    if (!found) {
      const url = new URL(
        `${
          requiredEnv("EVOLUTION_API_BASE_URL").replace(/\/$/u, "")
        }/instance/fetchInstances`,
      );
      url.searchParams.set("instanceName", instanceName);
      const result = await providerFetch<unknown>(url.toString(), {
        method: "GET",
        headers: { apikey: requiredEnv("EVOLUTION_API_KEY") },
      });
      for (const value of (Array.isArray(result) ? result : [result])) {
        const row = value as InstanceInfo;
        found = phone(row.ownerJid) ?? phone(row.number) ??
          phone(row.instance?.ownerJid) ?? phone(row.instance?.number);
        if (found) break;
      }
    }
    if (found) {
      await rpc("store_whatsapp_qr_connected_phone", {
        p_gateway_instance_id: instanceName,
        p_connected_phone_e164: found,
      });
    }
  } catch (error) {
    console.error("whatsapp_connected_phone_sync_failed", {
      errorCode: error instanceof IntegrationError
        ? error.code
        : "UNKNOWN_ERROR",
    });
  }
}

async function triggerV2Dispatcher(): Promise<void> {
  try {
    const baseUrl = requiredEnv("SUPABASE_URL").replace(/\/$/u, "");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const response = await fetch(
      `${baseUrl}/functions/v1/whatsapp-v2-dispatcher`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${serviceRoleKey}`,
          apikey: serviceRoleKey,
          "content-type": "application/json",
        },
        body: JSON.stringify({ limit: 25 }),
      },
    );
    if (!response.ok) {
      console.error("whatsapp_v2_dispatch_trigger_failed", {
        status: response.status,
      });
    }
  } catch (error) {
    console.error("whatsapp_v2_dispatch_trigger_failed", {
      errorCode: error instanceof IntegrationError
        ? error.code
        : "UNKNOWN_ERROR",
    });
  }
}

type WebhookDiagnostics = {
  stage: string;
  event: string;
  instanceFingerprint: string | null;
};

async function handleWebhook(
  request: Request,
  diagnostics: WebhookDiagnostics,
): Promise<Response> {
  if (request.method !== "POST") {
    throw new IntegrationError(405, "METHOD_NOT_ALLOWED");
  }
  diagnostics.stage = "read_body";
  const raw = await request.text();
  diagnostics.stage = "verify_secret";
  if (
    !verifySharedSecretHeader(
      request.headers.get("x-evolution-webhook-secret"),
      requiredEnv("EVOLUTION_WEBHOOK_SECRET"),
    )
  ) {
    console.warn("whatsapp_qr_webhook_rejected", {
      reason: "INVALID_SIGNATURE",
      auth_header_present: Boolean(
        request.headers.get("x-evolution-webhook-secret"),
      ),
    });
    throw new IntegrationError(401, "INVALID_SIGNATURE");
  }

  diagnostics.stage = "parse_payload";
  let decoded: unknown;
  try {
    decoded = JSON.parse(raw) as unknown;
  } catch {
    throw new IntegrationError(400, "INVALID_JSON");
  }
  if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) {
    throw new IntegrationError(400, "INVALID_PAYLOAD");
  }
  const payload = decoded as EvolutionPayload;
  diagnostics.stage = "normalize_event";
  diagnostics.event = normalizeEvolutionEventName(payload.event) ?? "UNKNOWN";
  if (diagnostics.event === "UNKNOWN") {
    console.warn("whatsapp_qr_webhook_rejected", {
      reason: "EVENT_MISSING_OR_INVALID",
      event_type: typeof payload.event,
    });
    return json(request, { received: true, queued: false });
  }
  const instance = typeof payload.instance === "string"
    ? payload.instance.trim()
    : "";
  if (!instance) {
    console.warn("whatsapp_qr_webhook_rejected", {
      event: diagnostics.event,
      reason: "INSTANCE_MISSING",
      instance_type: typeof payload.instance,
    });
    return json(request, { received: true, queued: false });
  }

  diagnostics.stage = "fingerprint_instance";
  diagnostics.instanceFingerprint = (await sha256Hex(instance)).slice(0, 12);
  const data = record(payload.data);
  if (diagnostics.event === "QRCODE_UPDATED") {
    const qrcode = record(data.qrcode);
    const code = typeof data.base64 === "string"
      ? data.base64
      : typeof qrcode.base64 === "string"
      ? qrcode.base64
      : null;
    if (code) {
      diagnostics.stage = "store_qr_code";
      await rpc("store_whatsapp_qr_code", {
        p_gateway_instance_id: instance,
        p_qr_code: code,
        p_expires_at: new Date(Date.now() + 300_000).toISOString(),
      });
    }
    return json(request, { received: true, qrStored: Boolean(code) });
  }

  if (
    diagnostics.event === "CONNECTION_UPDATE" &&
    typeof data.state === "string"
  ) {
    diagnostics.stage = "update_connection";
    const updated = await rpc<boolean>("update_whatsapp_qr_status", {
      p_gateway_instance_id: instance,
      p_status: data.state,
      p_error_code: typeof data.statusReason === "string"
        ? data.statusReason.slice(0, 255)
        : null,
    });
    if (["open", "connected"].includes(data.state.toLowerCase())) {
      await syncConnectedPhone(instance, data);
    }
    return json(request, { received: true, updated });
  }

  if (
    diagnostics.event !== "MESSAGES_UPSERT" &&
    diagnostics.event !== "MESSAGES_UPDATE"
  ) return json(request, { received: true });

  diagnostics.stage = "normalize_messages";
  const events = normalizeEvolutionMessages(
    diagnostics.event,
    instance,
    payload.data,
  );
  if (events.length === 0) {
    console.warn("whatsapp_qr_webhook_unparsed", {
      event: diagnostics.event,
      instance_fingerprint: diagnostics.instanceFingerprint,
      data_is_array: Array.isArray(payload.data),
      data_keys: Object.keys(data).slice(0, 24),
    });
  }

  let queued = false;
  let persistedCount = 0;
  for (const item of events) {
    diagnostics.stage = "persist_event";
    const fingerprint = await sha256Hex(eventIdentity(item));
    let eventId: string | null;
    try {
      eventId = await rpc<string | null>("record_whatsapp_v2_webhook_event", {
        p_gateway_instance_id: instance,
        p_event_name: item.event_name,
        p_provider_event_id: item.external_id,
        p_fingerprint: fingerprint,
        p_payload: item,
      });
    } catch (error) {
      console.error("whatsapp_qr_webhook_persist_failed", {
        event: diagnostics.event,
        instance_fingerprint: diagnostics.instanceFingerprint,
        error_code: error instanceof IntegrationError
          ? error.code
          : "WEBHOOK_EVENT_PERSIST_FAILED",
      });
      throw error;
    }
    queued = queued || Boolean(eventId);
    if (eventId) persistedCount += 1;
  }

  console.info("whatsapp_qr_webhook_processed", {
    event: diagnostics.event,
    instance_fingerprint: diagnostics.instanceFingerprint,
    normalized_count: events.length,
    persisted_count: persistedCount,
    queued,
  });
  // Low-latency path. The minute cron remains the durable fallback.
  if (queued) {
    diagnostics.stage = "trigger_dispatcher";
    const dispatch = triggerV2Dispatcher();
    const edgeRuntime = (globalThis as typeof globalThis & {
      EdgeRuntime?: EdgeRuntimeWithWaitUntil;
    }).EdgeRuntime;
    if (typeof edgeRuntime?.waitUntil === "function") {
      edgeRuntime.waitUntil(dispatch);
    } else void dispatch;
  }
  return json(request, {
    received: true,
    normalized: events.length,
    queued,
  });
}

Deno.serve((request) => {
  const diagnostics: WebhookDiagnostics = {
    stage: "method",
    event: "UNKNOWN",
    instanceFingerprint: null,
  };
  return endpoint(request, async () => {
    try {
      return await handleWebhook(request, diagnostics);
    } catch (error) {
      console.error("whatsapp_qr_webhook_failed", {
        stage: diagnostics.stage,
        event: diagnostics.event,
        instance_fingerprint: diagnostics.instanceFingerprint,
        error_name: error instanceof Error ? error.name : "UnknownError",
        error_code: error instanceof IntegrationError
          ? error.code
          : undefined,
      });
      throw error;
    }
  });
});
