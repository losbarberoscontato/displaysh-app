import { functionUrl, requiredEnv } from "./env.ts";
import { providerFetch } from "./provider-http.ts";
import { IntegrationError } from "./security.ts";

export const whatsappQrWebhookEvents = [
  "QRCODE_UPDATED",
  "CONNECTION_UPDATE",
  "MESSAGES_UPSERT",
  "MESSAGES_UPDATE",
] as const;

export function evolutionQrWebhookConfig() {
  return {
    enabled: true,
    url: functionUrl("whatsapp-qr-webhook"),
    byEvents: false,
    base64: true,
    headers: {
      "x-evolution-webhook-secret": requiredEnv("EVOLUTION_WEBHOOK_SECRET"),
    },
    events: whatsappQrWebhookEvents,
  };
}

export async function configureEvolutionQrWebhook(
  baseUrl: string,
  instanceName: string,
  apiKey: string,
): Promise<void> {
  const root = baseUrl.replace(/\/$/u, "");
  const config = evolutionQrWebhookConfig();
  const headers = { apikey: apiKey, "content-type": "application/json" };
  await providerFetch<unknown>(
    `${root}/webhook/set/${encodeURIComponent(instanceName)}`,
    {
      method: "POST",
      headers,
      body: JSON.stringify({ webhook: config }),
    },
  );

  const result = await providerFetch<unknown>(
    `${root}/webhook/find/${encodeURIComponent(instanceName)}`,
    { method: "GET", headers: { apikey: apiKey } },
  );
  const outer = asRecord(result);
  const webhook = asRecord(outer.webhook ?? outer);
  const events = Array.isArray(webhook.events)
    ? webhook.events.map((event) => String(event).toUpperCase())
    : [];
  const url = typeof webhook.url === "string"
    ? webhook.url.replace(/\/$/u, "")
    : "";
  const byEvents = webhook.webhookByEvents ?? webhook.byEvents ??
    webhook.webhook_by_events;
  const expectedUrl = config.url.replace(/\/$/u, "");
  const valid = webhook.enabled === true && url === expectedUrl &&
    byEvents !== true && events.includes("MESSAGES_UPSERT");
  if (!valid) {
    console.warn("whatsapp_qr_webhook_config_verification_failed", {
      enabled: webhook.enabled === true,
      url_matches: url === expectedUrl,
      by_events: byEvents === true,
      messages_upsert_enabled: events.includes("MESSAGES_UPSERT"),
    });
    throw new IntegrationError(
      502,
      "WEBHOOK_CONFIGURATION_VERIFICATION_FAILED",
      true,
    );
  }
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}
