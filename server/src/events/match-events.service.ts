import { Injectable } from '@nestjs/common';
import { Subject, Observable } from 'rxjs';
import type { EngineSideKey } from '../matches/engine-adapters';

export interface MatchMoveEvent {
  matchId: string;
  seq: number;
  stateVersion: number;
  userId: string;
  payload: unknown;
  at: string;
  /** Engine game: canonical notation of the accepted move. */
  notation?: string;
  /** Engine game: full serialized state after the move (server truth). */
  state?: unknown;
  sideToMove?: EngineSideKey;
  turnDeadlineAt?: string;
}

export interface MatchStatusEvent {
  matchId: string;
  status: string;
  stateVersion: number;
  at: string;
  /** Present when the match reached a server-decided result. */
  completed?: {
    reason: 'RULES' | 'RESIGN' | 'TIMEOUT' | 'DISCONNECT';
    winnerSeat: number | null;
    results: Record<string, 'WIN' | 'LOSS' | 'DRAW'>;
  };
}

export interface MatchPresenceEvent {
  matchId: string;
  userId: string;
  connected: boolean;
  at: string;
}

export interface MatchRematchEvent {
  matchId: string;
  newMatchId: string;
  at: string;
}

export type MatchEvent =
  | { kind: 'move'; data: MatchMoveEvent }
  | { kind: 'status'; data: MatchStatusEvent }
  | { kind: 'presence'; data: MatchPresenceEvent }
  | { kind: 'rematch'; data: MatchRematchEvent };

@Injectable()
export class MatchEventsService {
  private readonly subject = new Subject<MatchEvent>();

  get events$(): Observable<MatchEvent> {
    return this.subject.asObservable();
  }

  publish(event: MatchEvent): void {
    this.subject.next(event);
  }
}
