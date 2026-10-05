import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import mysql from 'mysql2/promise';

function loadEnv() {
  const envPath = resolve(process.cwd(), '.env');
  const env = {};
  if (existsSync(envPath)) {
    for (const line of readFileSync(envPath, 'utf8').split('\n')) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eq = trimmed.indexOf('=');
      if (eq === -1) continue;
      env[trimmed.slice(0, eq).trim()] = trimmed.slice(eq + 1).trim();
    }
  }
  return env;
}

function parseUrl(raw) {
  const u = new URL(raw);
  return {
    host: u.hostname,
    port: u.port ? Number(u.port) : 3306,
    user: decodeURIComponent(u.username || 'root'),
    password: decodeURIComponent(u.password || ''),
    database: u.pathname.replace(/^\//, '').split('?')[0],
  };
}

async function ensureDatabase({ url, drop }) {
  const cfg = parseUrl(url);
  if (!cfg.database) throw new Error('Could not parse database name');
  const conn = await mysql.createConnection({
    host: cfg.host,
    port: cfg.port,
    user: cfg.user,
    password: cfg.password,
  });
  try {
    if (drop) {
      await conn.query(`DROP DATABASE IF EXISTS \`${cfg.database}\``);
      console.log(`dropped ${cfg.database}`);
    }
    await conn.query(
      `CREATE DATABASE IF NOT EXISTS \`${cfg.database}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`,
    );
    console.log(`ready ${cfg.database}`);
  } finally {
    await conn.end();
  }
  return cfg.database;
}

function prisma(args, env) {
  execFileSync('npx', ['prisma', ...args], { stdio: 'inherit', env });
}

const env = { ...process.env, ...loadEnv() };
const command = process.argv[2] ?? 'deploy';
const testUrl = env.TEST_DATABASE_URL;
if (!testUrl) {
  console.error('TEST_DATABASE_URL must be set in .env');
  process.exit(1);
}
env.DATABASE_URL = testUrl;

switch (command) {
  case 'prepare':
    await ensureDatabase({ url: testUrl, drop: false });
    break;
  case 'deploy':
    await ensureDatabase({ url: testUrl, drop: false });
    prisma(['migrate', 'deploy'], env);
    break;
  case 'status':
    await ensureDatabase({ url: testUrl, drop: false });
    prisma(['migrate', 'status'], env);
    break;
  case 'reset':
    await ensureDatabase({ url: testUrl, drop: true });
    prisma(['migrate', 'deploy'], env);
    prisma(['migrate', 'status'], env);
    break;
  case 'validate':
    await ensureDatabase({ url: testUrl, drop: true });
    prisma(['migrate', 'deploy'], env);
    prisma(['migrate', 'status'], env);
    console.log('migration validation passed on a fresh database');
    break;
  default:
    console.error(`unknown command: ${command}`);
    process.exit(1);
}
