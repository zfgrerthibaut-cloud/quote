const port = process.env.PORT || '3000';
const url = process.env.HEALTHCHECK_URL || `http://127.0.0.1:${port}/`;
const timeoutMs = Number.parseInt(process.env.HEALTHCHECK_TIMEOUT_MS || '2000', 10);
const controller = new AbortController();
const timeout = setTimeout(() => controller.abort(), Number.isFinite(timeoutMs) ? timeoutMs : 2_000);

try {
  const response = await fetch(url, {
    cache: 'no-store',
    redirect: 'manual',
    signal: controller.signal,
  });
  if (response.status < 200 || response.status >= 400) {
    throw new Error(`healthcheck_http_${response.status}`);
  }
} finally {
  clearTimeout(timeout);
}
