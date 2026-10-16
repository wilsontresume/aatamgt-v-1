import { Component, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { HttpClient, HttpParams } from '@angular/common/http';
import { AdminUser, Paginated } from '../core/models';
import { serverMessage } from '../core/http-error';

type LoadState = 'loading' | 'ready' | 'error';

@Component({
  selector: 'app-user-list',
  standalone: true,
  imports: [CommonModule, FormsModule, RouterLink],
  templateUrl: './user-list.html',
  styleUrl: './user-list.scss',
})
export class UserListPage implements OnInit {
  readonly state = signal<LoadState>('loading');
  readonly data = signal<Paginated<AdminUser> | null>(null);
  readonly errorMessage = signal<string | null>(null);

  q = '';
  accountType = '';
  status = '';
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
    return this.q.trim() !== '' || this.accountType !== '' || this.status !== '';
  }

  load(): void {
    this.state.set('loading');
    this.errorMessage.set(null);

    let params = new HttpParams().set('page', String(this.page)).set('limit', String(this.limit));
    const q = this.q.trim();
    if (q) params = params.set('q', q);
    if (this.accountType) params = params.set('accountType', this.accountType);
    if (this.status) params = params.set('status', this.status);

    this.http.get<Paginated<AdminUser>>('/api/v1/admin/users', { params }).subscribe({
      next: (res) => {
        this.data.set(res);
        this.state.set('ready');
      },
      error: (err: { status?: number; message?: string }) => {
        if (err?.status === 401) {
          this.errorMessage.set('Your session has expired. Sign in again.');
        } else if (err?.status === 403) {
          this.errorMessage.set('You do not have permission to view users.');
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
    this.q = '';
    this.accountType = '';
    this.status = '';
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

  statsLabel(user: AdminUser): string {
    if (!user.stats) return '—';
    return `${user.stats.wins}W · ${user.stats.losses}L · ${user.stats.draws}D`;
  }
}
