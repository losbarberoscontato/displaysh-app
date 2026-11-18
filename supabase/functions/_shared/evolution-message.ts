export type EvolutionMessageKey = {
  id?: unknown;
  remoteJid?: unknown;
  remoteJidAlt?: unknown;
  participant?: unknown;
  participantAlt?: unknown;
  fromMe?: unknown;
  addressingMode?: unknown;
};

const ignoredJid = (value: unknown) => {
  const normalized = typeof value === "string" ? value.trim().toLowerCase() : "";
  return normalized.endsWith("@g.us") || normalized.endsWith("@broadcast");
};

export function phoneFromWhatsappJid(value: unknown): string | null {
  const normalized = typeof value === "string" ? value.trim() : "";
  if (normalized.toLowerCase().endsWith("@lid")) return null;
  const match = /^(\d{10,15})(?::\d+)?(?:@(s\.whatsapp\.net|c\.us))?$/iu.exec(
    normalized,
  );
  return match ? `+${match[1]}` : null;
}

export function senderPhoneFromMessageKey(
  key: EvolutionMessageKey | undefined,
): string | null {
  if (!key || ignoredJid(key.remoteJid)) return null;

  const candidates = [
    key.remoteJidAlt,
    key.remoteJid,
    key.participantAlt,
    key.participant,
  ];
  for (const candidate of candidates) {
    const phone = phoneFromWhatsappJid(candidate);
    if (phone) return phone;
  }
  return null;
}

export function isGroupOrBroadcastMessage(
  key: EvolutionMessageKey | undefined,
): boolean {
  return ignoredJid(key?.remoteJid);
}
