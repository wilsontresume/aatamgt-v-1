import { IsIn, IsInt, IsOptional, IsString, Min, MinLength, validateSync } from 'class-validator';

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

  @IsOptional()
  @IsInt()
  MATCH_TURN_TIMEOUT_MS: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  MATCH_DISCONNECT_GRACE_MS: number;

  @IsOptional()
  @IsInt()
  @Min(500)
  MATCHMAKING_TIMEOUT_MS: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  MATCHMAKING_AI_MOVE_DELAY_MS: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  COINS_REGISTRATION_BONUS: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  COINS_DAILY_LOGIN_BONUS: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  COINS_REWARDED_AD_BONUS: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  COINS_REWARDED_AD_STANDARD: number;

  @IsOptional()
  @IsIn(['stub', 'admob', 'unity_ads'])
  ADS_PROVIDER: string;

  @IsOptional()
  @IsString()
  ADS_REWARDED_UNIT_ID: string;

  @IsOptional()
  @IsString()
  ADS_INTERSTITIAL_UNIT_ID: string;

  @IsOptional()
  @IsInt()
  @Min(1)
  ADS_SESSION_TTL_SECONDS: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  ADS_INTERSTITIAL_AFTER_WINS: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  ADS_INTERSTITIAL_AFTER_LOSSES: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  ADS_INTERSTITIAL_COOLDOWN_MATCHES: number;

  @IsOptional()
  @IsInt()
  @Min(30)
  CHALLENGE_TTL_SECONDS: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  CHALLENGE_CREATE_PER_HOUR: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  CHALLENGE_PENDING_LIMIT: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  FRIEND_REQUEST_PER_HOUR: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  FRIEND_PENDING_LIMIT: number;

  @IsOptional()
  @IsString()
  DEV_COSMETIC_GRANTS?: string;

  @IsOptional()
  @IsString()
  IAP_DEV_STORE?: string;

  @IsOptional()
  @IsString()
  IAP_DEV_PRICES?: string;

  @IsOptional()
  @IsString()
  GOOGLE_PLAY_PACKAGE_NAME?: string;

  @IsOptional()
  @IsString()
  GOOGLE_PLAY_SERVICE_ACCOUNT?: string;

  @IsOptional()
  @IsString()
  GOOGLE_PUBSUB_AUDIENCE?: string;
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
    MATCH_TURN_TIMEOUT_MS: toNumber(config.MATCH_TURN_TIMEOUT_MS, 60_000),
    MATCH_DISCONNECT_GRACE_MS: toNumber(config.MATCH_DISCONNECT_GRACE_MS, 30_000),
    MATCHMAKING_TIMEOUT_MS: toNumber(config.MATCHMAKING_TIMEOUT_MS, 8_000),
    MATCHMAKING_AI_MOVE_DELAY_MS: toNumber(config.MATCHMAKING_AI_MOVE_DELAY_MS, 1_200),
    COINS_REGISTRATION_BONUS: toNumber(config.COINS_REGISTRATION_BONUS, 1000),
    COINS_DAILY_LOGIN_BONUS: toNumber(config.COINS_DAILY_LOGIN_BONUS, 100),
    COINS_REWARDED_AD_BONUS: toNumber(config.COINS_REWARDED_AD_BONUS, 500),
    COINS_REWARDED_AD_STANDARD: toNumber(config.COINS_REWARDED_AD_STANDARD, 100),
    ADS_SESSION_TTL_SECONDS: toNumber(config.ADS_SESSION_TTL_SECONDS, 300),
    ADS_INTERSTITIAL_AFTER_WINS: toNumber(config.ADS_INTERSTITIAL_AFTER_WINS, 3),
    ADS_INTERSTITIAL_AFTER_LOSSES: toNumber(config.ADS_INTERSTITIAL_AFTER_LOSSES, 5),
    ADS_INTERSTITIAL_COOLDOWN_MATCHES: toNumber(config.ADS_INTERSTITIAL_COOLDOWN_MATCHES, 2),
    CHALLENGE_TTL_SECONDS: toNumber(config.CHALLENGE_TTL_SECONDS, 900),
    CHALLENGE_CREATE_PER_HOUR: toNumber(config.CHALLENGE_CREATE_PER_HOUR, 20),
    CHALLENGE_PENDING_LIMIT: toNumber(config.CHALLENGE_PENDING_LIMIT, 5),
    FRIEND_REQUEST_PER_HOUR: toNumber(config.FRIEND_REQUEST_PER_HOUR, 20),
    FRIEND_PENDING_LIMIT: toNumber(config.FRIEND_PENDING_LIMIT, 10),
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
