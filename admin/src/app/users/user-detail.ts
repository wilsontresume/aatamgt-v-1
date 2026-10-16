import { Component, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { HttpClient, HttpParams } from '@angular/common/http';
import { AuthService } from '../core/auth.service';
import { serverMessage } from '../core/http-error';
import {
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
