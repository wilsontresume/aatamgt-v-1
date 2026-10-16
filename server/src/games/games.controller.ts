import { Body, Controller, Get, Param, Patch, Post } from '@nestjs/common';
import {
  IsInt,
  IsObject,
  IsIn,
  IsOptional,
  IsString,
  Matches,
  Max,
  MaxLength,
  Min,
  MinLength,
} from 'class-validator';
import { GamesService, CreateGameDto, UpdateGameDto } from './games.service';
import { Public } from '../common/decorators/public.decorator';
import { Roles } from '../common/decorators/roles.decorator';

class CreateGameBody implements CreateGameDto {
  @IsString()
  @Matches(/^[a-z0-9-]{3,64}$/)
  key: string;

  @IsString()
  @MinLength(2)
  @MaxLength(80)
  name: string;

  @IsString()
  @Matches(/^[a-z0-9-]{3,80}$/)
  slug: string;

  @IsOptional()
  @IsString()
  @MaxLength(2000)
  description?: string;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(8)
  minPlayers?: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(8)
  maxPlayers?: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(1000)
  rulesVersion?: number;
}

class UpdateGameBody implements UpdateGameDto {
  @IsOptional()
  @IsString()
  @MinLength(2)
  @MaxLength(80)
  name?: string;

  @IsOptional()
  @IsString()
  @MaxLength(2000)
  description?: string;

  @IsOptional()
  @IsIn(['ACTIVE', 'MAINTENANCE', 'DISABLED'])
  status?: UpdateGameDto['status'];

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(8)
  minPlayers?: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(8)
  maxPlayers?: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(1000)
  rulesVersion?: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(1000)
  displayOrder?: number;

  // Visual-only board theme: { backgroundAssetId, textureAssetId,
  // pieceAssetId, surfaceColor, borderColor, accentColor }. Keys are
  // whitelisted in GamesService; geometry and rules are never affected.
  @IsOptional()
  @IsObject()
  boardTheme?: Record<string, unknown> | null;
}

@Controller('games')
export class GamesController {
  constructor(private readonly games: GamesService) {}

  @Public()
  @Get()
  async list() {
    const games = await this.games.list();
    return { items: games.map((g) => this.games.serialize(g)) };
  }

  /** Staff list including MAINTENANCE/DISABLED games. */
  @Roles('MODERATOR', 'ADMIN')
  @Get('admin')
  async adminList() {
    const games = await this.games.list(true);
    return { items: games.map((g) => this.games.serialize(g)) };
  }

  @Public()
  @Get(':key')
  async get(@Param('key') key: string) {
    return this.games.serialize(await this.games.getByKey(key));
  }

  @Roles('ADMIN')
  @Post()
  async create(@Body() dto: CreateGameBody) {
    return this.games.serialize(await this.games.create(dto));
  }

  @Roles('ADMIN')
  @Patch(':key')
  async update(@Param('key') key: string, @Body() dto: UpdateGameBody) {
    return this.games.serialize(await this.games.update(key, dto));
  }
}
