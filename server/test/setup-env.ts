import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const envPath = resolve(__dirname, '..', '.env');
if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim();
    if (!(key in process.env)) process.env[key] = value;
  }
}

process.env.NODE_ENV = 'test';
process.env.PORT = '0';
process.env.API_PREFIX = 'api/v1';
process.env.LOG_LEVEL = process.env.TEST_LOG_LEVEL ?? 'silent';
process.env.JWT_ACCESS_SECRET = 'test-access-secret-0123456789abcdefgh';
process.env.JWT_REFRESH_SECRET = 'test-refresh-secret-0123456789abcdefg';
process.env.JWT_ACCESS_TTL = '900';
process.env.JWT_REFRESH_TTL = '2592000';
process.env.THROTTLE_TTL = '60';
process.env.THROTTLE_LIMIT = '1000';
process.env.AUTH_THROTTLE_TTL = '60';
process.env.AUTH_THROTTLE_LIMIT = '20';
process.env.CORS_ORIGINS = 'http://localhost:3000';
// Phase 13: integration specs exercise the purchase pipeline through the
// development store simulator (production forces this off).
process.env.IAP_DEV_STORE = process.env.IAP_DEV_STORE ?? 'true';

const testDatabaseUrl = process.env.TEST_DATABASE_URL;
if (!testDatabaseUrl) {
  throw new Error('TEST_DATABASE_URL must be set for integration tests');
}
process.env.DATABASE_URL = testDatabaseUrl;
