import { Injectable } from '@nestjs/common';
import { Subject, Observable } from 'rxjs';

export interface MatchMoveEvent {
  matchId: string;
  seq: number;
  stateVersion: number;
  userId: string;
  payload: unknown;
  at: string;
}

export interface MatchStatusEvent {
  matchId: string;
  status: string;
  stateVersion: number;
  at: string;
}

export type MatchEvent =
  { kind: 'move'; data: MatchMoveEvent } | { kind: 'status'; data: MatchStatusEvent };

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
