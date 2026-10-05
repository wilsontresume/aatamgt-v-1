import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';

/**
 * Prepares the dedicated test database: creates it if missing, applies all
 * migrations and asserts the migration history is fully applied.
 */
export default async function globalSetup(): Promise<void> {
  const root = resolve(__dirname, '..');
  execFileSync(process.execPath, [resolve(root, 'scripts/test-db.mjs'), 'deploy'], {
    cwd: root,
    stdio: 'inherit',
  });
  execFileSync(process.execPath, [resolve(root, 'scripts/test-db.mjs'), 'status'], {
    cwd: root,
    stdio: 'inherit',
  });
}
