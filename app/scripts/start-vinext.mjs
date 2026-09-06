import { startProdServer } from 'vinext/server/prod-server';

const port = Number.parseInt(process.env.PORT || '3000', 10);
const host = process.env.HOST || '0.0.0.0';
const shutdownTimeoutMs = Number.parseInt(process.env.SHUTDOWN_TIMEOUT_MS || '25000', 10);

const { server } = await startProdServer({ port, host });

let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(JSON.stringify({ level: 'info', event: 'frontend_shutdown', signal }));

  const timeout = setTimeout(() => {
    console.error(JSON.stringify({ level: 'error', event: 'frontend_shutdown_timeout' }));
    process.exit(1);
  }, Number.isFinite(shutdownTimeoutMs) ? shutdownTimeoutMs : 25_000);
  timeout.unref();

  server.close((error) => {
    clearTimeout(timeout);
    if (error) {
      console.error(JSON.stringify({ level: 'error', event: 'frontend_shutdown_failed', code: error.message }));
      process.exit(1);
    }
    process.exit(0);
  });
}

process.once('SIGINT', () => shutdown('SIGINT'));
process.once('SIGTERM', () => shutdown('SIGTERM'));
