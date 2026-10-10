import { INestApplication } from '@nestjs/common';
import { AddressInfo } from 'node:net';
import { io, Socket } from 'socket.io-client';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import {
  apiPrefix,
  auth,
  closePrisma,
  createGameFixture,
  prisma,
  registerUser,
} from '../helpers/fixtures';

function waitFor<T>(socket: Socket, event: string, timeoutMs = 5000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.off(event, handler);
      reject(new Error(`timed out waiting for ${event}`));
    }, timeoutMs);
    const handler = (payload: T) => {
      clearTimeout(timer);
      resolve(payload);
    };
    socket.once(event, handler);
  });
}

describe('Realtime gateway (integration)', () => {
  let app: INestApplication;
  let url: string;
  let alice: Awaited<ReturnType<typeof registerUser>>;
  let bob: Awaited<ReturnType<typeof registerUser>>;
  let outsider: Awaited<ReturnType<typeof registerUser>>;
  let matchId: string;

  beforeAll(async () => {
    app = await createTestApp();
    await app.listen(0, '127.0.0.1');
    const address = app.getHttpServer().address() as AddressInfo;
    url = `http://127.0.0.1:${address.port}/ws`;

    alice = await registerUser(app);
    bob = await registerUser(app);
    outsider = await registerUser(app);

    const gameKey = await createGameFixture();
    const create = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches`)
      .set(auth(alice.accessToken))
      .send({ gameKey });
    matchId = create.body.id;
    await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches/${matchId}/join`)
      .set(auth(bob.accessToken));
  });

  afterAll(async () => {
    await app.close();
    await closePrisma();
  });

  it('rejects connections without a valid access token', async () => {
    const anonymous = io(url, { transports: ['websocket'], reconnection: false });
    const error = await waitFor<{ code: string }>(anonymous, 'error');
    expect(error.code).toBe('unauthorized');
    anonymous.close();

    const forged = io(url, {
      transports: ['websocket'],
      reconnection: false,
      auth: { token: 'forged.token.value' },
    });
    const error2 = await waitFor<{ code: string }>(forged, 'error');
    expect(error2.code).toBe('unauthorized');
    forged.close();
  });

  it('authenticates, subscribes and broadcasts moves to the match room', async () => {
    const aliceSocket = io(url, {
      transports: ['websocket'],
      reconnection: false,
      auth: { token: alice.accessToken },
    });
    const bobSocket = io(url, {
      transports: ['websocket'],
      reconnection: false,
      auth: { token: bob.accessToken },
    });

    const aliceConnected = await waitFor<{ userId: string }>(aliceSocket, 'connected');
    await waitFor(bobSocket, 'connected');
    expect(aliceConnected.userId).toBe(alice.id);

    const subscribed = await aliceSocket.emitWithAck('match:subscribe', { matchId });
    expect(subscribed).toMatchObject({ ok: true, status: 'ACTIVE' });

    const bobSubscribed = await bobSocket.emitWithAck('match:subscribe', { matchId });
    expect(bobSubscribed).toMatchObject({ ok: true, status: 'ACTIVE' });

    const outsiderSocket = io(url, {
      transports: ['websocket'],
      reconnection: false,
      auth: { token: outsider.accessToken },
    });
    await waitFor(outsiderSocket, 'connected');
    const denied = await outsiderSocket.emitWithAck('match:subscribe', { matchId });
    expect(denied).toMatchObject({ ok: false, error: 'not a participant' });
    outsiderSocket.close();

    const moved = waitFor<{ seq: number; userId: string }>(bobSocket, 'match:moved');
    const result = await aliceSocket.emitWithAck('match:move', {
      matchId,
      payload: { action: 'move', to: 'c5' },
    });
    expect(result).toMatchObject({ ok: true });

    const broadcast = await moved;
    expect(broadcast.seq).toBe(1);
    expect(broadcast.userId).toBe(alice.id);

    const pong = await aliceSocket.emitWithAck('ping');
    expect(pong.ok).toBe(true);

    aliceSocket.close();
    bobSocket.close();
  });

  it("rejects a banned account's still-unexpired token at the handshake", async () => {
    const victim = await registerUser(app);

    const ok = io(url, {
      transports: ['websocket'],
      reconnection: false,
      auth: { token: victim.accessToken },
    });
    await waitFor(ok, 'connected');
    ok.close();

    await prisma().user.update({ where: { id: victim.id }, data: { status: 'BANNED' } });

    const banned = io(url, {
      transports: ['websocket'],
      reconnection: false,
      auth: { token: victim.accessToken },
    });
    const error = await waitFor<{ code: string; reason?: string }>(banned, 'error');
    expect(error.code).toBe('unauthorized');
    banned.close();

    await prisma().user.update({ where: { id: victim.id }, data: { status: 'ACTIVE' } });
  });
});
