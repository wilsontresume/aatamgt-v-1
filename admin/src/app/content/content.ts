import { Component, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpEventType } from '@angular/common/http';
import { forkJoin } from 'rxjs';
import { AuthService } from '../core/auth.service';
import { serverMessage } from '../core/http-error';
import {
  AdminGame,
  AdminTier,
  AssetType,
  BoardTheme,
  ContentAsset,
  ContentService,
  CurrentPublication,
  DraftManifest,
  PublicationRow,
  ValidationResult,
} from './content.service';

type LoadState = 'loading' | 'ready' | 'error';
type Tab = 'games' | 'assets' | 'tiers' | 'board' | 'publish';

const TABS: { id: Tab; label: string }[] = [
  { id: 'games', label: 'Games' },
  { id: 'assets', label: 'Assets' },
  { id: 'tiers', label: 'Tiers & Coins' },
  { id: 'board', label: 'Board Designer' },
  { id: 'publish', label: 'Publish History' },
];

const EMPTY_THEME: BoardTheme = {
  backgroundAssetId: null,
  textureAssetId: null,
  pieceAssetId: null,
  surfaceColor: null,
  borderColor: null,
  accentColor: null,
};

@Component({
  selector: 'app-content',
  standalone: true,
  imports: [CommonModule, FormsModule],
  templateUrl: './content.html',
  styleUrl: './content.scss',
})
export class ContentPage implements OnInit {
  readonly state = signal<LoadState>('loading');
  readonly errorMessage = signal<string | null>(null);
  readonly tab = signal<Tab>('games');
  readonly tabs = TABS;
  readonly assetTypes = ContentService.assetTypes;

  readonly games = signal<AdminGame[]>([]);
  readonly assets = signal<ContentAsset[]>([]);
  readonly assetTotal = signal(0);
  readonly tiers = signal<AdminTier[]>([]);
  readonly draft = signal<DraftManifest | null>(null);
  readonly validation = signal<ValidationResult | null>(null);
  readonly current = signal<CurrentPublication | null>(null);
  readonly publications = signal<PublicationRow[]>([]);

  // Assets tab
  assetGameFilter = '';
  assetTypeFilter = '';
  assetActiveFilter = '';
  uploadFile: File | null = null;
  uploadType: AssetType = 'HOME_BACKGROUND';
  uploadGameKey = '';
  uploadNote = '';
  uploadProgress = 0;
  uploadBusy = false;
  uploadError: string | null = null;
  uploadSuccess: string | null = null;
  replaceTarget: ContentAsset | null = null;
  replaceFile: File | null = null;
  replaceBusy = false;
  replaceError: string | null = null;

  // Games tab
  gameBusyKey: string | null = null;
  gameError: string | null = null;
  gameOrderDrafts: Record<string, number> = {};

  // Tiers tab
  tierBusyId: string | null = null;
  tierError: string | null = null;
  tierDrafts: Record<string, { description: string; displayColor: string; artAssetId: string }> = {};
  newTier = {
    id: '',
    name: '',
    description: '',
    displayColor: '#3366ff',
    artAssetId: '',
    entryCostCoins: 50,
    rewardMultiplierBp: 12_500,
    displayOrder: 10,
  };
  newTierBusy = false;
  newTierError: string | null = null;

  // Board designer
  boardGameKey = '';
  boardTheme: BoardTheme = { ...EMPTY_THEME };
  boardBusy = false;
  boardError: string | null = null;
  boardSuccess: string | null = null;

  // Publish
  publishNote = '';
  publishBusy = false;
  publishError: string | null = null;
  publishSuccess: string | null = null;
  rollbackBusyVersion: number | null = null;
  rollbackError: string | null = null;

  constructor(
    private readonly content: ContentService,
    readonly auth: AuthService,
  ) {}

  get isAdmin(): boolean {
    return this.auth.user?.role === 'ADMIN';
  }

  get boardGames(): AdminGame[] {
    return this.games();
  }

  get boardThemeAssets(): ContentAsset[] {
    return this.assets().filter(
      (a) =>
        a.active &&
        (a.type === 'BOARD_BACKGROUND' || a.type === 'BOARD_TEXTURE' || a.type === 'PIECE_ART'),
    );
  }

  get tierArtAssets(): ContentAsset[] {
    return this.assets().filter((a) => a.active && a.type === 'TIER_ART');
  }

  ngOnInit(): void {
    const hash = (window.location.hash ?? '').replace('#', '') as Tab;
    if (TABS.some((t) => t.id === hash)) this.tab.set(hash);
    this.load();
  }

  selectTab(id: Tab): void {
    this.tab.set(id);
    window.location.hash = id;
    if (id === 'publish') this.loadPublish();
    if (id === 'board' && !this.boardGameKey && this.games().length) {
      this.selectBoardGame(this.games()[0].key);
    }
  }

  load(): void {
    this.state.set('loading');
    this.errorMessage.set(null);
    forkJoin({
      games: this.content.listGames(),
      tiers: this.content.listTiers(),
      assets: this.content.listAssets({}),
    }).subscribe({
      next: ({ games, tiers, assets }) => {
        this.games.set(games.items);
        this.tiers.set(tiers);
        this.assets.set(assets.items);
        this.assetTotal.set(assets.total);
        for (const g of games.items) this.gameOrderDrafts[g.key] = g.displayOrder;
        for (const t of tiers) {
          this.tierDrafts[t.id] = {
            description: t.description ?? '',
            displayColor: t.color ?? '#3366ff',
            artAssetId: t.artAssetId ?? '',
          };
        }
        if (!this.boardGameKey && games.items.length) {
          this.selectBoardGame(games.items[0].key);
        }
        this.state.set('ready');
        if (this.tab() === 'publish') this.loadPublish();
      },
      error: (err: unknown) => {
        this.errorMessage.set(serverMessage(err) ?? 'Could not load content studio data');
        this.state.set('error');
      },
    });
  }

  // --- Assets ---------------------------------------------------------------

  reloadAssets(): void {
    const params: Record<string, string> = {};
    if (this.assetGameFilter.trim()) params['gameKey'] = this.assetGameFilter.trim();
    if (this.assetTypeFilter) params['type'] = this.assetTypeFilter;
    if (this.assetActiveFilter) params['active'] = this.assetActiveFilter;
    this.content.listAssets(params).subscribe({
      next: (res) => {
        this.assets.set(res.items);
        this.assetTotal.set(res.total);
      },
      error: (err: unknown) => this.uploadError = serverMessage(err) ?? 'Could not load assets',
    });
  }

  onUploadFileSelected(event: Event): void {
    const input = event.target as HTMLInputElement;
    this.uploadFile = input.files?.[0] ?? null;
    this.uploadError = null;
  }

  uploadAsset(): void {
    if (!this.uploadFile) {
      this.uploadError = 'Choose an image file first';
      return;
    }
    this.uploadBusy = true;
    this.uploadError = null;
    this.uploadSuccess = null;
    this.uploadProgress = 0;
    this.content
      .uploadAsset(
        this.uploadFile,
        this.uploadType,
        this.uploadGameKey.trim() || null,
        this.uploadNote.trim() || null,
      )
      .subscribe({
        next: (event) => {
          if (event.type === HttpEventType.UploadProgress && event.total) {
            this.uploadProgress = Math.round((100 * event.loaded) / event.total);
          } else if (event.type === HttpEventType.Response) {
            this.uploadBusy = false;
            const body = event.body as ContentAsset;
            this.uploadSuccess = `Uploaded ${body.type} → ${body.id} (v${body.version})`;
            this.uploadFile = null;
            this.uploadNote = '';
            this.reloadAssets();
          }
        },
        error: (err: unknown) => {
          this.uploadBusy = false;
          this.uploadError = serverMessage(err) ?? 'Upload failed';
        },
      });
  }

  startReplace(asset: ContentAsset): void {
    this.replaceTarget = asset;
    this.replaceFile = null;
    this.replaceError = null;
  }

  cancelReplace(): void {
    this.replaceTarget = null;
    this.replaceFile = null;
  }

  onReplaceFileSelected(event: Event): void {
    const input = event.target as HTMLInputElement;
    this.replaceFile = input.files?.[0] ?? null;
  }

  confirmReplace(): void {
    if (!this.replaceTarget || !this.replaceFile) {
      this.replaceError = 'Choose the replacement image first';
      return;
    }
    this.replaceBusy = true;
    this.replaceError = null;
    this.content.replaceAsset(this.replaceTarget.id, this.replaceFile).subscribe({
      next: () => {
        this.replaceBusy = false;
        this.replaceTarget = null;
        this.replaceFile = null;
        this.reloadAssets();
      },
      error: (err: unknown) => {
        this.replaceBusy = false;
        this.replaceError = serverMessage(err) ?? 'Replace failed';
      },
    });
  }

  toggleAsset(asset: ContentAsset): void {
    this.content.setAssetActive(asset.id, !asset.active).subscribe({
      next: () => this.reloadAssets(),
      error: (err: unknown) => this.uploadError = serverMessage(err) ?? 'Update failed',
    });
  }

  // --- Games ----------------------------------------------------------------

  saveGameOrder(game: AdminGame): void {
    const value = this.gameOrderDrafts[game.key];
    if (typeof value !== 'number' || value === game.displayOrder) return;
    this.gameBusyKey = game.key;
    this.gameError = null;
    this.content.updateGame(game.key, { displayOrder: value }).subscribe({
      next: (updated) => {
        this.games.set(this.games().map((g) => (g.key === updated.key ? updated : g)));
        this.gameBusyKey = null;
      },
      error: (err: unknown) => {
        this.gameBusyKey = null;
        this.gameError = serverMessage(err) ?? 'Could not save display order';
      },
    });
  }

  saveGameStatus(game: AdminGame, status: string): void {
    if (status === game.status) return;
    this.gameBusyKey = game.key;
    this.gameError = null;
    this.content.updateGame(game.key, { status }).subscribe({
      next: (updated) => {
        this.games.set(this.games().map((g) => (g.key === updated.key ? updated : g)));
        this.gameBusyKey = null;
      },
      error: (err: unknown) => {
        this.gameBusyKey = null;
        this.gameError = serverMessage(err) ?? 'Could not save status';
      },
    });
  }

  // --- Tiers ----------------------------------------------------------------

  saveTierFields(tier: AdminTier): void {
    const draft = this.tierDrafts[tier.id];
    if (!draft) return;
    this.tierBusyId = tier.id;
    this.tierError = null;
    this.content
      .updateTier(tier.id, {
        description: draft.description.trim() || null,
        displayColor: draft.displayColor || null,
        artAssetId: draft.artAssetId || null,
      })
      .subscribe({
        next: () => {
          this.tierBusyId = null;
          this.refreshTiers();
        },
        error: (err: unknown) => {
          this.tierBusyId = null;
          this.tierError = serverMessage(err) ?? 'Could not save tier';
        },
      });
  }

  toggleTier(tier: AdminTier): void {
    this.tierBusyId = tier.id;
    this.content.setTierActive(tier.id, !tier.active).subscribe({
      next: () => {
        this.tierBusyId = null;
        this.refreshTiers();
      },
      error: (err: unknown) => {
        this.tierBusyId = null;
        this.tierError = serverMessage(err) ?? 'Could not change tier state';
      },
    });
  }

  createTier(): void {
    if (!this.newTier.id.trim() || !this.newTier.name.trim()) {
      this.newTierError = 'Tier id and name are required';
      return;
    }
    this.newTierBusy = true;
    this.newTierError = null;
    this.content
      .createTier({
        id: this.newTier.id.trim(),
        name: this.newTier.name.trim(),
        description: this.newTier.description.trim() || null,
        displayColor: this.newTier.displayColor || null,
        artAssetId: this.newTier.artAssetId || null,
        entryCostCoins: Number(this.newTier.entryCostCoins) || 0,
        rewardMultiplierBp: Number(this.newTier.rewardMultiplierBp) || 10_000,
        displayOrder: Number(this.newTier.displayOrder) || 0,
      })
      .subscribe({
        next: () => {
          this.newTierBusy = false;
          this.newTier.id = '';
          this.newTier.name = '';
          this.newTier.description = '';
          this.newTier.artAssetId = '';
          this.refreshTiers();
        },
        error: (err: unknown) => {
          this.newTierBusy = false;
          this.newTierError = serverMessage(err) ?? 'Could not create tier';
        },
      });
  }

  private refreshTiers(): void {
    this.content.listTiers().subscribe({
      next: (res) => {
        this.tiers.set(res);
        for (const t of res) {
          this.tierDrafts[t.id] = {
            description: t.description ?? '',
            displayColor: t.color ?? '#3366ff',
            artAssetId: t.artAssetId ?? '',
          };
        }
      },
      error: (err: unknown) => this.tierError = serverMessage(err) ?? 'Could not reload tiers',
    });
  }

  // --- Board designer -------------------------------------------------------

  selectBoardGame(key: string): void {
    this.boardGameKey = key;
    const game = this.games().find((g) => g.key === key);
    const theme = game?.boardTheme ?? null;
    this.boardTheme = {
      backgroundAssetId: theme?.backgroundAssetId ?? null,
      textureAssetId: theme?.textureAssetId ?? null,
      pieceAssetId: theme?.pieceAssetId ?? null,
      surfaceColor: theme?.surfaceColor ?? null,
      borderColor: theme?.borderColor ?? null,
      accentColor: theme?.accentColor ?? null,
    };
    this.boardError = null;
    this.boardSuccess = null;
  }

  saveBoardTheme(): void {
    if (!this.boardGameKey) return;
    this.boardBusy = true;
    this.boardError = null;
    this.boardSuccess = null;
    this.content.updateGame(this.boardGameKey, { boardTheme: { ...this.boardTheme } }).subscribe({
      next: (updated) => {
        this.games.set(this.games().map((g) => (g.key === updated.key ? updated : g)));
        this.boardBusy = false;
        this.boardSuccess = `Board theme saved for ${updated.name}`;
      },
      error: (err: unknown) => {
        this.boardBusy = false;
        this.boardError = serverMessage(err) ?? 'Could not save board theme';
      },
    });
  }

  // --- Publish --------------------------------------------------------------

  loadPublish(): void {
    forkJoin({
      draft: this.content.getDraft(),
      current: this.content.getCurrent(),
      publications: this.content.listPublications(),
    }).subscribe({
      next: ({ draft, current, publications }) => {
        this.draft.set(draft.manifest);
        this.validation.set(draft.validation);
        this.current.set(current);
        this.publications.set(publications.items);
      },
      error: (err: unknown) =>
        this.publishError = serverMessage(err) ?? 'Could not load publish data',
    });
  }

  publishNow(): void {
    if (!this.validation()?.ok) return;
    this.publishBusy = true;
    this.publishError = null;
    this.publishSuccess = null;
    this.content.publish(this.publishNote.trim() || null).subscribe({
      next: (res) => {
        this.publishBusy = false;
        this.publishSuccess = `Published v${res.version} (checksum ${res.checksum.slice(0, 12)}…)`;
        this.publishNote = '';
        this.loadPublish();
      },
      error: (err: unknown) => {
        this.publishBusy = false;
        this.publishError = serverMessage(err) ?? 'Publish failed';
      },
    });
  }

  rollbackTo(version: number): void {
    this.rollbackBusyVersion = version;
    this.rollbackError = null;
    this.content.rollback(version, null).subscribe({
      next: (res) => {
        this.rollbackBusyVersion = null;
        this.publishSuccess = `Rolled back to v${version} — now live as v${res.version}`;
        this.loadPublish();
      },
      error: (err: unknown) => {
        this.rollbackBusyVersion = null;
        this.rollbackError = serverMessage(err) ?? 'Rollback failed';
      },
    });
  }

  trackAsset(_index: number, asset: ContentAsset): string {
    return asset.id;
  }

  objectCount(obj: Record<string, unknown> | null | undefined): number {
    return obj ? Object.keys(obj).length : 0;
  }

  trackGame(_index: number, game: AdminGame): string {
    return game.key;
  }

  trackTier(_index: number, tier: AdminTier): string {
    return tier.id;
  }

  trackPub(_index: number, row: PublicationRow): number {
    return row.version;
  }
}
