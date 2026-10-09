import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import { apiPrefix, auth, closePrisma, prisma, registerUser, TestUser } from '../helpers/fixtures';
import { CATALOG } from '../../src/cosmetics/catalog';

/**
 * Phase 12 — DEV_COSMETIC_GRANTS=false: the grant endpoint disappears (404)
 * and the client-facing flag is off. Env is set before the lazy app import
 * evaluates configuration, then restored for other suites in this worker.
 */
const PREV_DEV_GRANTS = process.env.DEV_COSMETIC_GRANTS;
process.env.DEV_COSMETIC_GRANTS = 'false';

describe('Cosmetics dev grants disabled', () => {
  let app: INestApplication;

  const post = (user: TestUser, path: string) =>
    request(app.getHttpServer())
      .post(`${apiPrefix(app)}${path}`)
      .set(auth(user.accessToken))
      .send({});

  beforeAll(async () => {
    for (const item of CATALOG) {
      await prisma().cosmetic.upsert({
        where: { key: item.key },
        update: { active: true },
        create: item,
      });
    }
    app = await createTestApp();
  });

  afterAll(async () => {
    await closePrisma();
    await app.close();
    if (PREV_DEV_GRANTS === undefined) delete process.env.DEV_COSMETIC_GRANTS;
    else process.env.DEV_COSMETIC_GRANTS = PREV_DEV_GRANTS;
  });

  it('exposes devGrantsEnabled: false to the client', async () => {
    const user = await registerUser(app);
    const res = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/cosmetics`)
      .set(auth(user.accessToken));
    expect(res.status).toBe(200);
    expect(res.body.devGrantsEnabled).toBe(false);
  });

  it('404s on the grant endpoint', async () => {
    const user = await registerUser(app);
    const res = await post(user, '/cosmetics/victory_fireworks/grant');
    expect(res.status).toBe(404);
    expect(JSON.stringify(res.body)).toContain('grants are disabled');
  });

  it('leaves claim, purchase and equip untouched', async () => {
    const user = await registerUser(app);
    expect((await post(user, '/cosmetics/board_woodland/claim')).status).toBe(200);
    expect((await post(user, '/cosmetics/board_woodland/equip')).status).toBe(200);
    expect((await post(user, '/cosmetics/board_midnight/purchase')).status).toBe(200);
  });
});
