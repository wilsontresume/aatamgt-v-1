import { Injectable, OnModuleDestroy } from '@nestjs/common';

/**
 * Server-side clocks for live matches:
 *  - one turn timer per ACTIVE match (turn timeout → forfeit);
 *  - one disconnect-grace timer per absent participant (grace expiry →
 *    forfeit on reconnection failure).
 *
 * Every timer re-checks its precondition inside the callback before
 * acting, so a stale timer can never finish a match twice.
 */
@Injectable()
export class MatchClockService implements OnModuleDestroy {
  private readonly turnTimers = new Map<string, NodeJS.Timeout>();
  private readonly disconnectTimers = new Map<string, NodeJS.Timeout>();

  armTurn(matchId: string, deadlineAt: Date, onExpired: () => void): void {
    this.disarmTurn(matchId);
    const delay = Math.max(0, deadlineAt.getTime() - Date.now());
    const timer = setTimeout(() => {
      this.turnTimers.delete(matchId);
      onExpired();
    }, delay);
    // Never hold the process open just for a match clock.
    if (typeof timer.unref === 'function') timer.unref();
    this.turnTimers.set(matchId, timer);
  }

  disarmTurn(matchId: string): void {
    const timer = this.turnTimers.get(matchId);
    if (timer) {
      clearTimeout(timer);
      this.turnTimers.delete(matchId);
    }
  }

  armDisconnect(matchId: string, userId: string, graceMs: number, onExpired: () => void): void {
    this.disarmDisconnect(matchId, userId);
    const timer = setTimeout(() => {
      this.disconnectTimers.delete(this.disconnectKey(matchId, userId));
      onExpired();
    }, Math.max(0, graceMs));
    if (typeof timer.unref === 'function') timer.unref();
    this.disconnectTimers.set(this.disconnectKey(matchId, userId), timer);
  }

  disarmDisconnect(matchId: string, userId: string): void {
    const key = this.disconnectKey(matchId, userId);
    const timer = this.disconnectTimers.get(key);
    if (timer) {
      clearTimeout(timer);
      this.disconnectTimers.delete(key);
    }
  }

  hasDisconnect(matchId: string, userId: string): boolean {
    return this.disconnectTimers.has(this.disconnectKey(matchId, userId));
  }

  /** Clears every timer tied to a match (completion or teardown). */
  disarmMatch(matchId: string): void {
    this.disarmTurn(matchId);
    for (const key of [...this.disconnectTimers.keys()]) {
      if (key.startsWith(`${matchId}:`)) {
        const timer = this.disconnectTimers.get(key);
        if (timer) clearTimeout(timer);
        this.disconnectTimers.delete(key);
      }
    }
  }

  onModuleDestroy(): void {
    for (const timer of [...this.turnTimers.values(), ...this.disconnectTimers.values()]) {
      clearTimeout(timer);
    }
    this.turnTimers.clear();
    this.disconnectTimers.clear();
  }

  private disconnectKey(matchId: string, userId: string): string {
    return `${matchId}:${userId}`;
  }
}
