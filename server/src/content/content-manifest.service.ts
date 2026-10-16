import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { AssetType, ContentPublication, GameAsset, Prisma } from '@prisma/client';
import { createHash } from 'crypto';
import { PrismaService } from '../prisma/prisma.service';
import { AdminService } from '../admin/admin.service';
import { assetUrl } from './assets.service';

export interface AssetRef {
  id: string;
}

export interface BoardThemeConfig {
  background: AssetRef | null;
  texture: AssetRef | null;
  piece: AssetRef | null;
  surfaceColor: string | null;
  borderColor: string | null;
  accentColor: string | null;
}

export interface DraftManifest {
  version: number;
  generatedAt: string;
  home: { background: AssetRef | null };
  games: Array<{
    key: string;
    name: string;
    slug: string;
    description: string | null;
    displayOrder: number;
    status: string;
    card: AssetRef | null;
    icon: AssetRef | null;
    background: AssetRef | null;
    boardTheme: BoardThemeConfig;
  }>;
  tiers: Array<{
    id: string;
    name: string;
    gameKey: string | null;
    description: string | null;
    color: string | null;
    art: AssetRef | null;
    entryCostCoins: number;
    rewardMultiplierBp: number;
    rewardCoins: number;
    displayOrder: number;
    active: boolean;
  }>;
  assets: Record<
    string,
    {
      url: string;
      checksum: string;
      type: string;
      version: number;
      width: number | null;
      height: number | null;
      mimeType: string;
      byteSize: number;
    }
  >;
}

export interface ValidationResult {
  ok: boolean;
  errors: string[];
  warnings: string[];
}

const HEX_COLOR = /^#[0-9a-fA-F]{6}$/;

function parseBoardTheme(config: unknown): BoardThemeConfig {
  const empty: BoardThemeConfig = {
    background: null,
    texture: null,
    piece: null,
    surfaceColor: null,
    borderColor: null,
    accentColor: null,
  };
  if (!config || typeof config !== 'object') return empty;
  const raw = (config as Record<string, unknown>).boardTheme;
  if (!raw || typeof raw !== 'object') return empty;
  const t = raw as Record<string, unknown>;
  const ref = (v: unknown): AssetRef | null =>
    typeof v === 'string' && v.length > 0 ? { id: v } : null;
  return {
    background: ref(t.backgroundAssetId),
    texture: ref(t.textureAssetId),
    piece: ref(t.pieceAssetId),
    surfaceColor: typeof t.surfaceColor === 'string' ? t.surfaceColor : null,
    borderColor: typeof t.borderColor === 'string' ? t.borderColor : null,
    accentColor: typeof t.accentColor === 'string' ? t.accentColor : null,
  };
}

/** Latest ACTIVE asset per (gameKey, type) slot, plus global slots. */
function pickLatest(rows: GameAsset[]): Map<string, GameAsset> {
  const bySlot = new Map<string, GameAsset>();
  for (const row of rows) {
    if (!row.active) continue;
    const slot = `${row.gameKey ?? '*'}|${row.type}`;
    const current = bySlot.get(slot);
    if (!current || row.version > current.version) bySlot.set(slot, row);
  }
  return bySlot;
}

@Injectable()
export class ContentManifestService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly admin: AdminService,
  ) {}

  /** Builds the draft manifest from live DB state (the draft workspace). */
  async buildDraft(): Promise<DraftManifest> {
    const [games, tiers, assets] = await Promise.all([
      this.prisma.game.findMany({ orderBy: [{ displayOrder: 'asc' }, { name: 'asc' }] }),
      this.prisma.tier.findMany({ orderBy: { displayOrder: 'asc' } }),
      this.prisma.gameAsset.findMany({ where: { active: true } }),
    ]);
    const latest = pickLatest(assets);

    const assetEntry = (row: GameAsset) => ({
      url: assetUrl(row.id),
      checksum: row.checksum,
      type: row.type,
      version: row.version,
      width: row.width,
      height: row.height,
      mimeType: row.mimeType,
      byteSize: row.byteSize,
    });

    const refFor = (gameKey: string | null, type: AssetType): AssetRef | null => {
      const row = latest.get(`${gameKey ?? '*'}|${type}`);
      return row ? { id: row.id } : null;
    };

    const manifest: DraftManifest = {
      version: 0,
      generatedAt: new Date().toISOString(),
      home: { background: refFor(null, 'HOME_BACKGROUND') },
      games: games.map((game) => ({
        key: game.key,
        name: game.name,
        slug: game.slug,
        description: game.description,
        displayOrder: game.displayOrder,
        status: game.status,
        card: refFor(game.key, 'GAME_CARD'),
        icon: refFor(game.key, 'GAME_ICON'),
        background: refFor(game.key, 'GAME_BACKGROUND'),
        boardTheme: parseBoardTheme(game.config),
      })),
      tiers: tiers.map((tier) => ({
        id: tier.id,
        name: tier.name,
        gameKey: tier.gameKey,
        description: tier.description,
        color: tier.displayColor,
        art: tier.artAssetId ? { id: tier.artAssetId } : null,
        entryCostCoins: tier.entryCostCoins,
        rewardMultiplierBp: tier.rewardMultiplierBp,
        rewardCoins: Math.floor((tier.entryCostCoins * tier.rewardMultiplierBp) / 10_000),
        displayOrder: tier.displayOrder,
        active: tier.active,
      })),
      assets: {},
    };

    // Collect every referenced asset id, then emit the assets map.
    const referenced = new Set<string>();
    const collect = (ref: AssetRef | null): void => {
      if (ref) referenced.add(ref.id);
    };
    collect(manifest.home.background);
    for (const game of manifest.games) {
      collect(game.card);
      collect(game.icon);
      collect(game.background);
      collect(game.boardTheme.background);
      collect(game.boardTheme.texture);
      collect(game.boardTheme.piece);
    }
    for (const tier of manifest.tiers) collect(tier.art);

    for (const id of referenced) {
      const row = assets.find((a) => a.id === id);
      if (row) manifest.assets[id] = assetEntry(row);
    }
    return manifest;
  }

  /** Server-side validation of a draft. Never trusts client manifests. */
  async validateDraft(manifest: DraftManifest): Promise<ValidationResult> {
    const errors: string[] = [];
    const warnings: string[] = [];

    const assetIds = Object.keys(manifest.assets);
    const rows = assetIds.length
      ? await this.prisma.gameAsset.findMany({ where: { id: { in: assetIds } } })
      : [];
    const byId = new Map(rows.map((r) => [r.id, r]));

    const checkRef = (label: string, ref: AssetRef | null, expected?: AssetType): void => {
      if (!ref) return;
      const row = byId.get(ref.id);
      if (!row) {
        errors.push(`${label}: asset ${ref.id} is missing`);
        return;
      }
      if (!row.active) errors.push(`${label}: asset ${ref.id} is inactive`);
      if (expected && row.type !== expected) {
        errors.push(`${label}: asset ${ref.id} is ${row.type}, expected ${expected}`);
      }
    };

    checkRef('home.background', manifest.home.background, 'HOME_BACKGROUND');
    for (const game of manifest.games) {
      checkRef(`game ${game.key}.card`, game.card, 'GAME_CARD');
      checkRef(`game ${game.key}.icon`, game.icon, 'GAME_ICON');
      checkRef(`game ${game.key}.background`, game.background, 'GAME_BACKGROUND');
      checkRef(`game ${game.key}.boardTheme.background`, game.boardTheme.background, 'BOARD_BACKGROUND');
      checkRef(`game ${game.key}.boardTheme.texture`, game.boardTheme.texture, 'BOARD_TEXTURE');
      checkRef(`game ${game.key}.boardTheme.piece`, game.boardTheme.piece, 'PIECE_ART');
      for (const [name, color] of [
        ['surfaceColor', game.boardTheme.surfaceColor],
        ['borderColor', game.boardTheme.borderColor],
        ['accentColor', game.boardTheme.accentColor],
      ] as const) {
        if (color && !HEX_COLOR.test(color)) {
          errors.push(`game ${game.key}.boardTheme.${name}: '${color}' is not a #rrggbb color`);
        }
      }
      if (game.status === 'DISABLED') warnings.push(`game ${game.key} is DISABLED and hidden from players`);
    }
    for (const tier of manifest.tiers) {
      checkRef(`tier ${tier.id}.art`, tier.art, 'TIER_ART');
      if (tier.color && !HEX_COLOR.test(tier.color)) {
        errors.push(`tier ${tier.id}: color '${tier.color}' is not a #rrggbb color`);
      }
      if (tier.entryCostCoins < 0 || tier.entryCostCoins > 1_000_000) {
        errors.push(`tier ${tier.id}: entry cost out of range`);
      }
      if (tier.rewardMultiplierBp < 10_000 || tier.rewardMultiplierBp > 1_000_000) {
        errors.push(`tier ${tier.id}: reward multiplier out of range`);
      }
      if (!tier.active) warnings.push(`tier ${tier.id} is inactive — blocked for new entries`);
    }
    if (manifest.games.filter((g) => g.status === 'ACTIVE').length === 0) {
      errors.push('no ACTIVE games in the manifest');
    }
    return { ok: errors.length === 0, errors, warnings };
  }

  async draftWithValidation(): Promise<{
    manifest: DraftManifest;
    validation: ValidationResult;
  }> {
    const manifest = await this.buildDraft();
    return { manifest, validation: await this.validateDraft(manifest) };
  }

  async publish(actor: { id: string; username: string }, note?: string): Promise<ContentPublication> {
    const { manifest, validation } = await this.draftWithValidation();
    if (!validation.ok) {
      throw new BadRequestException({
        message: 'Manifest failed validation',
        errors: validation.errors,
      });
    }
    return this.persistPublication(manifest, actor, note ?? null, null);
  }

  async rollback(actor: { id: string; username: string }, targetVersion: number, note?: string): Promise<ContentPublication> {
    const source = await this.prisma.contentPublication.findUnique({
      where: { version: targetVersion },
    });
    if (!source) throw new NotFoundException(`Version ${targetVersion} not found`);
    const manifest = source.manifest as unknown as DraftManifest;
    // Re-freeze the old manifest verbatim (ids/files are immutable).
    return this.persistPublication(
      manifest,
      actor,
      note ?? `rollback to v${targetVersion}`,
      targetVersion,
    );
  }

  private async persistPublication(
    manifest: DraftManifest,
    actor: { id: string; username: string },
    note: string | null,
    rolledBackFrom: number | null,
  ): Promise<ContentPublication> {
    return this.prisma.$transaction(async (tx) => {
      const top = await tx.contentPublication.findFirst({
        orderBy: { version: 'desc' },
      });
      const version = (top?.version ?? 0) + 1;
      const frozen: DraftManifest = {
        ...manifest,
        version,
        publishedAt: new Date().toISOString(),
        ...(rolledBackFrom !== null ? { rolledBackFrom } : {}),
      } as DraftManifest;
      const json = JSON.stringify(frozen);
      const checksum = createHash('sha256').update(json).digest('hex');

      await tx.contentPublication.updateMany({
        where: { status: 'PUBLISHED' },
        data: { status: 'SUPERSEDED' },
      });
      const row = await tx.contentPublication.create({
        data: {
          version,
          status: 'PUBLISHED',
          manifest: frozen as unknown as Prisma.InputJsonValue,
          checksum,
          note,
          rolledBackFrom,
          publishedByUserId: actor.id,
          publishedByName: actor.username,
        },
      });
      await this.admin.audit(actor.id, rolledBackFrom ? 'content.rollback' : 'content.publish', 'content', `v${version}`, {
        version,
        checksum,
        games: frozen.games.length,
        tiers: frozen.tiers.length,
        assets: Object.keys(frozen.assets).length,
        rolledBackFrom,
      });
      return row;
    });
  }

  async current(): Promise<ContentPublication | null> {
    return this.prisma.contentPublication.findFirst({
      where: { status: 'PUBLISHED' },
      orderBy: { version: 'desc' },
    });
  }

  async history() {
    const rows = await this.prisma.contentPublication.findMany({
      orderBy: { version: 'desc' },
      take: 100,
    });
    return {
      items: rows.map((row) => ({
        version: row.version,
        status: row.status,
        checksum: row.checksum,
        note: row.note,
        rolledBackFrom: row.rolledBackFrom,
        publishedBy: row.publishedByName,
        publishedAt: row.createdAt,
        summary: summarizeManifest(row.manifest as unknown as DraftManifest),
      })),
    };
  }

  async getByVersion(version: number) {
    const row = await this.prisma.contentPublication.findUnique({
      where: { version },
    });
    if (!row) throw new NotFoundException(`Version ${version} not found`);
    return {
      version: row.version,
      status: row.status,
      checksum: row.checksum,
      note: row.note,
      rolledBackFrom: row.rolledBackFrom,
      publishedBy: row.publishedByName,
      publishedAt: row.createdAt,
      manifest: row.manifest,
    };
  }
}

export function summarizeManifest(manifest: DraftManifest): {
  games: number;
  tiers: number;
  assets: number;
} {
  return {
    games: manifest.games?.length ?? 0,
    tiers: manifest.tiers?.length ?? 0,
    assets: Object.keys(manifest.assets ?? {}).length,
  };
}

export { parseBoardTheme };
