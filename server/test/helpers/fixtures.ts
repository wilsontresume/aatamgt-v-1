import { INestApplication } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import request from 'supertest';
import * as bcrypt from 'bcryptjs';
import { PrismaClient, Role } from '@prisma/client';
import { AppConfig } from '../../src/config/configuration';
import { uniqueSuffix } from './app';

let prismaSingleton: PrismaClient | null = null;

export function prisma(): PrismaClient {
  if (!prismaSingleton) prismaSingleton = new PrismaClient();
  return prismaSingleton;
}

export async function closePrisma(): Promise<void> {
  if (prismaSingleton) {
    await prismaSingleton.$disconnect();
    prismaSingleton = null;
  }
}

export function apiPrefix(app: INestApplication): string {
  const cfg = app.get(ConfigService).get<AppConfig>('app') as AppConfig;
  return `/${cfg.apiPrefix}`;
}

export interface TestUser {
  id: string;
  username: string;
  password: string;
  accessToken: string;
  refreshToken: string;
}

export async function registerUser(
  app: INestApplication,
  options: { role?: Role; username?: string; password?: string } = {},
): Promise<TestUser> {
  const username = options.username ?? `t_${uniqueSuffix()}`.slice(0, 24);
  const password = options.password ?? 'Password123!';
  const res = await request(app.getHttpServer())
    .post(`${apiPrefix(app)}/auth/register`)
    .send({ username, password });
  if (res.status !== 201) {
    throw new Error(`register failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
  if (options.role && options.role !== 'USER') {
    await prisma().user.update({ where: { id: res.body.user.id }, data: { role: options.role } });
    const login = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/login`)
      .send({ identifier: username, password });
    return {
      id: res.body.user.id,
      username,
      password,
      accessToken: login.body.accessToken,
      refreshToken: login.body.refreshToken,
    };
  }
  return {
    id: res.body.user.id,
    username,
    password,
    accessToken: res.body.accessToken,
    refreshToken: res.body.refreshToken,
  };
}

export async function login(
  app: INestApplication,
  identifier: string,
  password: string,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const res = await request(app.getHttpServer())
    .post(`${apiPrefix(app)}/auth/login`)
    .send({ identifier, password });
  return { status: res.status, body: res.body };
}

export async function createGameFixture(key?: string): Promise<string> {
  const gameKey = key ?? `game-${uniqueSuffix()}`;
  await prisma().game.create({
    data: {
      key: gameKey,
      name: 'Integration Test Game',
      slug: gameKey,
      minPlayers: 2,
      maxPlayers: 2,
    },
  });
  return gameKey;
}

export async function createUserDirectly(
  username: string,
  role: Role,
  password = 'AdminPass123!',
): Promise<{ id: string; username: string; password: string }> {
  const hash = await bcrypt.hash(password, 4);
  const user = await prisma().user.create({
    data: {
      username,
      email: `${username}@test.local`,
      passwordHash: hash,
      role,
      profile: { create: { displayName: username } },
      wallets: { create: { currency: 'COIN', balance: 0 } },
    },
  });
  return { id: user.id, username, password };
}

export const auth = (token: string) => ({ Authorization: `Bearer ${token}` });
