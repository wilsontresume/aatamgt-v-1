import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../helpers/app';

describe('Health (integration)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('reports the database as up', async () => {
    const res = await request(app.getHttpServer()).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
    expect(res.body.details.database.status).toBe('up');
  });

  it('is not exposed under the API prefix', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/health');
    expect(res.status).toBe(404);
  });

  it('rejects unauthenticated access to protected routes', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/users/me');
    expect(res.status).toBe(401);
    expect(res.body.message).toMatch(/auth/i);
  });
});
