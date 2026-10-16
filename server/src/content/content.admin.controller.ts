import { Body, Controller, Get, HttpCode, Param, Post } from '@nestjs/common';
import { IsInt, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';
import { Roles } from '../common/decorators/roles.decorator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { ContentManifestService } from './content-manifest.service';

class PublishBody {
  @IsOptional()
  @IsString()
  @MaxLength(255)
  note?: string;
}

class RollbackBody {
  @IsInt()
  @Min(1)
  @Max(1_000_000)
  version: number;

  @IsOptional()
  @IsString()
  @MaxLength(255)
  note?: string;
}

/**
 * Draft preview, publish, history and rollback. Draft = live DB state
 * (never served to ordinary clients); publish freezes a validated copy
 * atomically so clients can never observe a half-published manifest.
 */
@Controller('admin/content')
export class ContentAdminController {
  constructor(private readonly content: ContentManifestService) {}

  @Roles('MODERATOR', 'ADMIN')
  @Get('draft')
  draft() {
    return this.content.draftWithValidation();
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('current')
  async current() {
    const row = await this.content.current();
    if (!row) return { published: false };
    return {
      published: true,
      version: row.version,
      checksum: row.checksum,
      note: row.note,
      publishedBy: row.publishedByName,
      publishedAt: row.createdAt,
      rolledBackFrom: row.rolledBackFrom,
    };
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('publications')
  history() {
    return this.content.history();
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('publications/:version')
  get(@Param('version') version: string) {
    return this.content.getByVersion(Number(version));
  }

  @Roles('ADMIN')
  @Post('publish')
  @HttpCode(201)
  async publish(@CurrentUser() actor: AuthUser, @Body() body: PublishBody) {
    const row = await this.content.publish(
      { id: actor.id, username: actor.username },
      body.note,
    );
    return {
      version: row.version,
      checksum: row.checksum,
      publishedBy: row.publishedByName,
      publishedAt: row.createdAt,
    };
  }

  @Roles('ADMIN')
  @Post('rollback')
  @HttpCode(201)
  async rollback(@CurrentUser() actor: AuthUser, @Body() body: RollbackBody) {
    const row = await this.content.rollback(
      { id: actor.id, username: actor.username },
      body.version,
      body.note,
    );
    return {
      version: row.version,
      checksum: row.checksum,
      rolledBackFrom: row.rolledBackFrom,
      publishedBy: row.publishedByName,
      publishedAt: row.createdAt,
    };
  }
}
