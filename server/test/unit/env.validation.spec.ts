import { validate } from '../../src/config/env.validation';

const validEnv = (): Record<string, unknown> => ({
  NODE_ENV: 'test',
  PORT: '4000',
  API_PREFIX: 'api/v1',
  DATABASE_URL: 'mysql://user:pass@localhost:3306/db',
  JWT_ACCESS_SECRET: 'a'.repeat(32),
  JWT_REFRESH_SECRET: 'b'.repeat(32),
  JWT_ACCESS_TTL: '900',
  JWT_REFRESH_TTL: '2592000',
  LOG_LEVEL: 'silent',
});

describe('env validation', () => {
  it('accepts a valid environment and applies defaults', () => {
    const cfg = validate(validEnv());
    expect(cfg.PORT).toBe(4000);
    expect(cfg.THROTTLE_LIMIT).toBe(100);
    expect(cfg.THROTTLE_TTL).toBe(60);
    expect(cfg.AUTH_THROTTLE_LIMIT).toBe(10);
    expect(cfg.CORS_ORIGINS).toBe('http://localhost:5173');
  });

  it('rejects an unknown NODE_ENV', () => {
    expect(() => validate({ ...validEnv(), NODE_ENV: 'staging' })).toThrow(
      /Invalid environment configuration/,
    );
  });

  it('rejects a short JWT secret', () => {
    expect(() => validate({ ...validEnv(), JWT_ACCESS_SECRET: 'short' })).toThrow(
      /JWT_ACCESS_SECRET/,
    );
  });

  it('rejects an unknown log level', () => {
    expect(() => validate({ ...validEnv(), LOG_LEVEL: 'verbose' })).toThrow(/LOG_LEVEL/);
  });

  it('coerces numeric strings to numbers', () => {
    const cfg = validate({ ...validEnv(), THROTTLE_LIMIT: '42' });
    expect(cfg.THROTTLE_LIMIT).toBe(42);
    expect(typeof cfg.THROTTLE_LIMIT).toBe('number');
  });
});
