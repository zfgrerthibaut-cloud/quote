export const MAX_OUTBOX_EVENT_ID = 9_223_372_036_854_775_807n;

const DECIMAL_ID = /^\d+$/;

export function clampOutboxEventId(value: bigint) {
  if (value < 0n) return 0n;
  return value > MAX_OUTBOX_EVENT_ID ? MAX_OUTBOX_EVENT_ID : value;
}

export function parseOutboxEventId(value: string | null | undefined) {
  if (value === null || value === undefined || value === '') return 0n;
  if (!DECIMAL_ID.test(value)) return null;
  const normalized = value.replace(/^0+/, '') || '0';
  if (normalized.length > 19) return null;
  const parsed = BigInt(normalized);
  return parsed <= MAX_OUTBOX_EVENT_ID ? parsed : null;
}
