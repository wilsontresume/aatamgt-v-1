import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { pino } from 'pino';
import { pinoHttp } from 'pino-http';
import { AppModule } from './app.module';
import { configureApp } from './app.setup';
import { PinoLoggerService } from './common/logger/pino-logger.service';
import { AppConfig } from './config/configuration';

/**
 * HTTPS is enabled whenever TLS_CERT_PATH + TLS_KEY_PATH point at a
 * certificate/key pair. Clients refuse plain HTTP except for localhost
 * development (see BackendConfig in the Godot project).
 */
function loadTlsOptions(): { cert: Buffer; key: Buffer } | undefined {
  const certPath = process.env.TLS_CERT_PATH;
  const keyPath = process.env.TLS_KEY_PATH;
  if (!certPath && !keyPath) return undefined;
  if (!certPath || !keyPath) {
    throw new Error('TLS_CERT_PATH and TLS_KEY_PATH must be set together');
  }
  return { cert: readFileSync(certPath), key: readFileSync(keyPath) };
}

async function bootstrap(): Promise<void> {
  const httpsOptions = loadTlsOptions();
  const app = await NestFactory.create(AppModule, { bufferLogs: false, httpsOptions });
  const config = app.get(ConfigService);
  const cfg = config.get<AppConfig>('app') as AppConfig;

  const logger = new PinoLoggerService(cfg.logLevel);
  app.useLogger(logger);
  if (cfg.nodeEnv === 'production' && !httpsOptions) {
    logger.warn(
      'Serving plain HTTP in production — set TLS_CERT_PATH/TLS_KEY_PATH or terminate TLS at a reverse proxy in front of this process',
      'Bootstrap',
    );
  }
  configureApp(app, cfg);
  app.enableShutdownHooks();

  const httpLogger = pino({
    name: 'aatamgt-http',
    level: cfg.logLevel,
    redact: { paths: ['req.headers.authorization'], censor: '[redacted]' },
  });
  app.use(
    pinoHttp({
      logger: httpLogger,
      genReqId: (req, res) => {
        const existing = req.headers['x-request-id'];
        const id = typeof existing === 'string' ? existing : randomUUID();
        res.setHeader('x-request-id', id);
        return id;
      },
      customLogLevel: (_req, res, err) => {
        if (err || res.statusCode >= 500) return 'error';
        if (res.statusCode >= 400) return 'warn';
        return 'info';
      },
      autoLogging: { ignore: (req) => req.url === '/health' },
    }),
  );

  await app.listen(cfg.port, '0.0.0.0');
  new Logger('Bootstrap').log(
    `listening on ${httpsOptions ? 'https' : 'http'}://0.0.0.0:${cfg.port}`,
  );
}

bootstrap();
