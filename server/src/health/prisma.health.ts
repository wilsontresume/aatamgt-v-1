import { Injectable } from '@nestjs/common';
import { HealthCheckError, HealthIndicator, HealthIndicatorResult } from '@nestjs/terminus';
import { PrismaService } from '../prisma/prisma.service';

@Injectable()
export class PrismaHealthIndicator extends HealthIndicator {
  constructor(private readonly prisma: PrismaService) {
    super();
  }

  async ping(key = 'database'): Promise<HealthIndicatorResult> {
    const startedAt = Date.now();
    try {
      await this.prisma.$queryRaw`SELECT 1`;
      return this.getStatus(key, true, { latencyMs: Date.now() - startedAt });
    } catch (error) {
      throw new HealthCheckError(
        key,
        this.getStatus(key, false, {
          message: error instanceof Error ? error.message : 'unknown error',
        }),
      );
    }
  }
}
