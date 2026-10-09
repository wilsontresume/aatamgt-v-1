import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  HttpException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Prisma, WalletTxType } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { AppConfig } from '../config/configuration';
import { CATEGORY_ORDER, CosmeticCategoryKey, DEFAULT_KEY_BY_CATEGORY } from './catalog';

const CATEGORY_RANK = new Map<string, number>(
  CATEGORY_ORDER.map((category, index) => [category, index]),
);

export interface CosmeticItemView {
  key: string;
  category: CosmeticCategoryKey;
  name: string;
  description: string;
  tier: 'FREE' | 'PREMIUM';
  price: number;
  sortOrder: number;
  owned: boolean;
  equipped: boolean;
  source?: string;
}

function isP2002(error: unknown): boolean {
  return (
    error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002'
  );
}

@Injectable()
export class CosmeticsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly wallet: WalletService,
    private readonly config: ConfigService,
  ) {}

  get devGrantsEnabled(): boolean {
    const app = this.config.get<AppConfig>('app') as AppConfig;
    return app.cosmetics.devGrantsEnabled;
  }

  /** Full inventory for one user: defaults ensured, then owned/equipped flags. */
  async list(userId: string): Promise<{ items: CosmeticItemView[]; devGrantsEnabled: boolean }> {
    await this.ensureDefaults(userId);
    const [items, owned] = await Promise.all([
      this.prisma.cosmetic.findMany({
        where: { active: true },
        orderBy: [{ category: 'asc' }, { sortOrder: 'asc' }],
      }),
      this.prisma.userCosmetic.findMany({
        where: { userId },
        include: { cosmetic: { select: { id: true } } },
      }),
    ]);
    const ownership = new Map(
      owned.map((row) => [row.cosmeticId, { equipped: row.equipped, source: row.source }]),
    );
    const views = items.map((item) => {
      const own = ownership.get(item.id);
      return {
        key: item.key,
        category: item.category,
        name: item.name,
        description: item.description ?? '',
        tier: item.tier,
        price: item.price,
        sortOrder: item.sortOrder,
        owned: !!own,
        equipped: own?.equipped ?? false,
        ...(own ? { source: own.source } : {}),
      };
    });
    views.sort((a, b) => {
      const rank = (CATEGORY_RANK.get(a.category) ?? 0) - (CATEGORY_RANK.get(b.category) ?? 0);
      return rank !== 0 ? rank : a.sortOrder - b.sortOrder;
    });
    return { items: views, devGrantsEnabled: this.devGrantsEnabled };
  }

  /**
   * First-run bookkeeping: every active default cosmetic is owned (source
   * "default"), and every category with nothing equipped gets its default
   * equipped. Safe under parallel calls — unique constraints absorb races.
   */
  async ensureDefaults(userId: string): Promise<void> {
    const items = await this.prisma.cosmetic.findMany({
      where: { active: true, grantedByDefault: true },
    });
    if (items.length === 0) return;
    const owned = await this.prisma.userCosmetic.findMany({
      where: { userId },
      include: { cosmetic: { select: { id: true, category: true, key: true } } },
    });
    const ownedIds = new Set(owned.map((row) => row.cosmeticId));

    for (const item of items) {
      if (ownedIds.has(item.id)) continue;
      try {
        await this.prisma.userCosmetic.create({
          data: { userId, cosmeticId: item.id, source: 'default' },
        });
      } catch (error) {
        if (!isP2002(error)) throw error;
      }
    }

    for (const [category, defaultKey] of DEFAULT_KEY_BY_CATEGORY) {
      const equipped = owned.some(
        (row) => row.equipped && row.cosmetic.category === category,
      );
      if (equipped) continue;
      const defaultItem = items.find((item) => item.key === defaultKey);
      if (!defaultItem) continue;
      await this.prisma.userCosmetic.updateMany({
        where: { userId, cosmeticId: defaultItem.id, equipped: false },
        data: { equipped: true },
      });
    }
  }

  /** FREE cosmetics: claim adds them to the inventory. */
  async claim(userId: string, key: string): Promise<{ item: CosmeticItemView }> {
    const item = await this.findActive(key);
    await this.assertNotOwned(userId, item.id);
    if (item.tier === 'PREMIUM') {
      throw new BadRequestException('Premium cosmetics must be purchased with coins.');
    }
    try {
      await this.prisma.userCosmetic.create({
        data: { userId, cosmeticId: item.id, source: 'claim' },
      });
    } catch (error) {
      if (!isP2002(error)) throw error;
      throw new ConflictException('You already own this cosmetic.');
    }
    return { item: this.toView(item, { equipped: false, source: 'claim' }) };
  }

  /**
   * PREMIUM cosmetics: debit coins through the shared wallet (idempotency
   * key per user+item), then record ownership.
   */
  async purchase(
    userId: string,
    key: string,
  ): Promise<{ item: CosmeticItemView; balance: number }> {
    const item = await this.findActive(key);
    if (item.tier === 'FREE') {
      throw new BadRequestException('This cosmetic is free — claim it instead.');
    }
    await this.assertNotOwned(userId, item.id);

    const wallet = await this.wallet.getOrCreate(userId);
    if (wallet.balance < item.price) {
      throw new BadRequestException('Not enough coins.');
    }

    let balance: number;
    try {
      const debit = await this.wallet.debit(userId, item.price, {
        type: WalletTxType.COSMETIC_PURCHASE,
        refType: 'cosmetic',
        refId: item.key,
        idempotencyKey: `cosmetic:${userId}:${key}`,
        memo: `Cosmetic: ${item.name}`,
      });
      balance = debit.wallet.balance;
    } catch (error) {
      if (error instanceof HttpException && error.getStatus() === 422) {
        throw new BadRequestException('Not enough coins.');
      }
      throw error;
    }

    let row = await this.prisma.userCosmetic.findUnique({
      where: { userId_cosmeticId: { userId, cosmeticId: item.id } },
    });
    if (!row) {
      try {
        row = await this.prisma.userCosmetic.create({
          data: { userId, cosmeticId: item.id, source: 'purchase' },
        });
      } catch (error) {
        if (!isP2002(error)) throw error;
        // Concurrent purchase of the same item: ownership already exists.
        row = await this.prisma.userCosmetic.findUnique({
          where: { userId_cosmeticId: { userId, cosmeticId: item.id } },
        });
      }
    }
    if (!row) throw new ConflictException('You already own this cosmetic.');
    return { item: this.toView(item, row), balance };
  }

  /** One equipped cosmetic per category; equipping requires ownership. */
  async equip(userId: string, key: string): Promise<{ item: CosmeticItemView }> {
    const item = await this.findActive(key);
    const row = await this.prisma.userCosmetic.findUnique({
      where: { userId_cosmeticId: { userId, cosmeticId: item.id } },
    });
    if (!row) throw new ForbiddenException('You do not own this cosmetic.');
    if (row.equipped) return { item: this.toView(item, row) };

    await this.prisma.$transaction([
      this.prisma.userCosmetic.updateMany({
        where: {
          userId,
          equipped: true,
          NOT: { cosmeticId: item.id },
          cosmetic: { category: item.category },
        },
        data: { equipped: false },
      }),
      this.prisma.userCosmetic.update({
        where: { id: row.id },
        data: { equipped: true },
      }),
    ]);
    return { item: this.toView(item, { ...row, equipped: true }) };
  }

  /**
   * Development-only grant. Disabled (404) outside development unless the
   * DEV_COSMETIC_GRANTS opt-in; idempotent when the item is already owned.
   */
  async grant(userId: string, key: string): Promise<{ item: CosmeticItemView }> {
    if (!this.devGrantsEnabled) {
      throw new NotFoundException('Cosmetic grants are disabled.');
    }
    const item = await this.findActive(key);
    let row = await this.prisma.userCosmetic.findUnique({
      where: { userId_cosmeticId: { userId, cosmeticId: item.id } },
    });
    if (!row) {
      try {
        row = await this.prisma.userCosmetic.create({
          data: { userId, cosmeticId: item.id, source: 'dev_grant' },
        });
      } catch (error) {
        if (!isP2002(error)) throw error;
        row = await this.prisma.userCosmetic.findUnique({
          where: { userId_cosmeticId: { userId, cosmeticId: item.id } },
        });
      }
    }
    if (!row) throw new ConflictException('You already own this cosmetic.');
    return { item: this.toView(item, row) };
  }

  private async findActive(key: string) {
    const item = await this.prisma.cosmetic.findUnique({ where: { key } });
    if (!item || !item.active) {
      throw new NotFoundException(`Unknown cosmetic: ${key}`);
    }
    return item;
  }

  private async assertNotOwned(userId: string, cosmeticId: string): Promise<void> {
    const existing = await this.prisma.userCosmetic.findUnique({
      where: { userId_cosmeticId: { userId, cosmeticId } },
    });
    if (existing) throw new ConflictException('You already own this cosmetic.');
  }

  private toView(
    item: {
      key: string;
      category: CosmeticCategoryKey;
      name: string;
      description: string | null;
      tier: 'FREE' | 'PREMIUM';
      price: number;
      sortOrder: number;
    },
    ownership: { equipped: boolean; source: string },
  ): CosmeticItemView {
    return {
      key: item.key,
      category: item.category,
      name: item.name,
      description: item.description ?? '',
      tier: item.tier,
      price: item.price,
      sortOrder: item.sortOrder,
      owned: true,
      equipped: ownership.equipped,
      source: ownership.source,
    };
  }
}
