import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { createPgPool } from './infra/postgres-media.ts';

type Migration = Readonly<{
  id: string;
  sql: string;
  checksum: string;
}>;

const MIGRATIONS_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS schema_migrations (
  id text PRIMARY KEY,
  checksum text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
)
`;

export async function runMigrations(env: NodeJS.ProcessEnv = process.env) {
  const databaseUrl = required(env, 'DATABASE_URL');
  const pool = createPgPool(databaseUrl);
  try {
    const migrations = await loadMigrations();
    await pool.query(MIGRATIONS_TABLE_SQL);

    for (const migration of migrations) {
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        const existing = await client.query(
          'SELECT checksum FROM schema_migrations WHERE id = $1 FOR UPDATE',
          [migration.id],
        );
        if (existing.rowCount === 1) {
          if (existing.rows[0].checksum !== migration.checksum) {
            throw new Error(`migration_checksum_mismatch:${migration.id}`);
          }
          await client.query('COMMIT');
          continue;
        }

        await client.query(transactionBody(migration.sql));
        await client.query(
          'INSERT INTO schema_migrations(id, checksum) VALUES ($1, $2)',
          [migration.id, migration.checksum],
        );
        await client.query('COMMIT');
        console.log(JSON.stringify({ level: 'info', event: 'migration_applied', id: migration.id }));
      } catch (error) {
        await client.query('ROLLBACK').catch(() => undefined);
        throw error;
      } finally {
        client.release();
      }
    }
  } finally {
    await pool.end();
  }
}

export async function loadMigrations() {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'migrations');
  const filenames = (await readdir(root))
    .filter((filename) => /^\d+_.+\.sql$/.test(filename))
    .sort();

  const migrations: Migration[] = [];
  for (const id of filenames) {
    const sql = await readFile(path.join(root, id), 'utf8');
    migrations.push({
      id,
      sql,
      checksum: createHash('sha256').update(sql).digest('hex'),
    });
  }
  return migrations;
}

function required(env: NodeJS.ProcessEnv, name: string) {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name}_required`);
  return value;
}

function transactionBody(sql: string) {
  const trimmed = sql.trim();
  const match = /^BEGIN;\s*([\s\S]*?)\s*COMMIT;$/i.exec(trimmed);
  return match ? match[1] : sql;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await runMigrations();
}
