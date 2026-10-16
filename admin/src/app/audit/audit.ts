import { Component, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient, HttpParams } from '@angular/common/http';
import { AuditRow, Paginated } from '../core/models';
import { serverMessage } from '../core/http-error';

type LoadState = 'loading' | 'ready' | 'error';

const KNOWN_ACTIONS = [
  'user.status',
  'user.role',
  'user.sessions.revoke',
  'moderation.note.create',
  'wallet.adjust',
  'match.finalize',
  'cosmetic.update',
  'config.set',
];

const DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

@Component({
  selector: 'app-audit',
  standalone: true,
  imports: [CommonModule, FormsModule],
  templateUrl: './audit.html',
  styleUrl: './audit.scss',
})
export class AuditPage implements OnInit {
  readonly state = signal<LoadState>('loading');
  readonly data = signal<Paginated<AuditRow> | null>(null);
  readonly errorMessage = signal<string | null>(null);
  readonly knownActions = KNOWN_ACTIONS;

  action = '';
  actor = '';
  from = '';
  to = '';
  page = 1;
  readonly limit = 25;

  constructor(private readonly http: HttpClient) {}

  ngOnInit(): void {
    this.load();
  }

  get totalPages(): number {
    const d = this.data();
    if (!d || d.total === 0) return 1;
    return Math.ceil(d.total / d.limit);
  }

  get hasFilters(): boolean {
    return this.action !== '' || this.actor.trim() !== '' || this.from !== '' || this.to !== '';
  }

  load(): void {
    this.state.set('loading');
    this.errorMessage.set(null);

    for (const [name, value] of [
      ['from', this.from],
      ['to', this.to],
    ] as const) {
      if (value && !DAY_PATTERN.test(value)) {
        this.errorMessage.set(`Invalid ${name} date — use YYYY-MM-DD.`);
        this.state.set('error');
        return;
      }
    }

    let params = new HttpParams().set('page', String(this.page)).set('limit', String(this.limit));
    if (this.action) params = params.set('action', this.action);
    const actor = this.actor.trim();
    if (actor) params = params.set('actor', actor);
    if (this.from) params = params.set('from', this.from);
    if (this.to) params = params.set('to', this.to);

    this.http.get<Paginated<AuditRow>>('/api/v1/admin/audit', { params }).subscribe({
      next: (res) => {
        this.data.set(res);
        this.state.set('ready');
      },
      error: (err: { status?: number; message?: string }) => {
        if (err?.status === 401) {
          this.errorMessage.set('Your session has expired. Sign in again.');
        } else if (err?.status === 403) {
          this.errorMessage.set('Audit history is restricted to administrators.');
        } else if (err?.status === 400) {
          this.errorMessage.set(serverMessage(err) || 'Invalid filter values.');
        } else {
          this.errorMessage.set('Could not reach the server. Check the backend and retry.');
        }
        this.state.set('error');
      },
    });
  }

  applyFilters(): void {
    this.page = 1;
    this.load();
  }

  resetFilters(): void {
    this.action = '';
    this.actor = '';
    this.from = '';
    this.to = '';
    this.page = 1;
    this.load();
  }

  prevPage(): void {
    if (this.page > 1) {
      this.page -= 1;
      this.load();
    }
  }

  nextPage(): void {
    if (this.page < this.totalPages) {
      this.page += 1;
      this.load();
    }
  }

  /** Human-readable before/after for known actions; honest JSON otherwise. */
  describe(row: AuditRow): string {
    const data = row.data ?? {};
    switch (row.action) {
      case 'user.role': {
        const previous = typeof data['previous'] === 'string' ? data['previous'] : '?';
        const next = typeof data['next'] === 'string' ? data['next'] : '?';
        const revoked = typeof data['sessionsRevoked'] === 'number' ? data['sessionsRevoked'] : null;
        return `${previous} → ${next}${
          revoked !== null ? ` · ${revoked} session${revoked === 1 ? '' : 's'} revoked` : ''
        }`;
      }
      case 'user.status': {
        const previous = typeof data['previous'] === 'string' ? data['previous'] : '?';
        const status = typeof data['status'] === 'string' ? data['status'] : '?';
        const reason = typeof data['reason'] === 'string' && data['reason'] ? data['reason'] : null;
        return `${previous} → ${status}${reason ? ` · reason: ${reason}` : ' · no reason given'}`;
      }
      case 'user.sessions.revoke': {
        const revoked = typeof data['sessionsRevoked'] === 'number' ? data['sessionsRevoked'] : '?';
        return `${revoked} session${revoked === 1 ? '' : 's'} revoked`;
      }
      case 'moderation.note.create': {
        const preview = typeof data['preview'] === 'string' ? data['preview'] : null;
        return preview ? `note: “${preview}”` : 'moderation note created';
      }
      case 'wallet.adjust': {
        const amount = typeof data['amount'] === 'number' ? data['amount'] : null;
        const memo = typeof data['memo'] === 'string' && data['memo'] ? data['memo'] : null;
        if (amount === null) return this.json(data);
        return `${amount > 0 ? '+' : ''}${amount.toLocaleString('en-US')} coins${
          memo ? ` · ${memo}` : ''
        }`;
      }
      default:
        return this.json(data);
    }
  }

  private json(data: Record<string, unknown>): string {
    if (Object.keys(data).length === 0) return '—';
    return JSON.stringify(data);
  }

  targetLabel(row: AuditRow): string {
    if (!row.targetType && !row.targetId) return '—';
    return `${row.targetType ?? '—'}${row.targetId ? ` · ${row.targetId}` : ''}`;
  }
}
