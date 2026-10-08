import { INestApplication } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Test } from '@nestjs/testing';
import { configureApp } from '../../src/app.setup';
import { AppConfig } from '../../src/config/configuration';

export async function createTestApp(): Promise<INestApplication> {
  // Imported lazily so a spec can still adjust throttling env (e.g.
  // AUTH_THROTTLE_LIMIT) at module scope before Nest evaluates controllers.
  const { AppModule } = await import('../../src/app.module');
  const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
  const app = moduleRef.createNestApplication({ logger: false });
  const cfg = (app.get(ConfigService).get<AppConfig>('app') ?? null) as AppConfig | null;
  if (!cfg) throw new Error('app config missing');
  configureApp(app, cfg);
  await app.init();
  return app;
}

export function apiUrl(app: INestApplication, path: string): string {
  const address = app.getHttpServer().address();
  if (!address || typeof address === 'string') throw new Error('server not listening');
  return `http://127.0.0.1:${address.port}${path}`;
}

export const uniqueSuffix = (): string =>
  `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;
