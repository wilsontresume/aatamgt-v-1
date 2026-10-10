import { Body, Controller, Get, Param, Patch, Post, Put, Query } from '@nestjs/common';
import {
  ArrayMaxSize,
  IsArray,
  IsBoolean,
  IsDefined,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  Matches,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';
import { AdminService, CompleteMatchInput } from './admin.service';
import { Roles } from '../common/decorators/roles.decorator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { PaginationQuery } from '../common/dto/pagination.query';

const COSMETIC_CATEGORIES = [
  'BOARD_SKIN',
  'PROFILE_PICTURE',
  'PROFILE_FRAME',
  'VICTORY_ANIMATION',
  'CAPTURE_ANIMATION',
] as const;

const WALLET_TX_TYPES = [
  'REGISTRATION_BONUS',
  'DAILY_LOGIN',
  'REWARDED_AD',
  'MATCH_REWARD',
  'PURCHASE',
  'COSMETIC_PURCHASE',
  'ROYAL_PASS_BONUS',
  'ADMIN_ADJUSTMENT',
] as const;

class UserStatusBody {
  @IsIn(['ACTIVE', 'SUSPENDED', 'BANNED'])
  status: 'ACTIVE' | 'SUSPENDED' | 'BANNED';

  @IsOptional()
  @IsString()
  @MaxLength(255)
  reason?: string;
}

class PlayerResultBody {
  @IsString()
  userId: string;

  @IsIn(['WIN', 'LOSS', 'DRAW', 'ABANDONED'])
  result: 'WIN' | 'LOSS' | 'DRAW' | 'ABANDONED';

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  score?: number;
}

class FinalizeMatchBody implements CompleteMatchInput {
  @IsIn(['COMPLETED', 'ABANDONED', 'CANCELLED', 'PAUSED', 'ACTIVE'])
  status: CompleteMatchInput['status'];

  @IsOptional()
  @IsArray()
  @Type(() => PlayerResultBody)
  players?: PlayerResultBody[];

  @IsOptional()
  @IsString()
  @MaxLength(255)
  reason?: string;
}

class AdjustWalletBody {
  @Type(() => Number)
  @IsInt()
  @Min(-1_000_000)
  @Max(1_000_000)
  amount: number;

  @IsOptional()
  @IsString()
  @MaxLength(255)
  memo?: string;
}

class AdminListQuery extends PaginationQuery {
  @IsOptional()
  @IsString()
  q?: string;

  @IsOptional()
  @IsIn(['PENDING', 'ACTIVE', 'PAUSED', 'COMPLETED', 'ABANDONED', 'CANCELLED'])
  status?: string;
}

class EconomyQuery extends PaginationQuery {
  @IsOptional()
  @IsString()
  userId?: string;

  @IsOptional()
  @IsIn([...WALLET_TX_TYPES])
  type?: string;
}

class CosmeticsQuery extends PaginationQuery {
  @IsOptional()
  @IsIn([...COSMETIC_CATEGORIES])
  category?: string;
}

class CosmeticPatchBody {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  @Max(100_000)
  price?: number;

  @IsOptional()
  @IsBoolean()
  active?: boolean;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  name?: string;
}

class ConfigEntryDto {
  @IsString()
  @Matches(/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/)
  key: string;

  @IsDefined()
  value: unknown;
}

class SaveConfigBody {
  @IsArray()
  @ArrayMaxSize(64)
  @ValidateNested({ each: true })
  @Type(() => ConfigEntryDto)
  entries: ConfigEntryDto[];
}

@Controller('admin')
export class AdminController {
  constructor(private readonly admin: AdminService) {}

  @Roles('MODERATOR', 'ADMIN')
  @Get('stats')
  stats() {
    return this.admin.stats();
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('users')
  users(@Query() query: AdminListQuery) {
    return this.admin.users(query);
  }

  @Roles('ADMIN')
  @Patch('users/:id/status')
  status(@CurrentUser() actor: AuthUser, @Param('id') id: string, @Body() dto: UserStatusBody) {
    return this.admin.setUserStatus(actor.id, id, dto.status, dto.reason);
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('matches')
  matches(@Query() query: AdminListQuery) {
    return this.admin.matches(query);
  }

  @Roles('ADMIN')
  @Patch('matches/:id/finalize')
  finalize(
    @CurrentUser() actor: AuthUser,
    @Param('id') id: string,
    @Body() dto: FinalizeMatchBody,
  ) {
    return this.admin.finalizeMatch(actor.id, id, dto);
  }

  @Roles('ADMIN')
  @Post('wallets/:userId/adjust')
  adjust(
    @CurrentUser() actor: AuthUser,
    @Param('userId') userId: string,
    @Body() dto: AdjustWalletBody,
  ) {
    return this.admin.adjustWallet(actor.id, userId, dto.amount, dto.memo);
  }

  // --- Phase 15: dashboard ---------------------------------------------------

  @Roles('MODERATOR', 'ADMIN')
  @Get('users/:id')
  player(@Param('id') id: string) {
    return this.admin.player(id);
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('users/:id/wallet')
  playerWallet(@Param('id') id: string, @Query() query: PaginationQuery) {
    return this.admin.playerWallet(id, query);
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('users/:id/matches')
  playerMatches(@Param('id') id: string, @Query() query: PaginationQuery) {
    return this.admin.playerMatches(id, query);
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('economy/summary')
  economySummary() {
    return this.admin.economySummary();
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('economy/transactions')
  economyTransactions(@Query() query: EconomyQuery) {
    return this.admin.economyTransactions(query);
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('economy/ads')
  economyAdShows(@Query() query: PaginationQuery) {
    return this.admin.economyAdShows(query);
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('economy/purchases')
  economyPurchases(@Query() query: PaginationQuery) {
    return this.admin.economyPurchases(query);
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('cosmetics')
  cosmetics(@Query() query: CosmeticsQuery) {
    return this.admin.cosmetics(query);
  }

  @Roles('ADMIN')
  @Patch('cosmetics/:id')
  updateCosmetic(
    @CurrentUser() actor: AuthUser,
    @Param('id') id: string,
    @Body() dto: CosmeticPatchBody,
  ) {
    return this.admin.updateCosmetic(actor.id, id, dto);
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('config')
  config() {
    return this.admin.configEntries();
  }

  @Roles('ADMIN')
  @Put('config')
  saveConfig(@CurrentUser() actor: AuthUser, @Body() dto: SaveConfigBody) {
    return this.admin.saveConfig(actor.id, dto.entries);
  }

  @Roles('ADMIN')
  @Get('audit')
  audit(@Query() query: PaginationQuery) {
    return this.admin.auditLog(query);
  }
}
