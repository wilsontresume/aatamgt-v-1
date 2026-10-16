import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { AssetType, GameAsset } from '@prisma/client';
import { randomBytes } from 'crypto';
import { PrismaService } from '../prisma/prisma.service';
import { AdminService } from '../admin/admin.service';
import { StorageService, sha256Hex } from './storage/storage.service';
import { validateImageUpload } from './image-validation';

export interface UploadInput {
  buffer: Buffer;
  originalName: string;
  gameKey?: string | null;
  type: AssetType;
  note?: string | null;
}

export function assetUrl(id: string): string {
  return `/api/v1/content/assets/${id}/file`;
}

export function serializeAsset(row: GameAsset) {
  return {
    id: row.id,
    gameKey: row.gameKey,
    type: row.type,
    originalName: row.originalName,
    mimeType: row.mimeType,
    byteSize: row.byteSize,
    width: row.width,
    height: row.height,
    checksum: row.checksum,
    active: row.active,
    version: row.version,
    lineageId: row.lineageId,
    note: row.note,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    url: assetUrl(row.id),
  };
}

const ASSET_TYPES = new Set<string>(Object.values(AssetType));

@Injectable()
export class AssetsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly storage: StorageService,
    private readonly admin: AdminService,
  ) {}

  async list(query: {
    gameKey?: string;
    type?: string;
    active?: string;
    lineageId?: string;
  }): Promise<{ items: ReturnType<typeof serializeAsset>[]; total: number }> {
    const where = {
      ...(query.gameKey ? { gameKey: query.gameKey } : {}),
      ...(query.type && ASSET_TYPES.has(query.type)
        ? { type: query.type as AssetType }
        : {}),
      ...(query.active === 'true' ? { active: true } : {}),
      ...(query.active === 'false' ? { active: false } : {}),
      ...(query.lineageId ? { lineageId: query.lineageId } : {}),
    };
    const [rows, total] = await Promise.all([
      this.prisma.gameAsset.findMany({
        where,
        orderBy: [{ createdAt: 'desc' }],
        take: 200,
      }),
      this.prisma.gameAsset.count({ where }),
    ]);
    return { items: rows.map(serializeAsset), total };
  }

  async get(id: string): Promise<GameAsset> {
    const row = await this.prisma.gameAsset.findUnique({ where: { id } });
    if (!row) throw new NotFoundException('Asset not found');
    return row;
  }

  async versions(lineageId: string) {
    const rows = await this.prisma.gameAsset.findMany({
      where: { lineageId },
      orderBy: { version: 'asc' },
    });
    if (rows.length === 0) throw new NotFoundException('Asset lineage not found');
    return { items: rows.map(serializeAsset) };
  }

  async upload(actorId: string, input: UploadInput): Promise<GameAsset> {
    const type = this.assertType(input.type);
    await this.assertGame(input.gameKey, type);
    const probe = validateImageUpload(input.buffer, this.storage.maxUploadBytes);

    const id = `ga${randomBytes(14).toString('hex')}`;
    const storageKey = this.storage.newKey(probe.ext);
    await this.storage.put(storageKey, input.buffer);

    const row = await this.prisma.gameAsset.create({
      data: {
        id,
        gameKey: input.gameKey ?? null,
        type,
        storageKey,
        originalName: this.safeName(input.originalName),
        mimeType: probe.mimeType,
        byteSize: input.buffer.length,
        width: probe.width,
        height: probe.height,
        checksum: sha256Hex(input.buffer),
        lineageId: id,
        note: input.note?.slice(0, 255) ?? null,
        createdByUserId: actorId,
      },
    });
    await this.admin.audit(actorId, 'asset.upload', 'asset', row.id, {
      type: row.type,
      gameKey: row.gameKey,
      originalName: row.originalName,
      byteSize: row.byteSize,
      checksum: row.checksum,
    });
    return row;
  }

  async replace(actorId: string, id: string, file: { buffer: Buffer; originalName: string }): Promise<GameAsset> {
    const old = await this.get(id);
    const probe = validateImageUpload(file.buffer, this.storage.maxUploadBytes);

    const storageKey = this.storage.newKey(probe.ext);
    await this.storage.put(storageKey, file.buffer);

    // New immutable row in the same lineage. The previous version's row
    // AND file are preserved so any published manifest keeps resolving.
    const row = await this.prisma.gameAsset.create({
      data: {
        id: `ga${randomBytes(14).toString('hex')}`,
        gameKey: old.gameKey,
        type: old.type,
        storageKey,
        originalName: this.safeName(file.originalName || old.originalName),
        mimeType: probe.mimeType,
        byteSize: file.buffer.length,
        width: probe.width,
        height: probe.height,
        checksum: sha256Hex(file.buffer),
        version: old.version + 1,
        lineageId: old.lineageId,
        note: `replace of v${old.version}`,
        createdByUserId: actorId,
      },
    });
    await this.admin.audit(actorId, 'asset.replace', 'asset', row.id, {
      replacedAssetId: old.id,
      lineageId: row.lineageId,
      version: row.version,
      checksum: row.checksum,
    });
    return row;
  }

  async setActive(actorId: string, id: string, active: boolean): Promise<GameAsset> {
    const before = await this.get(id);
    const row = await this.prisma.gameAsset.update({
      where: { id },
      data: { active },
    });
    await this.admin.audit(actorId, 'asset.set_active', 'asset', id, {
      before: before.active,
      after: active,
      type: row.type,
      gameKey: row.gameKey,
    });
    return row;
  }

  private assertType(type: string): AssetType {
    if (!ASSET_TYPES.has(type)) {
      throw new BadRequestException(`Unknown asset type '${type}'`);
    }
    return type as AssetType;
  }

  private async assertGame(gameKey: string | null | undefined, type: AssetType): Promise<void> {
    if (!gameKey) {
      // Global slots are only the shell-level categories.
      const globalTypes = new Set(['HOME_BACKGROUND', 'BANNER', 'DECORATION']);
      if (!globalTypes.has(type)) {
        throw new BadRequestException(`Asset type ${type} requires a gameKey`);
      }
      return;
    }
    const game = await this.prisma.game.findUnique({ where: { key: gameKey } });
    if (!game) throw new BadRequestException(`Unknown game '${gameKey}'`);
  }

  private safeName(name: string): string {
    const base = (name || 'upload').split(/[\\/]/).pop() ?? 'upload';
    return base.replace(/[^\w.\- ]+/g, '_').slice(0, 200) || 'upload';
  }
}
