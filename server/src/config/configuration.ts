import { registerAs } from '@nestjs/config';

export interface AppConfig {
  nodeEnv: string;
  port: number;
  apiPrefix: string;
  corsOrigins: string[];
  databaseUrl: string;
  jwt: {
    accessSecret: string;
    refreshSecret: string;
    accessTtl: number;
    refreshTtl: number;
  };
  throttle: {
    ttl: number;
    limit: number;
    authTtl: number;
    authLimit: number;
  };
  match: {
    turnTimeoutMs: number;
    disconnectGraceMs: number;
  };
  matchmaking: {
    /** How long a queue ticket waits for a real opponent before AI fallback. */
    timeoutMs: number;
    /** Delay before the server drives an AI move (visual breathing room). */
    aiMoveDelayMs: number;
  };
  coins: {
    registrationBonus: number;
    dailyLoginBonus: number;
    rewardedAdBonus: number;
    rewardedAdStandard: number;
  };
  ads: {
    provider: string;
    rewardedUnitId: string;
    interstitialUnitId: string;
    sessionTtlSeconds: number;
    interstitialAfterWins: number;
    interstitialAfterLosses: number;
    interstitialCooldownMatches: number;
  };
  social: {
    challengeTtlSeconds: number;
    challengeCreatePerHour: number;
    challengePendingLimit: number;
    friendRequestPerHour: number;
    friendPendingLimit: number;
  };
  cosmetics: {
    /** Development-only cosmetic grants. Always false in production. */
    devGrantsEnabled: boolean;
  };
  iap: {
    /**
     * Development-only store simulator. Forced off in production —
     * purchases then require real Google Play Developer API verification.
     */
    devStore: boolean;
    /** Android package name used in Play Developer API verification. */
    packageName: string;
    /** Service-account JSON (inline text or file path) for the Play API. */
    serviceAccount: string;
    /** Pub/Sub push audience; when set, RTDN pushes must verify as Google. */
    rtdnAudience: string;
    /** Fixture prices for the dev store simulator only (never shipped). */
    devPrices: Record<string, string>;
  };
  logLevel: string;
}

export default registerAs<AppConfig>('app', () => {
  const num = (value: string | undefined, fallback: number): number => {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  };
  const bool = (value: string | undefined, fallback: boolean): boolean => {
    if (value === undefined || value === '') return fallback;
    return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
  };

  return {
    nodeEnv: process.env.NODE_ENV ?? 'development',
    port: num(process.env.PORT, 3000),
    apiPrefix: process.env.API_PREFIX ?? 'api/v1',
    corsOrigins: (process.env.CORS_ORIGINS ?? '').split(',').filter(Boolean),
    databaseUrl: process.env.DATABASE_URL ?? '',
    jwt: {
      accessSecret: process.env.JWT_ACCESS_SECRET ?? '',
      refreshSecret: process.env.JWT_REFRESH_SECRET ?? '',
      accessTtl: num(process.env.JWT_ACCESS_TTL, 900),
      refreshTtl: num(process.env.JWT_REFRESH_TTL, 2592000),
    },
    throttle: {
      ttl: num(process.env.THROTTLE_TTL, 60),
      limit: num(process.env.THROTTLE_LIMIT, 100),
      authTtl: num(process.env.AUTH_THROTTLE_TTL, 60),
      authLimit: num(process.env.AUTH_THROTTLE_LIMIT, 10),
    },
    match: {
      turnTimeoutMs: num(process.env.MATCH_TURN_TIMEOUT_MS, 60_000),
      disconnectGraceMs: num(process.env.MATCH_DISCONNECT_GRACE_MS, 30_000),
    },
    matchmaking: {
      timeoutMs: num(process.env.MATCHMAKING_TIMEOUT_MS, 8_000),
      aiMoveDelayMs: num(process.env.MATCHMAKING_AI_MOVE_DELAY_MS, 1_200),
    },
    coins: {
      registrationBonus: num(process.env.COINS_REGISTRATION_BONUS, 1000),
      dailyLoginBonus: num(process.env.COINS_DAILY_LOGIN_BONUS, 100),
      rewardedAdBonus: num(process.env.COINS_REWARDED_AD_BONUS, 500),
      rewardedAdStandard: num(process.env.COINS_REWARDED_AD_STANDARD, 100),
    },
    ads: {
      provider: process.env.ADS_PROVIDER ?? 'stub',
      rewardedUnitId: process.env.ADS_REWARDED_UNIT_ID ?? '',
      interstitialUnitId: process.env.ADS_INTERSTITIAL_UNIT_ID ?? '',
      sessionTtlSeconds: num(process.env.ADS_SESSION_TTL_SECONDS, 300),
      interstitialAfterWins: num(process.env.ADS_INTERSTITIAL_AFTER_WINS, 3),
      interstitialAfterLosses: num(process.env.ADS_INTERSTITIAL_AFTER_LOSSES, 5),
      interstitialCooldownMatches: num(process.env.ADS_INTERSTITIAL_COOLDOWN_MATCHES, 2),
    },
    social: {
      challengeTtlSeconds: num(process.env.CHALLENGE_TTL_SECONDS, 900),
      challengeCreatePerHour: num(process.env.CHALLENGE_CREATE_PER_HOUR, 20),
      challengePendingLimit: num(process.env.CHALLENGE_PENDING_LIMIT, 5),
      friendRequestPerHour: num(process.env.FRIEND_REQUEST_PER_HOUR, 20),
      friendPendingLimit: num(process.env.FRIEND_PENDING_LIMIT, 10),
    },
    cosmetics: {
      // Development-only grants: available outside production unless the
      // env explicitly disables them, and never in production.
      devGrantsEnabled:
        (process.env.NODE_ENV ?? 'development') !== 'production' &&
        bool(process.env.DEV_COSMETIC_GRANTS, true),
    },
    iap: {
      // Dev store simulator: opt-in outside production, structurally
      // impossible in production. Prices below are fixtures for the
      // simulator; the real store (Play Billing / StoreKit) is the only
      // price source in production builds.
      devStore:
        (process.env.NODE_ENV ?? 'development') !== 'production' &&
        bool(process.env.IAP_DEV_STORE, false),
      packageName:
        process.env.GOOGLE_PLAY_PACKAGE_NAME ?? 'com.aatamgt',
      serviceAccount: process.env.GOOGLE_PLAY_SERVICE_ACCOUNT ?? '',
      rtdnAudience: process.env.GOOGLE_PUBSUB_AUDIENCE ?? '',
      devPrices: (() => {
        const fallback: Record<string, string> = {
          'com.aatamgt.coins_100': '₹10',
          'com.aatamgt.coins_1000': '₹90',
          'com.aatamgt.coins_5500': '₹450',
          'com.aatamgt.coins_12000': '₹900',
          'com.aatamgt.coins_65000': '₹4,500',
          'com.aatamgt.coins_150000': '₹9,000',
          'com.aatamgt.royal_pass': '₹10',
        };
        if (!process.env.IAP_DEV_PRICES) return fallback;
        try {
          return { ...fallback, ...JSON.parse(process.env.IAP_DEV_PRICES) };
        } catch {
          return fallback;
        }
      })(),
    },
    logLevel: process.env.LOG_LEVEL ?? 'info',
  };
});
