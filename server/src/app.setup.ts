import { INestApplication } from '@nestjs/common';
import { AppConfig } from './config/configuration';

/** Shared HTTP pipeline setup used by both the runtime entrypoint and tests. */
export function configureApp(app: INestApplication, cfg: AppConfig): void {
  app.setGlobalPrefix(cfg.apiPrefix, { exclude: ['health'] });
  app.enableCors({ origin: cfg.corsOrigins, credentials: true });
}
