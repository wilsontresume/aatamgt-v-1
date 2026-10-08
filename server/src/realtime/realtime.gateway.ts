import { Logger, UsePipes, ValidationPipe } from '@nestjs/common';
import {
  OnGatewayConnection,
  OnGatewayDisconnect,
  WebSocketGateway,
  WebSocketServer,
  ConnectedSocket,
  MessageBody,
  SubscribeMessage,
} from '@nestjs/websockets';
import { JwtService } from '@nestjs/jwt';
import { ConfigService } from '@nestjs/config';
import { Server, Socket } from 'socket.io';
import { MatchEventsService, MatchEvent } from '../events/match-events.service';
import { MatchesService, SubmitMoveDto } from '../matches/matches.service';
import { sideKeyForSeat } from '../matches/engine-adapters';
import { MatchClockService } from '../matches/match-clock.service';
import { AccessTokenPayload } from '../auth/auth.service';
import { AppConfig } from '../config/configuration';

interface SubscribePayload {
  matchId: string;
}

/**
 * Realtime transport for live matches. The gateway only moves bytes:
 * every rule, turn and result comes from MatchesService (the
 * authoritative layer) — nothing here decides legality or a winner.
 *
 * Presence: the last socket of a participant leaving an ACTIVE match
 * arms a disconnect grace clock; reconnecting (re-subscribe) cancels it
 * and grace expiry forfeits the absent player.
 */
@WebSocketGateway({
  namespace: '/ws',
  cors: { origin: true, credentials: true },
})
@UsePipes(new ValidationPipe({ whitelist: true, transform: true }))
export class RealtimeGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer() server: Server;

  private readonly logger = new Logger('RealtimeGateway');
  private readonly cfg: AppConfig;

  /** matchId → userId → socket ids (a participant may hold several). */
  private readonly presence = new Map<string, Map<string, Set<string>>>();
  /** socketId → its current match subscription. */
  private readonly socketSub = new Map<string, { matchId: string; userId: string }>();

  constructor(
    private readonly jwt: JwtService,
    config: ConfigService,
    private readonly matches: MatchesService,
    private readonly events: MatchEventsService,
    private readonly clock: MatchClockService,
  ) {
    this.cfg = config.get<AppConfig>('app') as AppConfig;
    this.events.events$.subscribe((event) => this.broadcast(event));
  }

  async handleConnection(client: Socket): Promise<void> {
    const token =
      (client.handshake.auth?.token as string | undefined) ??
      (client.handshake.headers.authorization ?? '').replace(/^Bearer\s+/i, '');

    if (!token) {
      this.reject(client, 'missing token');
      return;
    }

    try {
      const payload = await this.jwt.verifyAsync<AccessTokenPayload>(token, {
        secret: this.cfg.jwt.accessSecret,
      });
      client.data.userId = payload.sub;
      client.data.username = payload.username;
      client.emit('connected', { userId: payload.sub, username: payload.username });
    } catch {
      this.reject(client, 'invalid token');
    }
  }

  handleDisconnect(client: Socket): void {
    this.logger.debug(`socket disconnected ${client.id}`);
    const sub = this.socketSub.get(client.id);
    if (!sub) return;
    this.socketSub.delete(client.id);
    if (this.removePresence(sub.matchId, sub.userId, client.id)) {
      this.events.publish({
        kind: 'presence',
        data: {
          matchId: sub.matchId,
          userId: sub.userId,
          connected: false,
          at: new Date().toISOString(),
        },
      });
      const graceMs = this.cfg.match.disconnectGraceMs;
      this.clock.armDisconnect(sub.matchId, sub.userId, graceMs, () => {
        if (this.hasPresence(sub.matchId, sub.userId)) return;
        void this.matches.forfeitByDisconnect(sub.matchId, sub.userId).catch((error) => {
          this.logger.error(`disconnect forfeit failed: ${String(error)}`);
        });
      });
    }
  }

  @SubscribeMessage('match:subscribe')
  async onSubscribe(@MessageBody() body: SubscribePayload, @ConnectedSocket() client: Socket) {
    const userId = this.userId(client);
    if (!body?.matchId) return { ok: false, error: 'matchId is required' };

    const match = await this.matches.getMatch(body.matchId, { includeHistory: 200 });
    const player = match.players.find((p) => p.userId === userId);
    if (!player) return { ok: false, error: 'not a participant' };

    const previous = this.socketSub.get(client.id);
    if (previous && previous.matchId !== match.id) {
      if (this.removePresence(previous.matchId, previous.userId, client.id)) {
        this.events.publish({
          kind: 'presence',
          data: {
            matchId: previous.matchId,
            userId: previous.userId,
            connected: false,
            at: new Date().toISOString(),
          },
        });
      }
    }

    await client.join(this.room(match.id));
    this.socketSub.set(client.id, { matchId: match.id, userId });
    const rejoined = this.addPresence(match.id, userId, client.id);
    if (rejoined) {
      this.clock.disarmDisconnect(match.id, userId);
      this.events.publish({
        kind: 'presence',
        data: {
          matchId: match.id,
          userId,
          connected: true,
          at: new Date().toISOString(),
        },
      });
    }
    await this.matches.ensureTurnClock(match.id);

    return {
      ok: true,
      matchId: match.id,
      status: match.status,
      stateVersion: match.stateVersion,
      seat: player.seat,
      side: sideKeyForSeat(match.gameKey, player.seat),
      serverState: match.serverState,
      players: match.players.map((p) => ({
        userId: p.userId,
        username: p.user.username,
        seat: p.seat,
        result: p.result,
      })),
      moves: match.moves.map((m) => ({
        seq: m.seq,
        userId: m.userId,
        payload: m.payload,
        serverAt: m.serverAt.toISOString(),
      })),
      presence: this.presenceFor(match.id),
    };
  }

  @SubscribeMessage('match:move')
  async onMove(
    @MessageBody() body: SubmitMoveDto & SubscribePayload,
    @ConnectedSocket() client: Socket,
  ) {
    const userId = this.userId(client);
    if (!body?.matchId) return { ok: false, error: 'matchId is required' };
    try {
      const result = await this.matches.submitMove(userId, body.matchId, {
        payload: body.payload,
        clientSeq: body.clientSeq,
      });
      return { ok: true, ...result };
    } catch (error) {
      const message = error instanceof Error ? error.message : 'move rejected';
      return { ok: false, error: message };
    }
  }

  @SubscribeMessage('match:resign')
  async onResign(@MessageBody() body: SubscribePayload, @ConnectedSocket() client: Socket) {
    const userId = this.userId(client);
    if (!body?.matchId) return { ok: false, error: 'matchId is required' };
    try {
      const outcome = await this.matches.resign(userId, body.matchId);
      return {
        ok: true,
        matchId: body.matchId,
        stateVersion: outcome.stateVersion,
        completed: {
          reason: outcome.completion.reason,
          winnerSeat: outcome.completion.winnerSeat,
          results: Object.fromEntries(outcome.results),
        },
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : 'resign failed';
      return { ok: false, error: message };
    }
  }

  @SubscribeMessage('match:rematch')
  async onRematch(@MessageBody() body: SubscribePayload, @ConnectedSocket() client: Socket) {
    const userId = this.userId(client);
    if (!body?.matchId) return { ok: false, error: 'matchId is required' };
    try {
      const match = await this.matches.rematch(userId, body.matchId);
      return {
        ok: true,
        matchId: match.id,
        status: match.status,
        players: match.players.map((p) => ({ userId: p.userId, seat: p.seat })),
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : 'rematch failed';
      return { ok: false, error: message };
    }
  }

  @SubscribeMessage('ping')
  onPing() {
    return { ok: true, at: new Date().toISOString() };
  }

  private broadcast(event: MatchEvent): void {
    if (!this.server) return;
    switch (event.kind) {
      case 'move':
        this.server.to(this.room(event.data.matchId)).emit('match:moved', event.data);
        return;
      case 'status':
        this.server.to(this.room(event.data.matchId)).emit('match:status', event.data);
        return;
      case 'presence':
        this.server.to(this.room(event.data.matchId)).emit('match:presence', event.data);
        return;
      case 'rematch':
        this.server.to(this.room(event.data.matchId)).emit('match:rematch', event.data);
        return;
    }
  }

  private room(matchId: string): string {
    return `match:${matchId}`;
  }

  private userId(client: Socket): string {
    const userId = client.data?.userId as string | undefined;
    if (!userId) throw new Error('unauthorized');
    return userId;
  }

  private reject(client: Socket, reason: string): void {
    client.emit('error', { code: 'unauthorized', reason });
    client.disconnect(true);
  }

  // --- presence ----------------------------------------------------------

  private addPresence(matchId: string, userId: string, socketId: string): boolean {
    let byUser = this.presence.get(matchId);
    if (!byUser) {
      byUser = new Map();
      this.presence.set(matchId, byUser);
    }
    let sockets = byUser.get(userId);
    if (!sockets) {
      sockets = new Set();
      byUser.set(userId, sockets);
    }
    const wasAbsent = sockets.size === 0;
    sockets.add(socketId);
    return wasAbsent;
  }

  private removePresence(matchId: string, userId: string, socketId: string): boolean {
    const byUser = this.presence.get(matchId);
    const sockets = byUser?.get(userId);
    if (!sockets || !sockets.delete(socketId)) return false;
    if (sockets.size === 0) {
      byUser?.delete(userId);
      if (byUser && byUser.size === 0) this.presence.delete(matchId);
      return true;
    }
    return false;
  }

  private hasPresence(matchId: string, userId: string): boolean {
    return (this.presence.get(matchId)?.get(userId)?.size ?? 0) > 0;
  }

  private presenceFor(matchId: string): Record<string, boolean> {
    const out: Record<string, boolean> = {};
    for (const [userId, sockets] of this.presence.get(matchId) ?? []) {
      out[userId] = sockets.size > 0;
    }
    return out;
  }
}
