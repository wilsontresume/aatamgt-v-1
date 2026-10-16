import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  Param,
  Patch,
  Post,
  Query,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { Throttle } from '@nestjs/throttler';
import { IsBoolean, IsIn, IsOptional, IsString, Matches, MaxLength } from 'class-validator';
import { AssetType } from '@prisma/client';
import { Roles } from '../common/decorators/roles.decorator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { AssetsService, serializeAsset } from './assets.service';

const ASSET_TYPE_VALUES = Object.values(AssetType) as [string, ...string[]];

class UploadQuery {
  @IsOptional()
  @Matches(/^[a-z0-9-]{3,64}$/)
  gameKey?: string;

  @IsIn(ASSET_TYPE_VALUES)
  type: AssetType;

  @IsOptional()
  @IsString()
  @MaxLength(255)
  note?: string;
}

class SetActiveBody {
  @IsBoolean()
  active: boolean;
}

/**
 * Admin asset library. Uploads are ADMIN-only and rate-limited; staff
 * (MODERATOR+) can browse. Files are validated by signature (never by
 * the client's claimed MIME), stored under randomized keys, and served
 * immutably from /api/v1/content/assets/:id/file.
 */
@Controller('admin/assets')
export class AssetsAdminController {
  constructor(private readonly assets: AssetsService) {}

  @Roles('MODERATOR', 'ADMIN')
  @Get()
  list(
    @Query('gameKey') gameKey?: string,
    @Query('type') type?: string,
    @Query('active') active?: string,
    @Query('lineageId') lineageId?: string,
  ) {
    return this.assets.list({ gameKey, type, active, lineageId });
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get(':id')
  async get(@Param('id') id: string) {
    return serializeAsset(await this.assets.get(id));
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get(':id/versions')
  versions(@Param('id') id: string) {
    return this.assets.versions(id);
  }

  @Roles('ADMIN')
  @Throttle({ default: { limit: 20, ttl: 60_000 } })
  @Post()
  @HttpCode(201)
  @UseInterceptors(FileInterceptor('file'))
  async upload(
    @CurrentUser() actor: AuthUser,
    @UploadedFile() file: Express.Multer.File | undefined,
    @Query() query: UploadQuery,
  ) {
    const upload = this.requireFile(file);
    const row = await this.assets.upload(actor.id, {
      buffer: upload.buffer,
      originalName: upload.originalname,
      gameKey: query.gameKey ?? null,
      type: query.type,
      note: query.note ?? null,
    });
    return serializeAsset(row);
  }

  @Roles('ADMIN')
  @Throttle({ default: { limit: 20, ttl: 60_000 } })
  @Post(':id/replace')
  @UseInterceptors(FileInterceptor('file'))
  async replace(
    @CurrentUser() actor: AuthUser,
    @Param('id') id: string,
    @UploadedFile() file: Express.Multer.File | undefined,
  ) {
    const upload = this.requireFile(file);
    const row = await this.assets.replace(actor.id, id, {
      buffer: upload.buffer,
      originalName: upload.originalname,
    });
    return serializeAsset(row);
  }

  @Roles('ADMIN')
  @Patch(':id')
  async setActive(
    @CurrentUser() actor: AuthUser,
    @Param('id') id: string,
    @Body() body: SetActiveBody,
  ) {
    return serializeAsset(await this.assets.setActive(actor.id, id, body.active));
  }

  private requireFile(file: Express.Multer.File | undefined): Express.Multer.File {
    if (!file || !file.buffer || file.buffer.length === 0) {
      throw new BadRequestException('A non-empty file field "file" is required');
    }
    return file;
  }
}
