import { Injectable } from '@nestjs/common';

/**
 * Tracks which user ids currently hold an authenticated websocket.
 * Friends lists and challenge UIs use this for a soft "online" flag —
 * it is never used for matchmaking eligibility or security decisions.
 */
@Injectable()
export class UserPresenceService {
  /** userId → set of socket ids. */
  private readonly sockets = new Map<string, Set<string>>();

  add(userId: string, socketId: string): void {
    let set = this.sockets.get(userId);
    if (!set) {
      set = new Set();
      this.sockets.set(userId, set);
    }
    set.add(socketId);
  }

  remove(userId: string, socketId: string): void {
    const set = this.sockets.get(userId);
    if (!set) return;
    set.delete(socketId);
    if (set.size === 0) this.sockets.delete(userId);
  }

  isOnline(userId: string): boolean {
    return (this.sockets.get(userId)?.size ?? 0) > 0;
  }

  /** Soft online flags for a list of user ids (used by friends list). */
  onlineFlags(userIds: readonly string[]): Record<string, boolean> {
    const out: Record<string, boolean> = {};
    for (const id of userIds) out[id] = this.isOnline(id);
    return out;
  }
}
