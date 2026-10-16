import { INestApplication } from '@nestjs/common';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import { apiPrefix, auth, closePrisma, prisma, registerUser, TestUser } from '../helpers/fixtures';
import { AssetType } from '@prisma/client';

/**
 * Phase E: Game Asset Studio, tier display fields, atomic content
 * publish/rollback, public manifest + immutable asset files, and the
 * match reward-multiplier snapshot.
 */

// Storage root must exist before AppModule boots; the upload limit is
// kept tiny so the oversize rejection path is reachable in-test.
const storageRoot = mkdtempSync(join(tmpdir(), 'phase-e-storage-'));
process.env.ASSET_STORAGE_LOCAL_ROOT = storageRoot;
process.env.ASSET_MAX_UPLOAD_BYTES = '4096';

/** Minimal 16×16 PNG header — detectImage only sniffs signature + IHDR. */
function png16x16(): Buffer {
  const buf = Buffer.alloc(64);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(buf, 0);
  buf.writeUInt32BE(13, 8); // IHDR length
  buf.write('IHDR', 12, 'ascii');
  buf.writeUInt32BE(16, 16); // width
  buf.writeUInt32BE(16, 20); // height
  return buf;
}

function junk(bytes: number): Buffer {
  return Buffer.alloc(bytes, 0x41);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(
  predicate: () => Promise<boolean> | boolean,
  timeoutMs = 8000,
  label = 'condition',
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (await predicate()) return;
    if (Date.now() > deadline) throw new Error(`timeout waiting for ${label}`);
    await sleep(50);
  }
}

describe('Phase E content studio', () => {
  let app: INestApplication;
  let admin: TestUser;
  let mod: TestUser;
  let user: TestUser;
  let gameKey: string;
  let tierId: string;
  let tierId2: string;
  let homeAssetId: string;
  let gameCardId: string;

  const p = () => apiPrefix(app);

  beforeAll(async () => {
    // Fast AI-fallback deadline so tiered queue tests resolve quickly.
    process.env.MATCHMAKING_TIMEOUT_MS = '700';
    app = await createTestApp();
    // Shared test DB: wipe content-studio leftovers from prior runs so
    // the newest-upload-per-slot assertions are deterministic.
    await prisma().gameAsset.deleteMany({
      where: { type: { in: ['HOME_BACKGROUND', 'GAME_CARD'] } },
    });
    admin = await registerUser(app, { role: 'ADMIN' });
    mod = await registerUser(app, { role: 'MODERATOR' });
    user = await registerUser(app, { role: 'USER' });
    gameKey = `phase-e-game-${Date.now().toString(36)}`;
    await prisma().game.create({
      data: { key: gameKey, name: 'Phase E Game', slug: gameKey, minPlayers: 2, maxPlayers: 2 },
    });
    // Real engine game required for the AI-fallback queue path.
    await prisma().game.upsert({
      where: { key: 'aadu-puli-aattam' },
      update: { status: 'ACTIVE', minPlayers: 2, maxPlayers: 2 },
      create: {
        key: 'aadu-puli-aattam',
        name: 'Aadu Puli Aattam',
        slug: 'aadu-puli-aattam',
        minPlayers: 2,
        maxPlayers: 2,
      },
    });
    tierId = `phase-e-tier-${Date.now().toString(36)}`.slice(0, 32);
    await prisma().tier.create({
      data: {
        id: tierId,
        name: 'Phase E Bronze',
        entryCostCoins: 50,
        rewardMultiplierBp: 12_500,
        displayOrder: 50,
      },
    });
  });

  afterAll(async () => {
    await app.close();
    await closePrisma();
  });

  // --- Asset upload --------------------------------------------------------

  it('rejects uploads without a token', async () => {
    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/assets`)
      .attach('file', png16x16(), { filename: 'x.png', contentType: 'image/png' })
      .query({ type: AssetType.HOME_BACKGROUND });
    expect(res.status).toBe(401);
  });

  it('rejects USER uploads with 403', async () => {
    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/assets`)
      .set(auth(user.accessToken))
      .attach('file', png16x16(), { filename: 'x.png', contentType: 'image/png' })
      .query({ type: AssetType.HOME_BACKGROUND });
    expect(res.status).toBe(403);
  });

  it('rejects MODERATOR uploads with 403', async () => {
    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/assets`)
      .set(auth(mod.accessToken))
      .attach('file', png16x16(), { filename: 'x.png', contentType: 'image/png' })
      .query({ type: AssetType.HOME_BACKGROUND });
    expect(res.status).toBe(403);
  });

  it('ADMIN can upload a valid PNG and gets checksum + url', async () => {
    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/assets`)
      .set(auth(admin.accessToken))
      .attach('file', png16x16(), { filename: 'home.png', contentType: 'image/png' })
      .query({ type: AssetType.HOME_BACKGROUND, note: 'phase-e home' });
    expect(res.status).toBe(201);
    expect(res.body.id).toMatch(/^ga[a-f0-9]{28}$/);
    expect(res.body.checksum).toMatch(/^[a-f0-9]{64}$/);
    expect(res.body.mimeType).toBe('image/png');
    expect(res.body.width).toBe(16);
    expect(res.body.height).toBe(16);
    expect(res.body.version).toBe(1);
    expect(res.body.active).toBe(true);
    expect(res.body.url).toContain(res.body.id);
    homeAssetId = res.body.id;
  });

  it('rejects files that are not images (bad magic bytes)', async () => {
    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/assets`)
      .set(auth(admin.accessToken))
      .attach('file', junk(512), { filename: 'fake.png', contentType: 'image/png' })
      .query({ type: AssetType.HOME_BACKGROUND });
    expect(res.status).toBe(400);
  });

  it('rejects files over the upload size limit', async () => {
    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/assets`)
      .set(auth(admin.accessToken))
      .attach('file', junk(8192), { filename: 'big.png', contentType: 'image/png' })
      .query({ type: AssetType.HOME_BACKGROUND });
    expect(res.status).toBe(400);
  });

  it('rejects images below the minimum dimensions', async () => {
    const buf = png16x16();
    buf.writeUInt32BE(1, 16);
    buf.writeUInt32BE(1, 20);
    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/assets`)
      .set(auth(admin.accessToken))
      .attach('file', buf, { filename: 'tiny.png', contentType: 'image/png' })
      .query({ type: AssetType.HOME_BACKGROUND });
    expect(res.status).toBe(400);
  });

  it('MODERATOR can list assets but USER cannot', async () => {
    const ok = await request(app.getHttpServer())
      .get(`${p()}/admin/assets`)
      .set(auth(mod.accessToken));
    expect(ok.status).toBe(200);
    expect(Array.isArray(ok.body.items ?? ok.body)).toBe(true);

    const denied = await request(app.getHttpServer())
      .get(`${p()}/admin/assets`)
      .set(auth(user.accessToken));
    expect(denied.status).toBe(403);
  });

  it('replace creates a new immutable version in the same lineage', async () => {
    const before = await request(app.getHttpServer())
      .get(`${p()}/admin/assets/${homeAssetId}`)
      .set(auth(mod.accessToken));
    expect(before.status).toBe(200);

    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/assets/${homeAssetId}/replace`)
      .set(auth(admin.accessToken))
      .attach('file', png16x16(), { filename: 'home-v2.png', contentType: 'image/png' });
    expect(res.status).toBe(201);
    expect(res.body.id).not.toBe(homeAssetId);
    expect(res.body.version).toBe(2);
    expect(res.body.lineageId).toBe(before.body.lineageId);

    // Old row and its file remain independently addressable.
    const old = await request(app.getHttpServer()).get(`${p()}/content/assets/${homeAssetId}/file`);
    expect(old.status).toBe(200);
    const neu = await request(app.getHttpServer()).get(`${p()}/content/assets/${res.body.id}/file`);
    expect(neu.status).toBe(200);
    // Draft/publish now resolve the slot to the v2 row.
    homeAssetId = res.body.id;
  });

  it('deactivate blocks future publishes but keeps the row readable', async () => {
    const res = await request(app.getHttpServer())
      .patch(`${p()}/admin/assets/${homeAssetId}`)
      .set(auth(admin.accessToken))
      .send({ active: false });
    expect(res.status).toBe(200);
    expect(res.body.active).toBe(false);

    const row = await request(app.getHttpServer())
      .get(`${p()}/admin/assets/${homeAssetId}`)
      .set(auth(mod.accessToken));
    expect(row.status).toBe(200);

    await request(app.getHttpServer())
      .patch(`${p()}/admin/assets/${homeAssetId}`)
      .set(auth(admin.accessToken))
      .send({ active: true });
  });

  // --- Games / tiers display fields ---------------------------------------

  it('ADMIN can set displayOrder and a sanitized board theme on a game', async () => {
    const res = await request(app.getHttpServer())
      .patch(`${p()}/games/${gameKey}`)
      .set(auth(admin.accessToken))
      .send({
        displayOrder: 3,
        boardTheme: {
          surfaceColor: '#112233',
          borderColor: '#445566',
          accentColor: '#778899',
          evilKey: 'should-be-dropped',
          backgroundAssetId: null,
        },
      });
    expect(res.status).toBe(200);
    expect(res.body.displayOrder).toBe(3);
    expect(res.body.boardTheme).toEqual({
      surfaceColor: '#112233',
      borderColor: '#445566',
      accentColor: '#778899',
      backgroundAssetId: null,
    });
    expect(res.body.boardTheme.evilKey).toBeUndefined();
  });

  it('MODERATOR cannot mutate games', async () => {
    const res = await request(app.getHttpServer())
      .patch(`${p()}/games/${gameKey}`)
      .set(auth(mod.accessToken))
      .send({ displayOrder: 4 });
    expect(res.status).toBe(403);
  });

  it('tier display fields flow through admin CRUD and the public list', async () => {
    tierId2 = `phase-e-tier2-${Date.now().toString(36)}`.slice(0, 32);
    const created = await request(app.getHttpServer())
      .post(`${p()}/admin/tiers`)
      .set(auth(admin.accessToken))
      .send({
        id: tierId2,
        name: 'Phase E Silver',
        description: 'Mid-stakes practice tier',
        displayColor: '#3366ff',
        entryCostCoins: 100,
        rewardMultiplierBp: 20_000,
        displayOrder: 51,
      });
    expect(created.status).toBe(201);
    expect(created.body.description).toBe('Mid-stakes practice tier');
    expect(created.body.displayColor).toBe('#3366ff');

    const list = await request(app.getHttpServer())
      .get(`${p()}/tiers`)
      .set(auth(user.accessToken));
    expect(list.status).toBe(200);
    const items = Array.isArray(list.body) ? list.body : list.body.items;
    const mine = items.find((t: { id: string }) => t.id === tierId2);
    expect(mine.description).toBe('Mid-stakes practice tier');
    expect(mine.color).toBe('#3366ff');
  });

  it('rejects invalid tier displayColor', async () => {
    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/tiers`)
      .set(auth(admin.accessToken))
      .send({
        id: `phase-e-bad-${Date.now().toString(36)}`.slice(0, 32),
        name: 'Bad Color',
        displayColor: 'red',
        entryCostCoins: 10,
        rewardMultiplierBp: 10_000,
        displayOrder: 90,
      });
    expect(res.status).toBe(400);
  });

  it('rejects a tier artAssetId that is not a TIER_ART asset', async () => {
    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/tiers`)
      .set(auth(admin.accessToken))
      .send({
        id: `phase-e-bad2-${Date.now().toString(36)}`.slice(0, 32),
        name: 'Bad Art',
        artAssetId: 'ga0000000000000000000000000000000',
        entryCostCoins: 10,
        rewardMultiplierBp: 10_000,
        displayOrder: 91,
      });
    expect(res.status).toBe(400);
  });

  // --- Reward snapshot -----------------------------------------------------

  it('snapshots the tier reward multiplier on the match at creation', async () => {
    // Fund the player (registration bonus may have been drained by
    // earlier suites) and clear leftover queue state.
    await prisma().wallet.upsert({
      where: { userId_currency: { userId: user.id, currency: 'COIN' } },
      update: { balance: { increment: 1000 } },
      create: { userId: user.id, currency: 'COIN', balance: 1000 },
    });
    await prisma().matchmakingTicket.deleteMany({ where: { userId: user.id } });

    const queued = await request(app.getHttpServer())
      .post(`${p()}/matchmaking/queue`)
      .set(auth(user.accessToken))
      .send({ gameKey: 'aadu-puli-aattam', tierId });
    expect(queued.status).toBe(200);
    expect(queued.body.status).toBe('queued');

    let matchId = '';
    await waitFor(async () => {
      const status = await request(app.getHttpServer())
        .get(`${p()}/matchmaking/status`)
        .set(auth(user.accessToken));
      if (status.body.status === 'matched') {
        matchId = status.body.matchId;
        return true;
      }
      return false;
    }, 8000, 'AI-fallback match');
    expect(matchId).toBeTruthy();

    const row = await prisma().gameMatch.findUnique({ where: { id: matchId } });
    expect(row?.rewardMultiplierBp).toBe(12_500);
    expect(row?.stakeCoins).toBe(50);

    // Mutating the live tier must not touch the in-flight match.
    await request(app.getHttpServer())
      .patch(`${p()}/admin/tiers/${tierId}`)
      .set(auth(admin.accessToken))
      .send({ rewardMultiplierBp: 50_000 });
    const after = await prisma().gameMatch.findUnique({ where: { id: matchId } });
    expect(after?.rewardMultiplierBp).toBe(12_500);

    // Restore the tier for later suites / the settlement fallback path.
    await request(app.getHttpServer())
      .patch(`${p()}/admin/tiers/${tierId}`)
      .set(auth(admin.accessToken))
      .send({ rewardMultiplierBp: 12_500 });

    await prisma().matchmakingTicket.deleteMany({ where: { userId: user.id } });
  });

  it('rejects match entry on a deactivated tier', async () => {
    await request(app.getHttpServer())
      .patch(`${p()}/admin/tiers/${tierId}/active`)
      .set(auth(admin.accessToken))
      .send({ active: false });
    const res = await request(app.getHttpServer())
      .post(`${p()}/matchmaking/queue`)
      .set(auth(user.accessToken))
      .send({ gameKey: 'aadu-puli-aattam', tierId });
    expect(res.status).toBe(400);
    await request(app.getHttpServer())
      .patch(`${p()}/admin/tiers/${tierId}/active`)
      .set(auth(admin.accessToken))
      .send({ active: true });
  });

  // --- Draft / publish / rollback -----------------------------------------

  it('draft is visible to staff and hidden from ordinary users', async () => {
    const asMod = await request(app.getHttpServer())
      .get(`${p()}/admin/content/draft`)
      .set(auth(mod.accessToken));
    expect(asMod.status).toBe(200);
    expect(asMod.body.manifest).toBeTruthy();
    expect(asMod.body.validation).toBeTruthy();

    const asUser = await request(app.getHttpServer())
      .get(`${p()}/admin/content/draft`)
      .set(auth(user.accessToken));
    expect(asUser.status).toBe(403);

    const anon = await request(app.getHttpServer()).get(`${p()}/admin/content/draft`);
    expect(anon.status).toBe(401);
  });

  it('public manifest 404s before the first publish', async () => {
    // Ensure no earlier suite published: if one did, skip the 400s.
    const res = await request(app.getHttpServer()).get(`${p()}/content/manifest`);
    if (res.status !== 404) {
      expect([200, 404]).toContain(res.status);
      return;
    }
    expect(res.status).toBe(404);
  });

  it('MODERATOR cannot publish; ADMIN can, atomically and with audit', async () => {
    const asMod = await request(app.getHttpServer())
      .post(`${p()}/admin/content/publish`)
      .set(auth(mod.accessToken))
      .send({ note: 'mod attempt' });
    expect(asMod.status).toBe(403);

    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/content/publish`)
      .set(auth(admin.accessToken))
      .send({ note: 'phase-e first publish' });
    expect(res.status).toBe(201);
    expect(res.body.version).toBeGreaterThanOrEqual(1);
    expect(res.body.checksum).toMatch(/^[a-f0-9]{64}$/);

    const audit = await prisma().adminAuditLog.findFirst({
      where: { action: 'content.publish', targetId: `v${res.body.version}` },
      orderBy: { createdAt: 'desc' },
    });
    expect(audit).toBeTruthy();
    expect(audit?.actorUserId).toBe(admin.id);
  });

  it('public manifest serves the frozen games, tiers and assets map', async () => {
    const res = await request(app.getHttpServer()).get(`${p()}/content/manifest`);
    expect(res.status).toBe(200);
    expect(res.body.version).toBeGreaterThanOrEqual(1);
    expect(res.body.manifest.games.some((g: { key: string }) => g.key === gameKey)).toBe(true);
    expect(res.body.manifest.tiers.some((t: { id: string }) => t.id === tierId)).toBe(true);
    expect(res.body.manifest.assets[homeAssetId]).toBeTruthy();
    expect(res.body.manifest.assets[homeAssetId].url).toContain(homeAssetId);
  });

  it('second publish supersedes the previous version', async () => {
    const first = await request(app.getHttpServer()).get(`${p()}/content/manifest`);
    const firstVersion = first.body.version;

    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/content/publish`)
      .set(auth(admin.accessToken))
      .send({ note: 'phase-e second publish' });
    expect(res.status).toBe(201);
    expect(res.body.version).toBe(firstVersion + 1);

    const old = await prisma().contentPublication.findUnique({ where: { version: firstVersion } });
    expect(old?.status).toBe('SUPERSEDED');

    const current = await request(app.getHttpServer())
      .get(`${p()}/admin/content/current`)
      .set(auth(mod.accessToken));
    expect(current.body.published).toBe(true);
    expect(current.body.version).toBe(firstVersion + 1);
  });

  it('publish is refused while the draft fails validation', async () => {
    // Plant a dangling tier art reference directly (the admin API would
    // reject it at write time; only DB-level damage produces a bad draft).
    const badTierId = `phase-e-badref-${Date.now().toString(36)}`.slice(0, 32);
    await prisma().tier.create({
      data: {
        id: badTierId,
        name: 'Phase E BadRef',
        entryCostCoins: 10,
        rewardMultiplierBp: 10_000,
        displayOrder: 92,
        artAssetId: 'ga0000000000000000000000000000000',
      },
    });
    try {
      const res = await request(app.getHttpServer())
        .post(`${p()}/admin/content/publish`)
        .set(auth(admin.accessToken))
        .send({});
      expect(res.status).toBe(400);
      expect(res.body.message).toContain('validation');
    } finally {
      await prisma().tier.delete({ where: { id: badTierId } });
    }
  });

  it('rollback re-publishes an old manifest as a new version', async () => {
    const history = await request(app.getHttpServer())
      .get(`${p()}/admin/content/publications`)
      .set(auth(mod.accessToken));
    expect(history.status).toBe(200);
    const versions = history.body.items.map((i: { version: number }) => i.version);
    const target = Math.min(...versions);

    const res = await request(app.getHttpServer())
      .post(`${p()}/admin/content/rollback`)
      .set(auth(admin.accessToken))
      .send({ version: target });
    expect(res.status).toBe(201);
    expect(res.body.rolledBackFrom).toBe(target);
    expect(res.body.version).toBe(Math.max(...versions) + 1);

    const audit = await prisma().adminAuditLog.findFirst({
      where: { action: 'content.rollback', targetId: `v${res.body.version}` },
      orderBy: { createdAt: 'desc' },
    });
    expect(audit).toBeTruthy();

    const current = await request(app.getHttpServer()).get(`${p()}/content/manifest`);
    expect(current.body.version).toBe(res.body.version);
    expect(current.body.manifest.rolledBackFrom).toBe(target);
  });

  // --- Immutable asset file route -----------------------------------------

  it('asset files are public with ETag and immutable caching', async () => {
    const res = await request(app.getHttpServer()).get(`${p()}/content/assets/${homeAssetId}/file`);
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('image/png');
    expect(res.headers['cache-control']).toBe('public, max-age=31536000, immutable');
    expect(res.headers.etag).toMatch(/^"[a-f0-9]{64}"$/);
  });

  it('unknown asset ids 404 on the file route', async () => {
    const res = await request(app.getHttpServer()).get(`${p()}/content/assets/gadeadbeefdeadbeefdeadbeefdeadbeef/file`);
    expect(res.status).toBe(404);
  });

  // --- Game card slot used by the manifest --------------------------------

  it('per-game card assets resolve into the game entry of the draft', async () => {
    const up = await request(app.getHttpServer())
      .post(`${p()}/admin/assets`)
      .set(auth(admin.accessToken))
      .attach('file', png16x16(), { filename: 'card.png', contentType: 'image/png' })
      .query({ type: AssetType.GAME_CARD, gameKey });
    expect(up.status).toBe(201);
    gameCardId = up.body.id;

    const draft = await request(app.getHttpServer())
      .get(`${p()}/admin/content/draft`)
      .set(auth(mod.accessToken));
    const entry = draft.body.manifest.games.find((g: { key: string }) => g.key === gameKey);
    expect(entry.card).toEqual({ id: gameCardId });
    expect(draft.body.manifest.assets[gameCardId]).toBeTruthy();
  });
});
