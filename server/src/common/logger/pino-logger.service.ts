import { LoggerService } from '@nestjs/common';
import { pino, Logger } from 'pino';

export class PinoLoggerService implements LoggerService {
  private readonly logger: Logger;

  constructor(level: string = 'info', name = 'aatamgt') {
    const usePretty = process.env.NODE_ENV === 'development';
    this.logger = pino({
      name,
      level,
      base: { service: 'aatamgt-backend' },
      redact: {
        paths: ['req.headers.authorization', 'password', 'passwordHash'],
        censor: '[redacted]',
      },
      ...(usePretty
        ? {
            transport: {
              target: 'pino-pretty',
              options: { colorize: true, translateTime: 'SYS:HH:MM:ss' },
            },
          }
        : {}),
    });
  }

  log(message: unknown, context?: string): void {
    this.logger.info({ context }, this.stringify(message));
  }

  error(message: unknown, trace?: string, context?: string): void {
    this.logger.error({ context, trace }, this.stringify(message));
  }

  warn(message: unknown, context?: string): void {
    this.logger.warn({ context }, this.stringify(message));
  }

  debug(message: unknown, context?: string): void {
    this.logger.debug({ context }, this.stringify(message));
  }

  verbose(message: unknown, context?: string): void {
    this.logger.trace({ context }, this.stringify(message));
  }

  child(context: string): LoggerService {
    const child = new PinoLoggerService();
    Object.assign(child, { logger: this.logger.child({ context }) });
    return child;
  }

  private stringify(message: unknown): string {
    if (message instanceof Error) return message.stack ?? message.message;
    if (typeof message === 'string') return message;
    return JSON.stringify(message);
  }
}
