import { BadRequestException, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { SystemConfig } from '@prisma/client';
import { AppConfig } from './configuration';
import { PrismaService } from '../prisma/prisma.service';

export type ConfigKind = 'int' | 'bool';

export interface ConfigKeySpec {
  key: string;
  label: string;
  kind: ConfigKind;
  min?: number;
  max?: number;
  envDefault: (app: AppConfig) => number | boolean;
}

export interface ConfigEntry {
  key: string;
  label: string;
  kind: ConfigKind;
  min: number | null;
  max: number | null;
  value: number | boolean;
  default: number | boolean;
  overridden: boolean;
}

/** The Phase 15 runtime configuration surface. Every admin-editable key
 *  lives here with its validation bounds and env fallback. */
export const CONFIG_KEYS: ConfigKeySpec[] = [
  {
    key: 'coins.registration_bonus',
    label: 'Registration bonus (coins)',
    kind: 'int',
    min: 0,
    max: 1_000_000,
    envDefault: (app) => app.coins.registrationBonus,
  },
  {
    key: 'coins.daily_reward',
    label: 'Daily reward (coins)',
    kind: 'int',
    min: 0,
    max: 1_000_000,
    envDefault: (app) => app.coins.dailyLoginBonus,
  },
  {
    key: 'ads.rewarded_bonus',
    label: 'Ad reward — bonus tier (coins)',
    kind: 'int',
    min: 0,
    max: 1_000_000,
    envDefault: (app) => app.coins.rewardedAdBonus,
  },
  {
    key: 'ads.rewarded_standard',
    label: 'Ad reward — standard tier (coins)',
    kind: 'int',
    min: 0,
    max: 1_000_000,
    envDefault: (app) => app.coins.rewardedAdStandard,
  },
  {
    key: 'ads.interstitial_after_wins',
    label: 'Interstitial after wins',
    kind: 'int',
    min: 0,
    max: 100,
    envDefault: (app) => app.ads.interstitialAfterWins,
  },
  {
    key: 'ads.interstitial_after_losses',
    label: 'Interstitial after losses',
    kind: 'int',
    min: 0,
    max: 100,
    envDefault: (app) => app.ads.interstitialAfterLosses,
  },
  {
    key: 'ads.interstitial_cooldown_matches',
    label: 'Interstitial cooldown (matches)',
    kind: 'int',
    min: 0,
    max: 100,
    envDefault: (app) => app.ads.interstitialCooldownMatches,
  },
  {
    key: 'shop.royal_pass_days',
    label: 'Royal Pass duration (days)',
    kind: 'int',
    min: 1,
    max: 365,
    envDefault: () => 30,
  },
  {
    key: 'shop.royal_pass_enabled',
    label: 'Royal Pass enabled',
    kind: 'bool',
    envDefault: () => true,
  },
  {
    key: 'admin.wallet_adjust_threshold',
    label: 'Large wallet adjustment threshold (coins)',
    kind: 'int',
    min: 1,
    max: 1_000_000,
    envDefault: () => 100_000,
  },
];

const BY_KEY = new Map(CONFIG_KEYS.map((spec) => [spec.key, spec]));

@Injectable()
export class SystemConfigService {
  private readonly app: AppConfig;

  constructor(
    private readonly prisma: PrismaService,
    config: ConfigService,
  ) {
    this.app = config.get<AppConfig>('app') as AppConfig;
  }

  static specFor(key: string): ConfigKeySpec | undefined {
    return BY_KEY.get(key);
  }

  static isKnownKey(key: string): boolean {
    return BY_KEY.has(key);
  }

  /** Every key with its live value (stored override or env default). */
  async entries(): Promise<ConfigEntry[]> {
    const rows = await this.prisma.systemConfig.findMany();
    const stored = new Map<string, SystemConfig>(rows.map((row) => [row.key, row]));
    return CONFIG_KEYS.map((spec) => {
      const row = stored.get(spec.key);
      const fallback = spec.envDefault(this.app);
      const overridden = row !== undefined && this.matchesKind(spec, row.value);
      return {
        key: spec.key,
        label: spec.label,
        kind: spec.kind,
        min: spec.min ?? null,
        max: spec.max ?? null,
        value: overridden ? (row.value as number | boolean) : fallback,
        default: fallback,
        overridden,
      };
    });
  }

  /** Live integer value: stored override first, env default second. */
  async number(key: string): Promise<number> {
    const spec = this.requireSpec(key, 'int');
    const row = await this.prisma.systemConfig.findUnique({ where: { key } });
    if (row && typeof row.value === 'number') return row.value;
    return spec.envDefault(this.app) as number;
  }

  /** Live boolean value: stored override first, env default second. */
  async boolean(key: string): Promise<boolean> {
    const spec = this.requireSpec(key, 'bool');
    const row = await this.prisma.systemConfig.findUnique({ where: { key } });
    if (row && typeof row.value === 'boolean') return row.value;
    return spec.envDefault(this.app) as boolean;
  }

  /** Validates one entry without writing. Returns the normalized value. */
  validate(key: string, value: unknown): number | boolean {
    const spec = BY_KEY.get(key);
    if (!spec) throw new BadRequestException(`Unknown config key '${key}'`);
    return this.normalize(spec, value);
  }

  /** Validates and stores one override. Throws BadRequest on unknown
   *  keys, wrong kinds and out-of-range values. A value equal to the
   *  current env default removes the row entirely — an override that
   *  matches the default is not an override, and keeping it would
   *  shadow per-app environment configuration. Does not audit — the
   *  admin service records the action. */
  async set(key: string, value: unknown): Promise<void> {
    const normalized = this.validate(key, value);
    const spec = BY_KEY.get(key)!;
    if (normalized === spec.envDefault(this.app)) {
      await this.prisma.systemConfig.deleteMany({ where: { key } });
      return;
    }
    await this.prisma.systemConfig.upsert({
      where: { key },
      create: { key, value: normalized as never },
      update: { value: normalized as never },
    });
  }

  private requireSpec(key: string, kind: ConfigKind): ConfigKeySpec {
    const spec = BY_KEY.get(key);
    if (!spec) throw new BadRequestException(`Unknown config key '${key}'`);
    if (spec.kind !== kind) {
      throw new BadRequestException(`Config key '${key}' is not a ${kind}`);
    }
    return spec;
  }

  private matchesKind(spec: ConfigKeySpec, value: unknown): boolean {
    if (spec.kind === 'int') return typeof value === 'number' && Number.isInteger(value);
    return typeof value === 'boolean';
  }

  private normalize(spec: ConfigKeySpec, value: unknown): number | boolean {
    if (spec.kind === 'bool') {
      if (typeof value !== 'boolean') {
        throw new BadRequestException(`Config key '${spec.key}' expects true or false`);
      }
      return value;
    }
    const num = typeof value === 'string' ? Number(value) : value;
    if (typeof num !== 'number' || !Number.isInteger(num)) {
      throw new BadRequestException(`Config key '${spec.key}' expects an integer`);
    }
    if (spec.min !== undefined && num < spec.min) {
      throw new BadRequestException(`Config key '${spec.key}' must be >= ${spec.min}`);
    }
    if (spec.max !== undefined && num > spec.max) {
      throw new BadRequestException(`Config key '${spec.key}' must be <= ${spec.max}`);
    }
    return num;
  }
}
