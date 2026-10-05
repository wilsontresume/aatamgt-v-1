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
import { AccessTokenPayload } from '../auth/auth.service';
import { AppConfig } from '../config/configuration';

interface SubscribePayload {
  matchId: string;
}

@WebSocketGateway({
  namespace: '/ws',
  cors: { origin: true, credentials: true },
})
@UsePipes(new ValidationPipe({ whitelist: true, transform: true }))
export class RealtimeGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer() server: Server;

  private readonly logger = new Logger('RealtimeGateway');
  private readonly cfg: AppConfig;

  constructor(
    private readonly jwt: JwtService,
    config: ConfigService,
    private readonly matches: MatchesService,
    private readonly events: MatchEventsService,
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
  }

  @SubscribeMessage('match:subscribe')
  async onSubscribe(@MessageBody() body: SubscribePayload, @ConnectedSocket() client: Socket) {
    const userId = this.userId(client);
    if (!body?.matchId) return { ok: false, error: 'matchId is required' };

    const match = await this.matches.getMatch(body.matchId, { includeHistory: 50 });
    const isParticipant = match.players.some((p) => p.userId === userId);
    if (!isParticipant) return { ok: false, error: 'not a participant' };

    await client.join(this.room(match.id));
    return {
      ok: true,
      matchId: match.id,
      status: match.status,
      stateVersion: match.stateVersion,
      players: match.players.length,
      moves: match.moves.length,
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

  @SubscribeMessage('ping')
  onPing() {
    return { ok: true, at: new Date().toISOString() };
  }

  private broadcast(event: MatchEvent): void {
    if (!this.server) return;
    if (event.kind === 'move') {
      this.server.to(this.room(event.data.matchId)).emit('match:moved', event.data);
      return;
    }
    this.server.to(this.room(event.data.matchId)).emit('match:status', event.data);
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
}
