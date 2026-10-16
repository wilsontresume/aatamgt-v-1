import { Component, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient, HttpParams } from '@angular/common/http';
import { RouterLink } from '@angular/router';
import { forkJoin } from 'rxjs';
import { BarChart, ChartRow } from '../dashboard/bar-chart';
import { AuthService } from '../core/auth.service';
import { serverMessage } from '../core/http-error';
import {
  ConfigEntry,
  EconomySummary,
  EconomyTrends,
  EconomyTx,
  Paginated,
} from '../core/models';

type LoadState = 'loading' | 'ready' | 'error';

const WALLET_TX_TYPES = [
  'REGISTRATION_BONUS',
  'DAILY_LOGIN',
  'REWARDED_AD',
  'MATCH_REWARD',
  'PURCHASE',
  'COSMETIC_PURCHASE',
  'ROYAL_PASS_BONUS',
  'ADMIN_ADJUSTMENT',
] as const;

const THRESHOLD_KEY = 'admin.wallet_adjust_threshold';
const DEFAULT_THRESHOLD = 100_000;

@Component({
  selector: 'app-economy',
  standalone: true,
  imports: [CommonModule, FormsModule, RouterLink, BarChart],
  templateUrl: './economy.html',
  styleUrl: './economy.scss',
})
export class EconomyPage implements OnInit {
  readonly state = signal<LoadState>('loading');
  readonly summary = signal<EconomySummary | null>(null);
  readonly trends = signal<EconomyTrends | null>(null);
  readonly tx = signal<Paginated<EconomyTx> | null>(null);
  readonly errorMessage = signal<string | null>(null);
  readonly threshold = signal<ConfigEntry | null>(null);
  readonly thresholdBusy = signal(false);
  readonly thresholdError = signal<string | null>(null);
  readonly thresholdSuccess = signal<string | null>(null);

  readonly txTypes = WALLET_TX_TYPES;

  from = '';
  to = '';
  typeFilter = '';
  playerFilter = '';
  thresholdDraft = 0;
  txPage = 1;
  readonly txLimit = 20;

  private readonly defaultFrom: string;
  private readonly defaultTo: string;

  constructor(
    private readonly http: HttpClient,
    readonly auth: AuthService,
  ) {
    const today = new Date();
    this.defaultTo = today.toISOString().slice(0, 10);
    this.defaultFrom = new Date(today.getTime() - 13 * 86_400_000).toISOString().slice(0, 10);
    this.from = this.defaultFrom;
    this.to = this.defaultTo;
  }

  ngOnInit(): void {
    this.load();
    this.loadConfig();
  }

  get thresholdValue(): number {
    const value = this.threshold()?.value;
    return typeof value === 'number' ? value : DEFAULT_THRESHOLD;
  }

  get isAdmin(): boolean {
    return this.auth.user?.role === 'ADMIN';
  }

  get rangeDays(): number {
    if (!this.from || !this.to) return 14;
    const ms = Date.parse(`${this.to}T00:00:00Z`) - Date.parse(`${this.from}T00:00:00Z`);
    return Math.round(ms / 86_400_000) + 1;
  }

  get filtersActive(): boolean {
    return (
      this.from !== this.defaultFrom ||
      this.to !== this.defaultTo ||
      !!this.typeFilter ||
      !!this.playerFilter.trim()
    );
  }

  load(): void {
    this.state.set('loading');
    this.errorMessage.set(null);

    const range = new HttpParams().set('from', this.from).set('to', this.to);
    let txParams = range;
    if (this.typeFilter) txParams = txParams.set('type', this.typeFilter);
    if (this.playerFilter.trim()) txParams = txParams.set('userId', this.playerFilter.trim());
    txParams = txParams.set('page', String(this.txPage)).set('limit', String(this.txLimit));

    forkJoin({
      summary: this.http.get<EconomySummary>('/api/v1/admin/economy/summary'),
      trends: this.http.get<EconomyTrends>('/api/v1/admin/economy/trends', { params: range }),
      tx: this.http.get<Paginated<EconomyTx>>('/api/v1/admin/economy/transactions', {
        params: txParams,
      }),
    }).subscribe({
      next: ({ summary, trends, tx }) => {
        this.summary.set(summary);
        this.trends.set(trends);
        this.tx.set(tx);
        this.state.set('ready');
      },
      error: (err: { status?: number; message?: string }) => {
        this.errorMessage.set(this.readError(err));
        this.state.set('error');
      },
    });
  }

  private readError(err: { status?: number; message?: string }): string {
    if (err?.status === 401) return 'Your session has expired. Sign in again.';
    if (err?.status === 403) return 'You do not have permission to view the economy.';
    if (err?.status === 400) return serverMessage(err) || 'Invalid filter values.';
    return 'Could not reach the server. Check the backend and retry.';
  }

  applyFilters(): void {
    this.txPage = 1;
    this.load();
  }

  resetFilters(): void {
    this.from = this.defaultFrom;
    this.to = this.defaultTo;
    this.typeFilter = '';
    this.playerFilter = '';
    this.txPage = 1;
    this.load();
  }

  prevTx(): void {
    if (this.txPage > 1) {
      this.txPage -= 1;
      this.load();
    }
  }

  nextTx(): void {
    if (this.txPages() > this.txPage) {
      this.txPage += 1;
      this.load();
    }
  }

  txPages(): number {
    const page = this.tx();
    if (!page || page.total === 0) return 1;
    return Math.ceil(page.total / page.limit);
  }

  issuedRows(): ChartRow[] {
    return (this.trends()?.points ?? []).map((p) => ({ label: p.day.slice(5), value: p.issued }));
  }

  spentRows(): ChartRow[] {
    return (this.trends()?.points ?? []).map((p) => ({ label: p.day.slice(5), value: p.spent }));
  }

  netRows(): ChartRow[] {
    return (this.trends()?.points ?? []).map((p) => ({
      label: p.day.slice(5),
      value: Math.max(0, p.net),
    }));
  }

  get netNegativeInRange(): boolean {
    return (this.trends()?.points ?? []).some((p) => p.net < 0);
  }

  fmt(n: number): string {
    return n.toLocaleString('en-US');
  }

  signed(n: number): string {
    return `${n > 0 ? '+' : ''}${n.toLocaleString('en-US')}`;
  }

  purchaseStates(): { state: string; count: number }[] {
    const byState = this.summary()?.purchases.byState ?? {};
    return Object.entries(byState)
      .map(([state, count]) => ({ state, count }))
      .sort((a, b) => b.count - a.count);
  }

  private loadConfig(): void {
    this.http.get<{ items: ConfigEntry[] }>('/api/v1/admin/config').subscribe({
      next: (res) => {
        const entry = res.items.find((row) => row.key === THRESHOLD_KEY) ?? null;
        this.threshold.set(entry);
        this.thresholdDraft = typeof entry?.value === 'number' ? entry.value : DEFAULT_THRESHOLD;
      },
      error: () => this.threshold.set(null),
    });
  }

  saveThreshold(): void {
    const value = Number(this.thresholdDraft);
    if (!Number.isInteger(value) || value < 1) {
      this.thresholdError.set('Threshold must be a whole number of at least 1 coin.');
      return;
    }
    this.thresholdBusy.set(true);
    this.thresholdError.set(null);
    this.thresholdSuccess.set(null);
    this.http
      .put('/api/v1/admin/config', {
        entries: [{ key: THRESHOLD_KEY, value }],
      })
      .subscribe({
        next: () => {
          this.thresholdBusy.set(false);
          this.thresholdSuccess.set(
            `Threshold saved — adjustments of ${this.fmt(value)} coins or more now require an administrator.`,
          );
          this.loadConfig();
        },
        error: (err: { status?: number; message?: string }) => {
          this.thresholdBusy.set(false);
          if (err?.status === 403) {
            this.thresholdError.set('Only administrators can change the threshold.');
          } else if (err?.status === 400) {
            this.thresholdError.set(serverMessage(err) || 'That value is out of range.');
          } else {
            this.thresholdError.set('Could not save the threshold. Check the backend and retry.');
          }
        },
      });
  }
}
