import { ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import { Prisma, User } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { UpdateUserDto } from './dto/user.dto';

@Injectable()
export class UsersService {
  constructor(private readonly prisma: PrismaService) {}

  findById(id: string): Promise<User> {
    return this.requireUser({ id });
  }

  async findByUsername(username: string): Promise<User> {
    return this.requireUser({ username: username.toLowerCase() });
  }

  async update(userId: string, dto: UpdateUserDto): Promise<User> {
    if (dto.email === undefined) return this.requireUser({ id: userId });

    const email = dto.email.toLowerCase();
    const clash = await this.prisma.user.findFirst({
      where: { email, NOT: { id: userId } },
      select: { id: true },
    });
    if (clash) throw new ConflictException('Email is already registered');

    return this.prisma.user.update({ where: { id: userId }, data: { email } });
  }

  async softDelete(userId: string): Promise<User> {
    return this.prisma.user.update({
      where: { id: userId },
      data: { deletedAt: new Date(), status: 'BANNED' },
    });
  }

  private async requireUser(where: Prisma.UserWhereUniqueInput): Promise<User> {
    const user = await this.prisma.user.findUnique({ where });
    if (!user || user.deletedAt) throw new NotFoundException('User not found');
    return user;
  }
}
