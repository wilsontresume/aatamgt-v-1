import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { Friendship, FriendStatus } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';

@Injectable()
export class FriendsService {
  constructor(private readonly prisma: PrismaService) {}

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
    ) => ({
      id: row.id,
      status: row.status,
      createdAt: row.createdAt.toISOString(),
      user:
        row.requesterId === userId
          ? { id: row.addressee.id, username: row.addressee.username }
          : { id: row.requester.id, username: row.requester.username },
      outgoing: row.requesterId === userId,
    });

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

    const existing = await this.prisma.friendship.findFirst({
      where: {
        OR: [
          { requesterId: fromUserId, addresseeId: target.id },
          { requesterId: target.id, addresseeId: fromUserId },
        ],
      },
    });
    if (existing?.status === 'BLOCKED') throw new ForbiddenException('Cannot send a request');
    if (existing) throw new ConflictException('A friendship request already exists');

    const created = await this.prisma.friendship.create({
      data: { requesterId: fromUserId, addresseeId: target.id, status: 'PENDING' },
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
