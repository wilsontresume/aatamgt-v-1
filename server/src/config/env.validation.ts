import { IsIn, IsInt, IsOptional, IsString, MinLength, validateSync } from 'class-validator';

export class EnvironmentVariables {
  @IsIn(['development', 'test', 'production'])
  NODE_ENV: string;

  @IsInt()
  PORT: number;

  @IsString()
  API_PREFIX: string;

  @IsString()
  @IsOptional()
  CORS_ORIGINS: string;

  @IsString()
  DATABASE_URL: string;

  @IsString()
  @MinLength(16)
  JWT_ACCESS_SECRET: string;

  @IsString()
  @MinLength(16)
  JWT_REFRESH_SECRET: string;

  @IsInt()
  JWT_ACCESS_TTL: number;

  @IsInt()
  JWT_REFRESH_TTL: number;

  @IsInt()
  THROTTLE_TTL: number;

  @IsInt()
  THROTTLE_LIMIT: number;

  @IsInt()
  AUTH_THROTTLE_TTL: number;

  @IsInt()
  AUTH_THROTTLE_LIMIT: number;

  @IsIn(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'])
  LOG_LEVEL: string;
}

const defaults: Record<string, unknown> = {
  NODE_ENV: 'development',
  PORT: 3000,
  API_PREFIX: 'api/v1',
  CORS_ORIGINS: 'http://localhost:5173',
  JWT_ACCESS_TTL: 900,
  JWT_REFRESH_TTL: 2592000,
  THROTTLE_TTL: 60,
  THROTTLE_LIMIT: 100,
  AUTH_THROTTLE_TTL: 60,
  AUTH_THROTTLE_LIMIT: 10,
  LOG_LEVEL: 'info',
};

function toNumber(value: unknown, fallback: number): number {
  if (value === undefined || value === null || value === '') return fallback;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function validate(config: Record<string, unknown>): EnvironmentVariables {
  const merged: Record<string, unknown> = {
    ...defaults,
    ...config,
    PORT: toNumber(config.PORT, 3000),
    JWT_ACCESS_TTL: toNumber(config.JWT_ACCESS_TTL, 900),
    JWT_REFRESH_TTL: toNumber(config.JWT_REFRESH_TTL, 2592000),
    THROTTLE_TTL: toNumber(config.THROTTLE_TTL, 60),
    THROTTLE_LIMIT: toNumber(config.THROTTLE_LIMIT, 100),
    AUTH_THROTTLE_TTL: toNumber(config.AUTH_THROTTLE_TTL, 60),
    AUTH_THROTTLE_LIMIT: toNumber(config.AUTH_THROTTLE_LIMIT, 10),
  };

  const instance = new EnvironmentVariables();
  Object.assign(instance, merged);

  const errors = validateSync(instance);
  if (errors.length > 0) {
    const details = errors
      .map((e) => `${e.property}: ${Object.values(e.constraints ?? {}).join(', ')}`)
      .join('; ');
    throw new Error(`Invalid environment configuration — ${details}`);
  }
  return instance;
}
