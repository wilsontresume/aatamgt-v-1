import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  HttpException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Friendship, FriendStatus } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { NotificationsService } from '../notifications/notifications.service';
import { AnalyticsService } from '../analytics/analytics.service';
import { UserPresenceService } from '../realtime/user-presence.service';
import { AppConfig } from '../config/configuration';

@Injectable()
export class FriendsService {
  private readonly social: AppConfig['social'];

  constructor(
    private readonly prisma: PrismaService,
    config: ConfigService,
    private readonly notifications: NotificationsService,
    private readonly analytics: AnalyticsService,
    private readonly presence: UserPresenceService,
  ) {
    this.social = (config.get<AppConfig>('app') as AppConfig).social;
  }

  async list(userId: string) {
    const rows = await this.prisma.friendship.findMany({
      where: { OR: [{ requesterId: userId }, { addresseeId: userId }] },
      include: {
        requester: { select: { id: true, username: true } },
        addressee: { select: { id: true, username: true } },
      },
      orderBy: { updatedAt: 'desc' },
    });

    const mapRow = (
      row: Friendship & {
        requester: { id: string; username: string };
        addressee: { id: string; username: string };
      },
    ) => {
      const other =
        row.requesterId === userId
          ? { id: row.addressee.id, username: row.addressee.username }
          : { id: row.requester.id, username: row.requester.username };
      return {
        id: row.id,
        status: row.status,
        createdAt: row.createdAt.toISOString(),
        user: other,
        online: this.presence.isOnline(other.id),
        outgoing: row.requesterId === userId,
      };
    };

    return {
      friends: rows.filter((r) => r.status === 'ACCEPTED').map(mapRow),
      incoming: rows.filter((r) => r.status === 'PENDING' && r.addresseeId === userId).map(mapRow),
      outgoing: rows.filter((r) => r.status === 'PENDING' && r.requesterId === userId).map(mapRow),
      blocked: rows.filter((r) => r.status === 'BLOCKED').map(mapRow),
    };
  }

  async request(fromUserId: string, targetUsername: string) {
    const target = await this.prisma.user.findFirst({
      where: { username: targetUsername.toLowerCase(), deletedAt: null },
      select: { id: true, username: true },
    });
    if (!target) throw new NotFoundException('User not found');
    if (target.id === fromUserId) throw new BadRequestException('You cannot add yourself');

    // Abuse controls: one account may only hold so many pending requests and
    // fire off so many per hour before being rate limited.
    const pendingOutgoing = await this.prisma.friendship.count({
      where: { requesterId: fromUserId, status: 'PENDING' },
    });
    if (pendingOutgoing >= this.social.friendPendingLimit) {
      throw new HttpException('Too many pending requests. Wait for a reply.', 429);
    }
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    const recent = await this.prisma.friendship.count({
      where: { requesterId: fromUserId, createdAt: { gte: oneHourAgo } },
    });
    if (recent >= this.social.friendRequestPerHour) {
      throw new HttpException('Too many requests today. Try again later.', 429);
    }

    const existing = await this.prisma.friendship.findFirst({
      where: {
        OR: [
          { requesterId: fromUserId, addresseeId: target.id },
          { requesterId: target.id, addresseeId: fromUserId },
        ],
      },
    });
    if (existing?.status === 'BLOCKED') throw new ForbiddenException('Cannot send a request');
    if (existing?.status === 'PENDING') {
      throw new ConflictException(
        existing.requesterId === fromUserId
          ? 'A friendship request already exists'
          : 'They already sent you a request',
      );
    }
    if (existing?.status === 'ACCEPTED') throw new ConflictException('You are already friends');

    // DECLINED rows are reusable: a fresh request resets them back to PENDING
    // (swapping the pair so `requesterId` is always the new sender).
    const created = existing
      ? await this.prisma.friendship.update({
          where: { id: existing.id },
          data: { requesterId: fromUserId, addresseeId: target.id, status: 'PENDING' },
        })
      : await this.prisma.friendship.create({
          data: { requesterId: fromUserId, addresseeId: target.id, status: 'PENDING' },
        });

    const me = await this.prisma.user.findUnique({
      where: { id: fromUserId },
      select: { username: true },
    });
    await this.notifications.notify({
      userId: target.id,
      type: 'friend_request',
      title: 'Friend request',
      body: `${me?.username ?? 'Someone'} sent you a friend request`,
      data: { friendshipId: created.id, userId: fromUserId },
    });
    void this.analytics.record({
      type: 'friend_request',
      userId: fromUserId,
      // No dedupeKey: a declined request can be legitimately re-sent on
      // the same friendship row and must count again.
    });
    return { id: created.id, status: created.status, username: target.username };
  }

  async respond(userId: string, friendshipId: string, action: 'accept' | 'decline') {
    const row = await this.requirePendingFor(userId, friendshipId);
    if (row.status !== 'PENDING') throw new ConflictException('Request is not pending');
    const status: FriendStatus = action === 'accept' ? 'ACCEPTED' : 'DECLINED';
    const updated = await this.prisma.friendship.update({
      where: { id: row.id },
      data: { status },
    });
    if (action === 'accept') {
      const me = await this.prisma.user.findUnique({
        where: { id: userId },
        select: { username: true },
      });
      await this.notifications.notify({
        userId: row.requesterId,
        type: 'friend_accepted',
        title: 'Friend request accepted',
        body: `${me?.username ?? 'Someone'} accepted your friend request`,
        data: { friendshipId: row.id, userId },
      });
    }
    return { id: updated.id, status: updated.status };
  }

  async block(userId: string, targetUsername: string) {
    const target = await this.prisma.user.findFirst({
      where: { username: targetUsername.toLowerCase(), deletedAt: null },
      select: { id: true },
    });
    if (!target) throw new NotFoundException('User not found');
    if (target.id === userId) throw new BadRequestException('You cannot block yourself');

    const existing = await this.prisma.friendship.findFirst({
      where: {
        OR: [
          { requesterId: userId, addresseeId: target.id },
          { requesterId: target.id, addresseeId: userId },
        ],
      },
    });
    if (existing) {
      const updated = await this.prisma.friendship.update({
        where: { id: existing.id },
        data: { status: 'BLOCKED' },
      });
      return { id: updated.id, status: updated.status };
    }
    const created = await this.prisma.friendship.create({
      data: { requesterId: userId, addresseeId: target.id, status: 'BLOCKED' },
    });
    return { id: created.id, status: created.status };
  }

  async remove(userId: string, friendshipId: string): Promise<{ removed: boolean }> {
    const row = await this.prisma.friendship.findUnique({ where: { id: friendshipId } });
    if (!row) throw new NotFoundException('Friendship not found');
    if (row.requesterId !== userId && row.addresseeId !== userId) {
      throw new ForbiddenException('Not your friendship');
    }
    await this.prisma.friendship.delete({ where: { id: row.id } });
    return { removed: true };
  }

  private async requirePendingFor(userId: string, friendshipId: string) {
    const row = await this.prisma.friendship.findUnique({ where: { id: friendshipId } });
    if (!row) throw new NotFoundException('Request not found');
    if (row.addresseeId !== userId) throw new ForbiddenException('Only the recipient can respond');
    return row;
  }
}
