import { HttpClient, HttpEvent } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { Observable } from 'rxjs';

export interface ContentAsset {
  id: string;
  gameKey: string | null;
  type: string;
  storageKey: string;
  originalName: string;
  mimeType: string;
  byteSize: number;
  width: number | null;
  height: number | null;
  checksum: string;
  version: number;
  lineageId: string;
  active: boolean;
  note: string | null;
  url: string;
  createdByUserId: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface AssetListResponse {
  items: ContentAsset[];
  total: number;
}

export interface BoardTheme {
  backgroundAssetId: string | null;
  textureAssetId: string | null;
  pieceAssetId: string | null;
  surfaceColor: string | null;
  borderColor: string | null;
  accentColor: string | null;
}

export interface AdminGame {
  id: string;
  key: string;
  name: string;
  slug: string;
  description: string | null;
  minPlayers: number;
  maxPlayers: number;
  status: string;
  rulesVersion: number;
  requiresAuthoritativeState: boolean;
  displayOrder: number;
  boardTheme: Partial<BoardTheme> | null;
}

export interface AdminTier {
  id: string;
  label: string;
  costCoins: number;
  rewardMultiplierBp: number;
  minBalance: number;
  rewardCoins: number;
  description: string | null;
  color: string | null;
  artAssetId: string | null;
  displayOrder: number;
  active: boolean;
  gameKey: string | null;
}

export interface AssetRef {
  id: string;
}

export interface DraftManifest {
  version: number;
  generatedAt: string;
  home: { background: AssetRef | null };
  games: {
    key: string;
    name: string;
    slug: string;
    description: string | null;
    displayOrder: number;
    status: string;
    card: AssetRef | null;
    icon: AssetRef | null;
    background: AssetRef | null;
    boardTheme: {
      background: AssetRef | null;
      texture: AssetRef | null;
      piece: AssetRef | null;
      surfaceColor: string | null;
      borderColor: string | null;
      accentColor: string | null;
    };
  }[];
  tiers: {
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
  }[];
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

export interface DraftResponse {
  manifest: DraftManifest;
  validation: ValidationResult;
}

export interface CurrentPublication {
  published: boolean;
  version?: number;
  checksum?: string;
  note?: string | null;
  publishedBy?: string | null;
  publishedAt?: string;
  rolledBackFrom?: number | null;
}

export interface PublicationRow {
  version: number;
  status: string;
  checksum: string;
  note: string | null;
  rolledBackFrom: number | null;
  publishedBy: string | null;
  publishedAt: string;
  summary: { games: number; tiers: number; assets: number };
}

export interface PublicationsResponse {
  items: PublicationRow[];
}

export interface PublishResult {
  version: number;
  checksum: string;
  publishedBy: string;
  publishedAt: string;
  rolledBackFrom?: number | null;
}

const ASSET_TYPES = [
  'HOME_BACKGROUND',
  'GAME_BACKGROUND',
  'GAME_CARD',
  'GAME_ICON',
  'BOARD_TEXTURE',
  'BOARD_BACKGROUND',
  'PIECE_ART',
  'TIER_ART',
  'BANNER',
  'DECORATION',
] as const;

export type AssetType = (typeof ASSET_TYPES)[number];

@Injectable({ providedIn: 'root' })
export class ContentService {
  static readonly assetTypes = ASSET_TYPES;

  constructor(private readonly http: HttpClient) {}

  // --- Assets --------------------------------------------------------------

  listAssets(params: {
    gameKey?: string;
    type?: string;
    active?: string;
    lineageId?: string;
  }): Observable<AssetListResponse> {
    let query = '';
    const parts: string[] = [];
    if (params.gameKey) parts.push(`gameKey=${encodeURIComponent(params.gameKey)}`);
    if (params.type) parts.push(`type=${encodeURIComponent(params.type)}`);
    if (params.active) parts.push(`active=${params.active}`);
    if (params.lineageId) parts.push(`lineageId=${encodeURIComponent(params.lineageId)}`);
    if (parts.length) query = `?${parts.join('&')}`;
    return this.http.get<AssetListResponse>(`/api/v1/admin/assets${query}`);
  }

  getAsset(id: string): Observable<ContentAsset> {
    return this.http.get<ContentAsset>(`/api/v1/admin/assets/${id}`);
  }

  getAssetVersions(id: string): Observable<{ items: ContentAsset[] }> {
    return this.http.get<{ items: ContentAsset[] }>(`/api/v1/admin/assets/${id}/versions`);
  }

  uploadAsset(
    file: File,
    type: AssetType,
    gameKey: string | null,
    note: string | null,
  ): Observable<HttpEvent<ContentAsset>> {
    const form = new FormData();
    form.append('file', file, file.name);
    let query = `type=${encodeURIComponent(type)}`;
    if (gameKey) query += `&gameKey=${encodeURIComponent(gameKey)}`;
    if (note) query += `&note=${encodeURIComponent(note)}`;
    return this.http.post<ContentAsset>(`/api/v1/admin/assets?${query}`, form, {
      reportProgress: true,
      observe: 'events',
    });
  }

  replaceAsset(id: string, file: File): Observable<HttpEvent<ContentAsset>> {
    const form = new FormData();
    form.append('file', file, file.name);
    return this.http.post<ContentAsset>(`/api/v1/admin/assets/${id}/replace`, form, {
      reportProgress: true,
      observe: 'events',
    });
  }

  setAssetActive(id: string, active: boolean): Observable<ContentAsset> {
    return this.http.patch<ContentAsset>(`/api/v1/admin/assets/${id}`, { active });
  }

  // --- Games ---------------------------------------------------------------

  listGames(): Observable<{ items: AdminGame[] }> {
    return this.http.get<{ items: AdminGame[] }>('/api/v1/games/admin');
  }

  updateGame(
    key: string,
    patch: {
      displayOrder?: number;
      status?: string;
      boardTheme?: Partial<BoardTheme> | null;
    },
  ): Observable<AdminGame> {
    return this.http.patch<AdminGame>(`/api/v1/admin/games/${key}`, patch);
  }

  // --- Tiers ---------------------------------------------------------------

  listTiers(): Observable<AdminTier[]> {
    return this.http.get<AdminTier[]>('/api/v1/admin/tiers');
  }

  createTier(body: {
    id: string;
    name: string;
    description?: string | null;
    displayColor?: string | null;
    artAssetId?: string | null;
    entryCostCoins: number;
    rewardMultiplierBp: number;
    displayOrder: number;
  }): Observable<AdminTier> {
    return this.http.post<AdminTier>('/api/v1/admin/tiers', body);
  }

  updateTier(
    id: string,
    patch: {
      name?: string;
      description?: string | null;
      displayColor?: string | null;
      artAssetId?: string | null;
      entryCostCoins?: number;
      rewardMultiplierBp?: number;
      displayOrder?: number;
    },
  ): Observable<AdminTier> {
    return this.http.patch<AdminTier>(`/api/v1/admin/tiers/${id}`, patch);
  }

  setTierActive(id: string, active: boolean): Observable<AdminTier> {
    return this.http.patch<AdminTier>(`/api/v1/admin/tiers/${id}/active`, { active });
  }

  // --- Content publish -----------------------------------------------------

  getDraft(): Observable<DraftResponse> {
    return this.http.get<DraftResponse>('/api/v1/admin/content/draft');
  }

  getCurrent(): Observable<CurrentPublication> {
    return this.http.get<CurrentPublication>('/api/v1/admin/content/current');
  }

  publish(note: string | null): Observable<PublishResult> {
    return this.http.post<PublishResult>('/api/v1/admin/content/publish', { note: note ?? null });
  }

  listPublications(): Observable<PublicationsResponse> {
    return this.http.get<PublicationsResponse>('/api/v1/admin/content/publications');
  }

  rollback(version: number, note: string | null): Observable<PublishResult> {
    return this.http.post<PublishResult>('/api/v1/admin/content/rollback', {
      version,
      note: note ?? null,
    });
  }
}
