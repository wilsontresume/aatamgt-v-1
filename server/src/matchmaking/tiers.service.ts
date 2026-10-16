import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { Tier } from '@prisma/client';

export interface GameTier {
  id: string;
  label: string;
  costCoins: number;
  rewardMultiplierBp: number;
  minBalance: number;
  rewardCoins: number;
  description: string | null;
  color: string | null;
  artAssetId: string | null;
  displayOrder: number;
  active: boolean;
  gameKey: string | null;
}

function toGameTier(row: Tier): GameTier {
  const costCoins = Math.max(0, row.entryCostCoins);
  const multBp = Math.max(10_000, row.rewardMultiplierBp);
  return {
    id: row.id,
    label: row.name,
    costCoins,
    rewardMultiplierBp: multBp,
    minBalance: costCoins,
    rewardCoins: Math.floor((costCoins * multBp) / 10_000),
    description: row.description,
    color: row.displayColor,
    artAssetId: row.artAssetId,
    displayOrder: row.displayOrder,
    active: row.active,
    gameKey: row.gameKey,
  };
}

const HEX_COLOR = /^#[0-9a-fA-F]{6}$/;

/**
 * DB-backed virtual-coin tiers. Active tiers are served to players via
 * GET /tiers; admins manage them through /admin/tiers. Game association
 * is validated at queue/challenge time (active + gameKey match or null).
 */
@Injectable()
export class TiersService {
  constructor(private readonly prisma: PrismaService) {}

  private async validateDisplayFields(input: {
    displayColor?: string | null;
    artAssetId?: string | null;
  }): Promise<void> {
    if (input.displayColor != null && !HEX_COLOR.test(input.displayColor)) {
      throw new BadRequestException('displayColor must be a #rrggbb color');
    }
    if (input.artAssetId != null && input.artAssetId !== '') {
      const asset = await this.prisma.gameAsset.findUnique({
        where: { id: input.artAssetId },
      });
      if (!asset || asset.type !== 'TIER_ART') {
        throw new BadRequestException('artAssetId must reference a TIER_ART asset');
      }
    }
  }

  /** Active tiers for the game-entry screen, ordered by displayOrder. */
  async list(gameKey?: string): Promise<GameTier[]> {
    const where = {
      active: true,
      ...(gameKey ? { OR: [{ gameKey: null }, { gameKey }] } : {}),
    };
    const rows = await this.prisma.tier.findMany({
      where,
      orderBy: { displayOrder: 'asc' },
    });
    return rows.map(toGameTier);
  }

  async byId(id: string): Promise<GameTier | null> {
    const row = await this.prisma.tier.findUnique({ where: { id } });
    return row ? toGameTier(row) : null;
  }

  /** Returns null when unknown, inactive, or gameKey mismatch. */
  async activeForGame(id: string, gameKey: string): Promise<GameTier | null> {
    const row = await this.prisma.tier.findUnique({ where: { id } });
    if (!row || !row.active) return null;
    if (row.gameKey !== null && row.gameKey !== gameKey) return null;
    return toGameTier(row);
  }

  async requireActiveForGame(id: string, gameKey: string): Promise<GameTier> {
    const tier = await this.activeForGame(id, gameKey);
    if (!tier) throw new BadRequestException('Unknown or inactive tier');
    return tier;
  }

  // --- Admin CRUD ----------------------------------------------------------

  async adminList(): Promise<Tier[]> {
    return this.prisma.tier.findMany({ orderBy: { displayOrder: 'asc' } });
  }

  async adminGet(id: string): Promise<Tier> {
    const row = await this.prisma.tier.findUnique({ where: { id } });
    if (!row) throw new NotFoundException('Tier not found');
    return row;
  }

  async adminCreate(input: {
    id: string;
    name: string;
    gameKey?: string | null;
    description?: string | null;
    displayColor?: string | null;
    artAssetId?: string | null;
    entryCostCoins: number;
    rewardMultiplierBp: number;
    displayOrder: number;
    active?: boolean;
  }): Promise<Tier> {
    await this.validateDisplayFields(input);
    return this.prisma.tier.create({
      data: {
        id: input.id,
        name: input.name,
        gameKey: input.gameKey ?? null,
        description: input.description ?? null,
        displayColor: input.displayColor ?? null,
        artAssetId: input.artAssetId ?? null,
        entryCostCoins: input.entryCostCoins,
        rewardMultiplierBp: input.rewardMultiplierBp,
        displayOrder: input.displayOrder,
        active: input.active ?? true,
      },
    });
  }

  async adminUpdate(
    id: string,
    patch: Partial<{
      name: string;
      gameKey: string | null;
      description: string | null;
      displayColor: string | null;
      artAssetId: string | null;
      entryCostCoins: number;
      rewardMultiplierBp: number;
      displayOrder: number;
      active: boolean;
    }>,
  ): Promise<Tier> {
    await this.adminGet(id);
    await this.validateDisplayFields(patch);
    return this.prisma.tier.update({ where: { id }, data: patch });
  }

  async adminSetActive(id: string, active: boolean): Promise<Tier> {
    return this.adminUpdate(id, { active });
  }
}
