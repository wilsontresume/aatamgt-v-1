import { Injectable, NotFoundException } from '@nestjs/common';
import { Game, Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';

export interface CreateGameDto {
  key: string;
  name: string;
  slug: string;
  description?: string;
  minPlayers?: number;
  maxPlayers?: number;
  rulesVersion?: number;
}

export interface UpdateGameDto {
  name?: string;
  description?: string;
  status?: Game['status'];
  minPlayers?: number;
  maxPlayers?: number;
  rulesVersion?: number;
  displayOrder?: number;
  /** Visual board theme (colors + asset ids). Never geometry or rules. */
  boardTheme?: Record<string, unknown> | null;
}

const BOARD_THEME_KEYS = new Set([
  'backgroundAssetId',
  'textureAssetId',
  'pieceAssetId',
  'surfaceColor',
  'borderColor',
  'accentColor',
]);

/** Keeps only known visual keys; asset ids/colors are validated deeper. */
export function sanitizeBoardTheme(raw: unknown): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (!raw || typeof raw !== 'object') return out;
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (!BOARD_THEME_KEYS.has(key)) continue;
    if (value === null) {
      out[key] = null;
    } else if (typeof value === 'string' && value.length <= 64) {
      out[key] = value;
    }
  }
  return out;
}

@Injectable()
export class GamesService {
  constructor(private readonly prisma: PrismaService) {}

  list(includeInactive = false): Promise<Game[]> {
    return this.prisma.game.findMany({
      where: includeInactive ? {} : { status: 'ACTIVE' },
      orderBy: [{ displayOrder: 'asc' }, { name: 'asc' }],
    });
  }

  async getByKey(key: string): Promise<Game> {
    const game = await this.prisma.game.findUnique({ where: { key } });
    if (!game) throw new NotFoundException('Game not found');
    return game;
  }

  create(dto: CreateGameDto): Promise<Game> {
    return this.prisma.game.create({
      data: {
        key: dto.key,
        name: dto.name,
        slug: dto.slug,
        description: dto.description,
        minPlayers: dto.minPlayers ?? 2,
        maxPlayers: dto.maxPlayers ?? 2,
        rulesVersion: dto.rulesVersion ?? 1,
      },
    });
  }

  async update(key: string, dto: UpdateGameDto): Promise<Game> {
    const existing = await this.getByKey(key);
    const data: Prisma.GameUpdateInput = {};
    if (dto.name !== undefined) data.name = dto.name;
    if (dto.description !== undefined) data.description = dto.description;
    if (dto.status !== undefined) data.status = dto.status;
    if (dto.minPlayers !== undefined) data.minPlayers = dto.minPlayers;
    if (dto.maxPlayers !== undefined) data.maxPlayers = dto.maxPlayers;
    if (dto.rulesVersion !== undefined) data.rulesVersion = dto.rulesVersion;
    if (dto.displayOrder !== undefined) data.displayOrder = dto.displayOrder;
    if (dto.boardTheme !== undefined) {
      const previous = (existing.config as Record<string, unknown> | null) ?? {};
      const merged = { ...previous };
      if (dto.boardTheme === null) delete merged.boardTheme;
      else merged.boardTheme = sanitizeBoardTheme(dto.boardTheme);
      data.config = merged as unknown as Prisma.InputJsonValue;
    }
    return this.prisma.game.update({ where: { key }, data });
  }

  serialize(game: Game) {
    const config = (game.config as Record<string, unknown> | null) ?? {};
    return {
      id: game.id,
      key: game.key,
      name: game.name,
      slug: game.slug,
      description: game.description,
      minPlayers: game.minPlayers,
      maxPlayers: game.maxPlayers,
      status: game.status,
      rulesVersion: game.rulesVersion,
      requiresAuthoritativeState: game.requiresAuthoritativeState,
      displayOrder: game.displayOrder,
      boardTheme: config.boardTheme ?? null,
    };
  }
}
