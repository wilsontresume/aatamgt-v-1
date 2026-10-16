import { Body, Controller, Get, HttpCode, Param, Patch, Post } from '@nestjs/common';
import {
  IsBoolean,
  IsInt,
  IsOptional,
  IsString,
  Matches,
  Max,
  MaxLength,
  Min,
} from 'class-validator';
import { TiersService } from './tiers.service';
import { Roles } from '../common/decorators/roles.decorator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { AdminService } from '../admin/admin.service';

class CreateTierBody {
  @IsString()
  @Matches(/^[a-z0-9-]{3,64}$/)
  id: string;

  @IsString()
  @MaxLength(64)
  name: string;

  @IsOptional()
  @IsString()
  @Matches(/^[a-z0-9-]{3,64}$/)
  gameKey?: string;

  @IsOptional()
  @IsString()
  @MaxLength(255)
  description?: string;

  @IsOptional()
  @IsString()
  @Matches(/^#[0-9a-fA-F]{6}$/)
  displayColor?: string;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  artAssetId?: string;

  @IsInt()
  @Min(0)
  @Max(1_000_000)
  entryCostCoins: number;

  @IsInt()
  @Min(10_000)
  @Max(1_000_000)
  rewardMultiplierBp: number;

  @IsInt()
  @Min(0)
  @Max(1000)
  displayOrder: number;

  @IsOptional()
  @IsBoolean()
  active?: boolean;
}

class UpdateTierBody {
  @IsOptional()
  @IsString()
  @MaxLength(64)
  name?: string;

  @IsOptional()
  @IsString()
  @Matches(/^[a-z0-9-]{3,64}$/)
  gameKey?: string;

  @IsOptional()
  @IsString()
  @MaxLength(255)
  description?: string;

  @IsOptional()
  @IsString()
  @Matches(/^#[0-9a-fA-F]{6}$/)
  displayColor?: string;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  artAssetId?: string;

  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(1_000_000)
  entryCostCoins?: number;

  @IsOptional()
  @IsInt()
  @Min(10_000)
  @Max(1_000_000)
  rewardMultiplierBp?: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(1000)
  displayOrder?: number;

  @IsOptional()
  @IsBoolean()
  active?: boolean;
}

/**
 * Admin tier management (role-protected). Players use GET /tiers for the
 * active catalog; these routes manage the DB rows backing it.
 */
@Controller('admin/tiers')
export class TiersAdminController {
  constructor(
    private readonly tiers: TiersService,
    private readonly admin: AdminService,
  ) {}

  @Roles('ADMIN')
  @Get()
  list() {
    return this.tiers.adminList();
  }

  @Roles('ADMIN')
  @Get(':id')
  async get(@Param('id') id: string) {
    return this.tiers.adminGet(id);
  }

  @Roles('ADMIN')
  @Post()
  @HttpCode(201)
  async create(@CurrentUser() actor: AuthUser, @Body() dto: CreateTierBody) {
    const tier = await this.tiers.adminCreate({
      id: dto.id,
      name: dto.name,
      gameKey: dto.gameKey ?? null,
      description: dto.description ?? null,
      displayColor: dto.displayColor ?? null,
      artAssetId: dto.artAssetId ?? null,
      entryCostCoins: dto.entryCostCoins,
      rewardMultiplierBp: dto.rewardMultiplierBp,
      displayOrder: dto.displayOrder,
      active: dto.active ?? true,
    });
    await this.admin.audit(actor.id, 'tier.create', 'tier', tier.id, {
      id: tier.id,
      name: tier.name,
      description: tier.description,
      displayColor: tier.displayColor,
      artAssetId: tier.artAssetId,
      entryCostCoins: tier.entryCostCoins,
      rewardMultiplierBp: tier.rewardMultiplierBp,
      displayOrder: tier.displayOrder,
      active: tier.active,
    });
    return tier;
  }

  @Roles('ADMIN')
  @Patch(':id')
  async update(
    @CurrentUser() actor: AuthUser,
    @Param('id') id: string,
    @Body() dto: UpdateTierBody,
  ) {
    const before = await this.tiers.adminGet(id);
    const tier = await this.tiers.adminUpdate(id, dto);
    await this.admin.audit(actor.id, 'tier.update', 'tier', id, {
      before: {
        name: before.name,
        description: before.description,
        displayColor: before.displayColor,
        artAssetId: before.artAssetId,
        entryCostCoins: before.entryCostCoins,
        rewardMultiplierBp: before.rewardMultiplierBp,
        displayOrder: before.displayOrder,
        active: before.active,
      },
      after: {
        name: tier.name,
        description: tier.description,
        displayColor: tier.displayColor,
        artAssetId: tier.artAssetId,
        entryCostCoins: tier.entryCostCoins,
        rewardMultiplierBp: tier.rewardMultiplierBp,
        displayOrder: tier.displayOrder,
        active: tier.active,
      },
    });
    return tier;
  }

  @Roles('ADMIN')
  @Patch(':id/active')
  async setActive(
    @CurrentUser() actor: AuthUser,
    @Param('id') id: string,
    @Body() body: { active: boolean },
  ) {
    const before = await this.tiers.adminGet(id);
    const tier = await this.tiers.adminSetActive(id, body.active);
    await this.admin.audit(actor.id, 'tier.set_active', 'tier', id, {
      before: before.active,
      after: tier.active,
    });
    return tier;
  }
}
