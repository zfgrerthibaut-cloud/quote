type RealtimeEnvelope = Record<string, unknown>;

export type NormalizedRealtimeMessage = {
  id?: string;
  type: string;
  payload: unknown;
  shouldRefetch: boolean;
};

function isRecord(value: unknown): value is RealtimeEnvelope {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function text(value: unknown): string | undefined {
  if (typeof value === 'string') {
    const normalized = value.trim();
    return normalized || undefined;
  }
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  if (typeof value === 'bigint') return value.toString();
  return undefined;
}

function nestedPayload(value: unknown) {
  if (!isRecord(value)) return value;
  const data = value.data;
  if (!isRecord(data)) return data ?? value;
  return 'args' in data ? data.args : data;
}

function isRefetchEvent(type: string) {
  const normalized = type.toLowerCase();
  return (
    normalized === 'market.trade.upsert' ||
    normalized.includes('trade.upsert') ||
    normalized.includes('reorg') ||
    normalized.includes('rebuilt') ||
    normalized.includes('rebuild')
  );
}

export function normalizeRealtimeMessage(
  raw: unknown,
  eventType = 'message',
  explicitEventId?: string,
): NormalizedRealtimeMessage {
  if (!isRecord(raw)) {
    return { type: eventType, payload: raw, shouldRefetch: isRefetchEvent(eventType) };
  }

  const type = text(raw.type) || text(raw.event) || text(raw.topic) || eventType;
  const id = explicitEventId || text(raw.id) || text(raw.eventId) || text(raw.event_id) || text(raw.lastEventId);
  const payload = nestedPayload(raw);

  return {
    id,
    type,
    payload,
    shouldRefetch: isRefetchEvent(type),
  };
}
