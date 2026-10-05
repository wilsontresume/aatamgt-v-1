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
}

@Injectable()
export class GamesService {
  constructor(private readonly prisma: PrismaService) {}

  list(includeInactive = false): Promise<Game[]> {
    return this.prisma.game.findMany({
      where: includeInactive ? {} : { status: 'ACTIVE' },
      orderBy: { name: 'asc' },
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
    await this.getByKey(key);
    const data: Prisma.GameUpdateInput = {};
    if (dto.name !== undefined) data.name = dto.name;
    if (dto.description !== undefined) data.description = dto.description;
    if (dto.status !== undefined) data.status = dto.status;
    if (dto.minPlayers !== undefined) data.minPlayers = dto.minPlayers;
    if (dto.maxPlayers !== undefined) data.maxPlayers = dto.maxPlayers;
    if (dto.rulesVersion !== undefined) data.rulesVersion = dto.rulesVersion;
    return this.prisma.game.update({ where: { key }, data });
  }

  serialize(game: Game) {
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
    };
  }
}
