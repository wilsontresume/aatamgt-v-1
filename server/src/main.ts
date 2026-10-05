import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { randomUUID } from 'node:crypto';
import { pino } from 'pino';
import { pinoHttp } from 'pino-http';
import { AppModule } from './app.module';
import { configureApp } from './app.setup';
import { PinoLoggerService } from './common/logger/pino-logger.service';
import { AppConfig } from './config/configuration';

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule, { bufferLogs: false });
  const config = app.get(ConfigService);
  const cfg = config.get<AppConfig>('app') as AppConfig;

  app.useLogger(new PinoLoggerService(cfg.logLevel));
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
}

bootstrap();
