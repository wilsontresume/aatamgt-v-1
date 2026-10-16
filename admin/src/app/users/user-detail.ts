import { Component, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { HttpClient, HttpParams } from '@angular/common/http';
import { AuthService } from '../core/auth.service';
import { serverMessage } from '../core/http-error';
import {
  AdjustResult,
  ConfigEntry,
  ModerationNote,
  Paginated,
  PlayerDetail,
  PlayerMatchRow,
  RoleChangeResult,
  SessionRevokeResult,
  WalletPage,
} from '../core/models';

type LoadState = 'loading' | 'ready' | 'error';
type ActionKind = 'suspend' | 'unsuspend' | 'ban' | 'unban' | 'revoke' | 'role';

const THRESHOLD_KEY = 'admin.wallet_adjust_threshold';
const DEFAULT_THRESHOLD = 100_000;

interface AdjustReview {
  amount: number;
  reason: string;
  proposed: number;
  large: boolean;
  key: string;
}

const STATUS_FOR_ACTION: Record<Exclude<ActionKind, 'revoke' | 'role'>, string> = {
  suspend: 'SUSPENDED',
  unsuspend: 'ACTIVE',
  ban: 'BANNED',
  unban: 'ACTIVE',
};

@Component({
  selector: 'app-user-detail',
  standalone: true,
  imports: [CommonModule, FormsModule, RouterLink],
  templateUrl: './user-detail.html',
  styleUrl: './user-detail.scss',
})
export class UserDetailPage implements OnInit {
  readonly state = signal<LoadState>('loading');
  readonly user = signal<PlayerDetail | null>(null);
  readonly wallet = signal<WalletPage | null>(null);
  readonly matches = signal<Paginated<PlayerMatchRow> | null>(null);
  readonly notes = signal<Paginated<ModerationNote> | null>(null);
  readonly errorMessage = signal<string | null>(null);

  readonly pendingAction = signal<ActionKind | null>(null);
  readonly actionBusy = signal(false);
  readonly actionError = signal<string | null>(null);
  readonly actionSuccess = signal<string | null>(null);

  reason = '';
  roleChoice: 'USER' | 'MODERATOR' | 'ADMIN' = 'USER';
  noteBody = '';
  noteError = signal<string | null>(null);

  // --- Phase D: wallet adjustment --------------------------------------------
  readonly adjustOpen = signal(false);
  readonly adjustBusy = signal(false);
  readonly adjustError = signal<string | null>(null);
  readonly adjustReview = signal<AdjustReview | null>(null);
  adjustDirection: 'credit' | 'debit' = 'credit';
  adjustAmount = '';
  adjustReason = '';
  adjustConfirmText = '';
  adjustThreshold = DEFAULT_THRESHOLD;

  txPage = 1;
  matchPage = 1;
  notePage = 1;
  private userId = '';

  constructor(
    private readonly http: HttpClient,
    private readonly route: ActivatedRoute,
    readonly auth: AuthService,
  ) {}

  ngOnInit(): void {
    this.userId = this.route.snapshot.paramMap.get('id') ?? '';
    this.load();
    this.loadThreshold();
  }

  get isAdmin(): boolean {
    return this.auth.user?.role === 'ADMIN';
  }

  get isSelf(): boolean {
    return this.auth.user?.id === this.userId;
  }

  get pendingNeedsReason(): boolean {
    const kind = this.pendingAction();
    return kind === 'suspend' || kind === 'unsuspend' || kind === 'ban' || kind === 'unban';
  }

  get statusChangeBlocked(): boolean {
    return this.isSelf;
  }

  load(): void {
    this.state.set('loading');
    this.errorMessage.set(null);
    this.http.get<PlayerDetail>(`/api/v1/admin/users/${this.userId}`).subscribe({
      next: (res) => {
        this.user.set(res);
        this.roleChoice = res.role;
        this.state.set('ready');
        this.loadWallet();
        this.loadMatches();
        this.loadNotes();
      },
      error: (err: { status?: number; message?: string }) => {
        if (err?.status === 401) {
          this.errorMessage.set('Your session has expired. Sign in again.');
        } else if (err?.status === 403) {
          this.errorMessage.set('You do not have permission to view this player.');
        } else if (err?.status === 404) {
          this.errorMessage.set('This player does not exist or was deleted.');
        } else {
          this.errorMessage.set('Could not reach the server. Check the backend and retry.');
        }
        this.state.set('error');
      },
    });
  }

  private loadWallet(): void {
    const params = new HttpParams().set('page', String(this.txPage)).set('limit', '10');
    this.http.get<WalletPage>(`/api/v1/admin/users/${this.userId}/wallet`, { params }).subscribe({
      next: (res) => this.wallet.set(res),
      error: () => this.wallet.set(null),
    });
  }

  private loadMatches(): void {
    const params = new HttpParams().set('page', String(this.matchPage)).set('limit', '10');
    this.http
      .get<Paginated<PlayerMatchRow>>(`/api/v1/admin/users/${this.userId}/matches`, { params })
      .subscribe({
        next: (res) => this.matches.set(res),
        error: () => this.matches.set(null),
      });
  }

  private loadNotes(): void {
    const params = new HttpParams().set('page', String(this.notePage)).set('limit', '10');
    this.http
      .get<Paginated<ModerationNote>>(`/api/v1/admin/users/${this.userId}/notes`, { params })
      .subscribe({
        next: (res) => this.notes.set(res),
        error: () => this.notes.set(null),
      });
  }

  // --- Pagination -------------------------------------------------------------

  txPages(): number {
    const w = this.wallet();
    if (!w || w.total === 0) return 1;
    return Math.ceil(w.total / w.limit);
  }

  matchPages(): number {
    const m = this.matches();
    if (!m || m.total === 0) return 1;
    return Math.ceil(m.total / m.limit);
  }

  notePages(): number {
    const n = this.notes();
    if (!n || n.total === 0) return 1;
    return Math.ceil(n.total / n.limit);
  }

  prevTx(): void {
    if (this.txPage > 1) {
      this.txPage -= 1;
      this.loadWallet();
    }
  }

  nextTx(): void {
    if (this.txPage < this.txPages()) {
      this.txPage += 1;
      this.loadWallet();
    }
  }

  prevMatch(): void {
    if (this.matchPage > 1) {
      this.matchPage -= 1;
      this.loadMatches();
    }
  }

  nextMatch(): void {
    if (this.matchPage < this.matchPages()) {
      this.matchPage += 1;
      this.loadMatches();
    }
  }

  prevNote(): void {
    if (this.notePage > 1) {
      this.notePage -= 1;
      this.loadNotes();
    }
  }

  nextNote(): void {
    if (this.notePage < this.notePages()) {
      this.notePage += 1;
      this.loadNotes();
    }
  }

  // --- Moderation actions -----------------------------------------------------

  beginAction(kind: ActionKind): void {
    if (kind === 'suspend' || kind === 'ban') {
      if (this.statusChangeBlocked) return;
    }
    this.pendingAction.set(kind);
    this.reason = '';
    this.actionError.set(null);
    this.actionSuccess.set(null);
    if (kind === 'role') this.roleChoice = this.user()?.role ?? 'USER';
  }

  cancelAction(): void {
    this.pendingAction.set(null);
    this.reason = '';
    this.actionError.set(null);
  }

  confirmAction(): void {
    const kind = this.pendingAction();
    if (!kind || this.actionBusy()) return;

    const reason = this.reason.trim();
    if (this.pendingNeedsReason && !reason) {
      this.actionError.set('A reason is required — it is stored in the audit log.');
      return;
    }

    this.actionBusy.set(true);
    this.actionError.set(null);

    if (kind === 'revoke') {
      this.http.post<SessionRevokeResult>(`/api/v1/admin/users/${this.userId}/revoke-sessions`, {}).subscribe({
        next: (res) => {
          this.actionBusy.set(false);
          this.pendingAction.set(null);
          this.actionSuccess.set(
            `Revoked ${res.sessionsRevoked} session${res.sessionsRevoked === 1 ? '' : 's'}.`,
          );
        },
        error: (err: { status?: number; message?: string }) => this.handleActionError(err),
      });
      return;
    }

    if (kind === 'role') {
      this.http
        .patch<RoleChangeResult>(`/api/v1/admin/users/${this.userId}/role`, { role: this.roleChoice })
        .subscribe({
          next: (res) => {
            this.actionBusy.set(false);
            this.pendingAction.set(null);
            this.actionSuccess.set(
              `Role set to ${res.role}. ${res.sessionsRevoked} session${
                res.sessionsRevoked === 1 ? '' : 's'
              } revoked — the change applies on next sign-in.`,
            );
            this.load();
          },
          error: (err: { status?: number; message?: string }) => this.handleActionError(err),
        });
      return;
    }

    const status = STATUS_FOR_ACTION[kind];
    this.http
      .patch<{ status: string }>(`/api/v1/admin/users/${this.userId}/status`, {
        status,
        reason: reason || undefined,
      })
      .subscribe({
        next: () => {
          this.actionBusy.set(false);
          this.pendingAction.set(null);
          this.actionSuccess.set(`Status set to ${status}.`);
          this.load();
        },
        error: (err: { status?: number; message?: string }) => this.handleActionError(err),
      });
  }

  private handleActionError(err: { status?: number; message?: string }): void {
    this.actionBusy.set(false);
    if (err?.status === 400) {
      this.actionError.set(serverMessage(err) || 'The request was rejected. Check the values and retry.');
    } else if (err?.status === 401) {
      this.actionError.set('Your session has expired. Sign in again.');
    } else if (err?.status === 403) {
      this.actionError.set('You do not have permission to perform this action.');
    } else if (err?.status === 404) {
      this.actionError.set('This player no longer exists.');
    } else if (err?.status === 409) {
      this.actionError.set(serverMessage(err) || 'Conflict — the change was blocked.');
    } else {
      this.actionError.set('Could not reach the server. Nothing was changed — retry.');
    }
  }

  // --- Phase D: wallet adjustment --------------------------------------------

  get canAdjust(): boolean {
    const role = this.auth.user?.role;
    return (role === 'ADMIN' || role === 'MODERATOR') && this.wallet() !== null;
  }

  get signedAdjustAmount(): number {
    const n = Number(this.adjustAmount);
    if (!Number.isInteger(n) || n <= 0) return 0;
    return this.adjustDirection === 'credit' ? n : -n;
  }

  get proposedBalance(): number | null {
    const w = this.wallet();
    const amount = this.signedAdjustAmount;
    if (!w || amount === 0) return null;
    return w.balance + amount;
  }

  get adjustLarge(): boolean {
    return Math.abs(this.signedAdjustAmount) >= this.adjustThreshold;
  }

  get adjustOverdraws(): boolean {
    const proposed = this.proposedBalance;
    return proposed !== null && proposed < 0;
  }

  openAdjust(): void {
    this.adjustOpen.set(true);
    this.adjustReview.set(null);
    this.adjustError.set(null);
    this.adjustDirection = 'credit';
    this.adjustAmount = '';
    this.adjustReason = '';
    this.adjustConfirmText = '';
  }

  cancelAdjust(): void {
    this.adjustOpen.set(false);
    this.adjustReview.set(null);
    this.adjustError.set(null);
  }

  reviewAdjust(): void {
    const amount = this.signedAdjustAmount;
    if (amount === 0) {
      this.adjustError.set('Enter a whole number of coins greater than zero.');
      return;
    }
    const reason = this.adjustReason.trim();
    if (!reason) {
      this.adjustError.set('A reason is required — it is stored on the ledger and in the audit log.');
      return;
    }
    if (this.adjustOverdraws) {
      this.adjustError.set('This debit would overdraw the wallet — reduce the amount.');
      return;
    }
    const large = this.adjustLarge;
    if (large && !this.isAdmin) {
      this.adjustError.set(
        `Adjustments of ${this.adjustThreshold.toLocaleString('en-US')} coins or more are restricted to administrators.`,
      );
      return;
    }
    this.adjustError.set(null);
    this.adjustConfirmText = '';
    this.adjustReview.set({
      amount,
      reason,
      proposed: this.proposedBalance ?? 0,
      large,
      key: this.newIdempotencyKey(),
    });
  }

  backToEditAdjust(): void {
    this.adjustReview.set(null);
    this.adjustConfirmText = '';
    this.adjustError.set(null);
  }

  confirmAdjust(): void {
    const review = this.adjustReview();
    if (!review || this.adjustBusy()) return;
    if (review.large && this.adjustConfirmText.trim() !== 'ADJUST') {
      this.adjustError.set('Type ADJUST to confirm this large adjustment.');
      return;
    }

    this.adjustBusy.set(true);
    this.adjustError.set(null);
    this.http
      .post<AdjustResult>(`/api/v1/admin/wallets/${this.userId}/adjust`, {
        amount: review.amount,
        reason: review.reason,
        idempotencyKey: review.key,
      })
      .subscribe({
        next: (res) => {
          this.adjustBusy.set(false);
          this.adjustOpen.set(false);
          this.adjustReview.set(null);
          this.actionSuccess.set(
            res.replayed
              ? 'Duplicate request — this adjustment was already applied and was not counted twice.'
              : `Balance updated to ${res.balance.toLocaleString('en-US')} coins.`,
          );
          this.load();
        },
        error: (err: { status?: number; message?: string }) => {
          this.adjustBusy.set(false);
          if (err?.status === 400) {
            this.adjustError.set(serverMessage(err) || 'The adjustment was rejected. Check the values and retry.');
          } else if (err?.status === 401) {
            this.adjustError.set('Your session has expired. Sign in again.');
          } else if (err?.status === 403) {
            this.adjustError.set(serverMessage(err) || 'You do not have permission to make this adjustment.');
          } else if (err?.status === 404) {
            this.adjustError.set('This player no longer exists.');
          } else if (err?.status === 409) {
            this.adjustError.set(serverMessage(err) || 'The wallet is busy — retry the same adjustment.');
          } else if (err?.status === 422) {
            this.adjustError.set(serverMessage(err) || 'Insufficient balance.');
          } else {
            this.adjustError.set('Could not reach the server. Nothing was changed — retry.');
          }
        },
      });
  }

  private newIdempotencyKey(): string {
    const cryptoRef = globalThis.crypto as { randomUUID?: () => string } | undefined;
    if (cryptoRef?.randomUUID) return `adj-${cryptoRef.randomUUID()}`;
    return `adj-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`;
  }

  private loadThreshold(): void {
    this.http.get<{ items: ConfigEntry[] }>('/api/v1/admin/config').subscribe({
      next: (res) => {
        const entry = res.items.find((row) => row.key === THRESHOLD_KEY);
        if (entry && typeof entry.value === 'number') this.adjustThreshold = entry.value;
      },
      error: () => undefined,
    });
  }

  // --- Moderation notes -------------------------------------------------------

  addNote(): void {
    const body = this.noteBody.trim();
    if (!body) {
      this.noteError.set('A note must not be empty.');
      return;
    }
    this.noteError.set(null);
    this.actionSuccess.set(null);
    this.http
      .post<ModerationNote>(`/api/v1/admin/users/${this.userId}/notes`, { body })
      .subscribe({
        next: () => {
          this.noteBody = '';
          this.actionSuccess.set('Moderation note added.');
          this.notePage = 1;
          this.loadNotes();
        },
        error: (err: { status?: number; message?: string }) => {
          if (err?.status === 400) {
            this.noteError.set(serverMessage(err) || 'The note was rejected.');
          } else if (err?.status === 401) {
            this.noteError.set('Your session has expired. Sign in again.');
          } else if (err?.status === 403) {
            this.noteError.set('You do not have permission to write moderation notes.');
          } else if (err?.status === 404) {
            this.noteError.set('This player no longer exists.');
          } else {
            this.noteError.set('Could not reach the server. The note was not saved.');
          }
        },
      });
  }

  // --- Display helpers --------------------------------------------------------

  walletTotalPages(): number {
    return this.txPages();
  }

  formatMatchPlayers(match: PlayerMatchRow): string {
    if (!match.players || match.players.length === 0) return '—';
    return match.players
      .map((p) => `${p.user.username}: ${p.result}${p.score ? ` (${p.score})` : ''}`)
      .join(', ');
  }
}
