import {
  type EvolutionMessageKey,
  isGroupOrBroadcastMessage,
  senderPhoneFromMessageKey,
} from "./evolution-message.ts";
import type { CanonicalMessage } from "./whatsapp-contracts.ts";

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function booleanValue(value: unknown): boolean {
  return value === true ||
    (typeof value === "string" && value.toLowerCase() === "true");
}

function unwrapMessage(value: unknown): Record<string, unknown> {
  let message = record(value);
  for (let depth = 0; depth < 4; depth += 1) {
    const wrapped = [
      message.ephemeralMessage,
      message.viewOnceMessage,
      message.viewOnceMessageV2,
      message.documentWithCaptionMessage,
    ].map(record).find((candidate) => candidate.message);
    if (!wrapped) break;
    message = record(wrapped.message);
  }
  return message;
}

function messageText(message: Record<string, unknown>): string | null {
  const extended = record(message.extendedTextMessage);
  const buttons = record(message.buttonsResponseMessage);
  const list = record(message.listResponseMessage);
  const listReply = record(list.singleSelectReply);
  const templateButton = record(message.templateButtonReplyMessage);
  return stringValue(message.conversation) ??
    stringValue(extended.text) ??
    stringValue(buttons.selectedButtonId) ??
    stringValue(listReply.selectedRowId) ??
    stringValue(templateButton.selectedId);
}

export function normalizeEvolutionEventName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toUpperCase().replaceAll(".", "_");
  return normalized || null;
}

export function normalizeEvolutionMessages(
  event: string,
  instance: string,
  data: unknown,
): CanonicalMessage[] {
  if (event !== "MESSAGES_UPSERT" && event !== "MESSAGES_UPDATE") return [];

  const result: CanonicalMessage[] = [];
  for (const item of Array.isArray(data) ? data : [data]) {
    const row = record(item);
    const key = record(row.key) as EvolutionMessageKey;
    const id = stringValue(key.id) ?? stringValue(row.keyId);
    if (!id || isGroupOrBroadcastMessage(key)) continue;

    const message = unwrapMessage(row.message);
    const extended = record(message.extendedTextMessage);
    const image = record(message.imageMessage);
    const context = record(extended.contextInfo ?? image.contextInfo);
    const update = record(row.update);
    const state = String(row.status ?? update.status ?? "").toUpperCase();
    const receipt = ({
      "0": "FAILED",
      "2": "SUBMITTED",
      "3": "DELIVERED",
      "4": "READ",
      "5": "READ",
      ERROR: "FAILED",
      SERVER_ACK: "SUBMITTED",
      DELIVERY_ACK: "DELIVERED",
      READ: "READ",
      PLAYED: "READ",
    } as const)[state as "0"] ?? null;
    const fromMe = booleanValue(key.fromMe);
    if (event === "MESSAGES_UPSERT" && fromMe) continue;
    if (event === "MESSAGES_UPDATE" && !receipt) continue;

    result.push({
      gateway_instance_id: instance,
      external_id: id,
      event_name: event as CanonicalMessage["event_name"],
      sender_e164: senderPhoneFromMessageKey(key),
      from_me: fromMe,
      text: messageText(message),
      quoted_id: stringValue(context.stanzaId),
      receipt: event === "MESSAGES_UPDATE" ? receipt : null,
      // Store only a provider message key. Never download arbitrary webhook URLs.
      media: event === "MESSAGES_UPSERT" && Object.keys(image).length > 0
        ? {
          key: {
            id,
            remoteJid: stringValue(key.remoteJid) ?? undefined,
            fromMe: false,
          },
        }
        : null,
    });
  }
  return result;
}

export function eventIdentity(event: CanonicalMessage): string {
  return `${event.event_name}:${event.gateway_instance_id}:${event.external_id}:${
    event.receipt ?? "message"
  }`;
}
