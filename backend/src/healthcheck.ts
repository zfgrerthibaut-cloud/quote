import { fileURLToPath } from 'node:url';

import { createPgPool } from './infra/postgres-media.ts';
import { loadMigrations } from './migrate.ts';

const DEFAULT_TIMEOUT_MS = 2_000;

export async function runHealthcheck(mode = process.argv[2] ?? 'api', env: NodeJS.ProcessEnv = process.env) {
  if (mode === 'migrations' || mode === 'indexer') {
    await checkMigrations(env);
    return;
  }
  if (mode !== 'api') throw new Error(`healthcheck_mode_invalid:${mode}`);
  await checkApi(env);
}

async function checkApi(env: NodeJS.ProcessEnv) {
  const port = env.PORT || '8787';
  const url = env.HEALTHCHECK_URL || `http://127.0.0.1:${port}/v1/health`;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs(env));
  try {
    const response = await fetch(url, { cache: 'no-store', signal: controller.signal });
    if (!response.ok) throw new Error(`healthcheck_http_${response.status}`);
    const payload = await response.json() as { status?: unknown };
    if (payload.status !== 'ok') throw new Error('healthcheck_status_not_ok');
  } finally {
    clearTimeout(timeout);
  }
}

async function checkMigrations(env: NodeJS.ProcessEnv) {
  const databaseUrl = required(env, 'DATABASE_URL');
  const migrations = await loadMigrations();
  const latest = migrations.at(-1);
  if (!latest) throw new Error('migrations_empty');

  const pool = createPgPool(databaseUrl);
  try {
    const result = await pool.query(
      `SELECT checksum FROM schema_migrations WHERE id = $1`,
      [latest.id],
    );
    if (result.rowCount !== 1 || result.rows[0].checksum !== latest.checksum) {
      throw new Error(`migration_not_applied:${latest.id}`);
    }
  } finally {
    await pool.end();
  }
}

function timeoutMs(env: NodeJS.ProcessEnv) {
  const value = Number(env.HEALTHCHECK_TIMEOUT_MS || DEFAULT_TIMEOUT_MS);
  return Number.isFinite(value) && value >= 250 && value <= 30_000 ? value : DEFAULT_TIMEOUT_MS;
}

function required(env: NodeJS.ProcessEnv, name: string) {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name}_required`);
  return value;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await runHealthcheck();
}
