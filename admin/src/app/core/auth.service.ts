import { Injectable, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';
import { LoginResponse, PublicUser, Session } from './models';

const STORAGE_KEY = 'aatamgt.admin.session';

@Injectable({ providedIn: 'root' })
export class AuthService {
  readonly session = signal<Session | null>(this.restore());
  private refreshInFlight: Promise<Session | null> | null = null;

  constructor(private readonly http: HttpClient) {}

  get user(): PublicUser | null {
    return this.session()?.user ?? null;
  }

  get isStaff(): boolean {
    const role = this.user?.role;
    return role === 'ADMIN' || role === 'MODERATOR';
  }

  async login(identifier: string, password: string): Promise<PublicUser> {
    const res = await firstValueFrom(
      this.http.post<LoginResponse>('/api/v1/auth/login', { identifier, password }),
    );
    this.persist({
      user: res.user,
      accessToken: res.accessToken,
      refreshToken: res.refreshToken,
      expiresAt: Date.now() + res.expiresIn * 1000,
    });
    return res.user;
  }

  logout(): void {
    this.session.set(null);
    localStorage.removeItem(STORAGE_KEY);
  }

  /** Single-flight refresh: concurrent 401s share one refresh request. */
  refreshTokens(): Promise<Session | null> {
    if (!this.refreshInFlight) {
      this.refreshInFlight = this.doRefresh().finally(() => {
        this.refreshInFlight = null;
      });
    }
    return this.refreshInFlight;
  }

  private async doRefresh(): Promise<Session | null> {
    const current = this.session();
    if (!current) return null;
    try {
      const res = await firstValueFrom(
        this.http.post<{ accessToken: string; refreshToken: string; expiresIn: number }>(
          '/api/v1/auth/refresh',
          { refreshToken: current.refreshToken },
        ),
      );
      const next: Session = {
        user: current.user,
        accessToken: res.accessToken,
        refreshToken: res.refreshToken,
        expiresAt: Date.now() + res.expiresIn * 1000,
      };
      this.persist(next);
      return next;
    } catch {
      this.logout();
      return null;
    }
  }

  private persist(session: Session): void {
    this.session.set(session);
    localStorage.setItem(STORAGE_KEY, JSON.stringify(session));
  }

  private restore(): Session | null {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw) as Session;
      if (!parsed?.accessToken || !parsed?.user) return null;
      return parsed;
    } catch {
      return null;
    }
  }
}
