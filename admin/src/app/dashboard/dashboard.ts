import { Component, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient, HttpParams } from '@angular/common/http';
import { BarChart, ChartRow } from './bar-chart';
import { DashboardResponse, GameOption } from '../core/models';

type LoadState = 'loading' | 'ready' | 'error';

function isoDay(d: Date): string {
  return d.toISOString().slice(0, 10);
}

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule, FormsModule, BarChart],
  templateUrl: './dashboard.html',
  styleUrl: './dashboard.scss',
})
export class DashboardPage implements OnInit {
  readonly state = signal<LoadState>('loading');
  readonly data = signal<DashboardResponse | null>(null);
  readonly errorMessage = signal<string | null>(null);
  readonly games = signal<GameOption[]>([]);

  from = '';
  to = '';
  gameKey = '';

  private readonly defaultFrom: string;
  private readonly defaultTo: string;

  constructor(private readonly http: HttpClient) {
    const today = new Date();
    const start = new Date(today.getTime() - 13 * 86_400_000);
    this.defaultFrom = isoDay(start);
    this.defaultTo = isoDay(today);
    this.from = this.defaultFrom;
    this.to = this.defaultTo;
  }

  ngOnInit(): void {
    this.http.get<{ items: GameOption[] }>('/api/v1/games').subscribe({
      next: (res) => this.games.set(res.items),
      error: () => this.games.set([]),
    });
    this.load();
  }

  get rangeDays(): number {
    if (!this.from || !this.to) return 14;
    const ms = Date.parse(`${this.to}T00:00:00Z`) - Date.parse(`${this.from}T00:00:00Z`);
    return Math.round(ms / 86_400_000) + 1;
  }

  get isEmptyRange(): boolean {
    const d = this.data();
    if (!d) return false;
    return (
      d.users.registeredInRange === 0 &&
      d.matches.totalInRange === 0 &&
      d.economy.transactionsInRange === 0
    );
  }

  get showDefaultRange(): boolean {
    return this.from === this.defaultFrom && this.to === this.defaultTo;
  }

  load(): void {
    this.state.set('loading');
    this.errorMessage.set(null);

    let params = new HttpParams();
    if (this.from) params = params.set('from', this.from);
    if (this.to) params = params.set('to', this.to);
    if (this.gameKey) params = params.set('gameKey', this.gameKey);

    this.http.get<DashboardResponse>('/api/v1/admin/dashboard', { params }).subscribe({
      next: (res) => {
        this.data.set(res);
        this.state.set('ready');
      },
      error: (err: { status?: number; message?: string }) => {
        if (err?.status === 401) {
          this.errorMessage.set('Your session has expired. Sign in again.');
        } else if (err?.status === 403) {
          this.errorMessage.set('You do not have permission to view this dashboard.');
        } else if (err?.status === 404) {
          this.errorMessage.set('Unknown game filter.');
        } else if (err?.status === 400) {
          this.errorMessage.set(err.message || 'Invalid filter values.');
        } else {
          this.errorMessage.set('Could not reach the server. Check the backend and retry.');
        }
        this.state.set('error');
      },
    });
  }

  resetFilters(): void {
    this.from = this.defaultFrom;
    this.to = this.defaultTo;
    this.gameKey = '';
    this.load();
  }

  registrationRows(): ChartRow[] {
    const rows = this.data()?.users.registrations ?? [];
    return rows.map((r) => ({ label: r.date.slice(5), value: r.count }));
  }

  grantRows(): ChartRow[] {
    const rows = this.data()?.economy.grantsPerDay ?? [];
    return rows.map((r) => ({ label: r.date.slice(5), value: r.amount ?? 0 }));
  }

  statusRows(): { status: string; count: number }[] {
    const byStatus = this.data()?.matches.byStatus ?? {};
    return Object.entries(byStatus)
      .map(([status, count]) => ({ status, count }))
      .sort((a, b) => b.count - a.count);
  }

  fmt(n: number): string {
    return n.toLocaleString('en-US');
  }

  signed(n: number): string {
    return `${n > 0 ? '+' : ''}${n.toLocaleString('en-US')}`;
  }
}
