import { Controller, Get, NotFoundException, Param, Res, StreamableFile } from '@nestjs/common';
import { Response } from 'express';
import { Public } from '../common/decorators/public.decorator';
import { PrismaService } from '../prisma/prisma.service';
import { ContentManifestService } from './content-manifest.service';
import { StorageService } from './storage/storage.service';

/**
 * Client-facing content endpoints. The manifest is the only surface
 * ordinary clients see — unpublished assets exist in storage but are
 * never listed. Files are immutable (new version = new id/key), so they
 * carry a permanent cache header keyed by content checksum.
 */
@Controller('content')
export class ContentPublicController {
  constructor(
    private readonly content: ContentManifestService,
    private readonly prisma: PrismaService,
    private readonly storage: StorageService,
  ) {}

  @Public()
  @Get('manifest')
  async manifest() {
    const row = await this.content.current();
    if (!row) throw new NotFoundException('No content has been published yet');
    return {
      version: row.version,
      checksum: row.checksum,
      publishedAt: row.createdAt,
      manifest: row.manifest,
    };
  }

  @Public()
  @Get('assets/:id/file')
  async file(@Param('id') id: string, @Res({ passthrough: true }) res: Response) {
    const asset = await this.prisma.gameAsset.findUnique({ where: { id } });
    if (!asset) throw new NotFoundException('Asset not found');
    if (!(await this.storage.exists(asset.storageKey))) {
      throw new NotFoundException('Asset file missing');
    }
    res.setHeader('Content-Type', asset.mimeType);
    res.setHeader('Content-Length', String(asset.byteSize));
    res.setHeader('ETag', `"${asset.checksum}"`);
    res.setHeader('X-Asset-Version', String(asset.version));
    // Storage keys are content-addressed per version — never rewritten.
    res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
    const stream = await this.storage.getStream(asset.storageKey);
    return new StreamableFile(stream);
  }
}
