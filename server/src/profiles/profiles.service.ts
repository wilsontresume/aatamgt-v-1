import { Injectable, NotFoundException } from '@nestjs/common';
import { Profile } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { UpdateProfileDto } from '../users/dto/user.dto';

export type ProfileWithUser = Profile & {
  user: { id: string; username: string; createdAt: Date };
};

@Injectable()
export class ProfilesService {
  constructor(private readonly prisma: PrismaService) {}

  async getById(userId: string): Promise<ProfileWithUser> {
    const profile = await this.prisma.profile.findUnique({
      where: { userId },
      include: { user: { select: { id: true, username: true, createdAt: true } } },
    });
    if (!profile) throw new NotFoundException('Profile not found');
    return profile;
  }

  async getByUsername(username: string): Promise<ProfileWithUser> {
    const profile = await this.prisma.profile.findFirst({
      where: { user: { username: username.toLowerCase(), deletedAt: null } },
      include: { user: { select: { id: true, username: true, createdAt: true } } },
    });
    if (!profile) throw new NotFoundException('Profile not found');
    if (!profile.isPublic) throw new NotFoundException('Profile not found');
    return profile;
  }

  async update(userId: string, dto: UpdateProfileDto): Promise<ProfileWithUser> {
    const data: Record<string, string | boolean> = {};
    if (dto.displayName !== undefined) data.displayName = dto.displayName;
    if (dto.avatarKey !== undefined) data.avatarKey = dto.avatarKey;
    if (dto.countryCode !== undefined) data.countryCode = dto.countryCode;
    if (dto.bio !== undefined) data.bio = dto.bio;
    if (dto.isPublic !== undefined) data.isPublic = dto.isPublic;

    await this.prisma.profile.update({ where: { userId }, data });
    return this.getById(userId);
  }

  serialize(profile: ProfileWithUser) {
    return {
      userId: profile.userId,
      username: profile.user.username,
      displayName: profile.displayName,
      avatarKey: profile.avatarKey,
      countryCode: profile.countryCode,
      bio: profile.bio,
      level: profile.level,
      xp: profile.xp,
      rating: profile.rating,
      stats: {
        gamesPlayed: profile.gamesPlayed,
        wins: profile.wins,
        losses: profile.losses,
        draws: profile.draws,
      },
      isPublic: profile.isPublic,
      updatedAt: profile.updatedAt.toISOString(),
    };
  }
}
