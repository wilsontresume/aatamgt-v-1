import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { MatchEventsService } from '../events/match-events.service';
import { MatchesService, EngineServerState } from '../matches/matches.service';
import { getAdapter } from '../matches/engine-adapters';
import { chooseAiMove } from '../ai/ai-move';
import { AppConfig } from '../config/configuration';

/**
 * Drives server-side AI turns for matches that contain an AI seat.
 *
 * After every accepted human move (and on activation) the driver checks
 * whether the side to move is the AI seat; if so it waits a short delay
 * (so the client can render the previous move), picks a legal move via
 * the same rules engine and submits it through MatchesService — which
 * re-validates everything authoritatively. The client never decides the
 * AI's move or the match result.
 */
@Injectable()
export class MatchAiDriver {
  private readonly logger = new Logger(MatchAiDriver.name);
  private readonly cfg: AppConfig;
  private readonly scheduled = new Set<string>();

  constructor(
    private readonly matches: MatchesService,
    private readonly events: MatchEventsService,
    config: ConfigService,
  ) {
    this.cfg = config.get<AppConfig>('app') as AppConfig;
    this.events.events$.subscribe((event) => {
      if (event.kind === 'move' || event.kind === 'status') {
        this.maybeSchedule(event.data.matchId as string);
      }
    });
  }

  /** Public hook: called after activation and after every accepted move. */
  maybeSchedule(matchId: string): void {
    if (!matchId || this.scheduled.has(matchId)) return;
    this.scheduled.add(matchId);
    void this.run(matchId).finally(() => this.scheduled.delete(matchId));
  }

  private async run(matchId: string): Promise<void> {
    try {
      const match = await this.matches.getMatch(matchId, { includeHistory: 0 });
      if (match.status !== 'ACTIVE') return;
      const aiSeat = match.players.find((p) => p.isAi);
      if (!aiSeat) return;

      const adapter = getAdapter(match.gameKey);
      const serverState = match.serverState as EngineServerState | null;
      if (!adapter || !serverState?.state) return;
      const view = adapter.load(serverState.state);
      if (!view || view.finished || view.seatToMove !== aiSeat.seat) return;

      const delay = this.cfg.matchmaking.aiMoveDelayMs;
      if (delay > 0) await new Promise((r) => setTimeout(r, delay));

      // Re-check: the match may have finished or the human may have left.
      const fresh = await this.matches.getMatch(matchId, { includeHistory: 0 });
      if (fresh.status !== 'ACTIVE') return;
      const freshState = fresh.serverState as EngineServerState | null;
      const freshView = freshState ? adapter.load(freshState.state) : null;
      if (!freshView || freshView.finished || freshView.seatToMove !== aiSeat.seat) return;

      const payload = chooseAiMove(match.gameKey, freshState!.state);
      if (!payload) {
        this.logger.warn(`AI has no legal move in ${matchId}`);
        return;
      }

      await this.matches.submitAiMove(matchId, aiSeat.id, payload);
      this.logger.log(`AI move applied in ${matchId}`);
    } catch (error) {
      this.logger.error(`AI driver failed for ${matchId}: ${String(error)}`);
    }
  }
}
