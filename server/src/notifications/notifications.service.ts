import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { PaginationQuery, Paginated } from '../common/dto/pagination.query';

export interface NotifyInput {
  userId: string;
  type: string;
  title: string;
  body?: string;
  data?: Record<string, unknown>;
}

@Injectable()
export class NotificationsService {
  constructor(private readonly prisma: PrismaService) {}

  notify(input: NotifyInput) {
    return this.prisma.notification.create({
      data: {
        userId: input.userId,
        type: input.type,
        title: input.title,
        body: input.body,
        data: input.data as Prisma.InputJsonValue | undefined,
      },
    });
  }

  async list(
    userId: string,
    query: PaginationQuery,
    unreadOnly = false,
  ): Promise<Paginated<unknown>> {
    const where = { userId, ...(unreadOnly ? { readAt: null } : {}) };
    const [items, total] = await Promise.all([
      this.prisma.notification.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: query.skip,
        take: query.limit,
      }),
      this.prisma.notification.count({ where }),
    ]);
    return {
      items: items.map((row) => ({
        id: row.id,
        type: row.type,
        title: row.title,
        body: row.body,
        data: row.data,
        readAt: row.readAt?.toISOString() ?? null,
        createdAt: row.createdAt.toISOString(),
      })),
      page: query.page,
      limit: query.limit,
      total,
    };
  }

  async unreadCount(userId: string): Promise<number> {
    return this.prisma.notification.count({ where: { userId, readAt: null } });
  }

  async markRead(userId: string, ids?: string[]): Promise<number> {
    const result = await this.prisma.notification.updateMany({
      where: { userId, readAt: null, ...(ids && ids.length > 0 ? { id: { in: ids } } : {}) },
      data: { readAt: new Date() },
    });
    return result.count;
  }

  async markAllRead(userId: string): Promise<number> {
    const result = await this.prisma.notification.updateMany({
      where: { userId, readAt: null },
      data: { readAt: new Date() },
    });
    return result.count;
  }
}
