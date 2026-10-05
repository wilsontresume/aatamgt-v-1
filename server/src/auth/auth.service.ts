import {
  ConflictException,
  ForbiddenException,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { User } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { PrismaService } from '../prisma/prisma.service';
import { sha256 } from '../common/crypto.service';
import { AppConfig } from '../config/configuration';
import { LoginDto, RegisterDto } from './dto/auth.dto';
import * as bcrypt from 'bcryptjs';

export interface AccessTokenPayload {
  sub: string;
  username: string;
  role: string;
}

export interface RefreshTokenPayload {
  sub: string;
  jti: string;
}

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

const SALT_ROUNDS = 10;

@Injectable()
export class AuthService {
  private readonly cfg: AppConfig;

  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
  ) {
    this.cfg = this.config.get<AppConfig>('app') as AppConfig;
  }

  async register(dto: RegisterDto): Promise<{ user: User; tokens: TokenPair }> {
    const username = dto.username.toLowerCase();
    const existing = await this.prisma.user.findFirst({
      where: {
        OR: [{ username }, ...(dto.email ? [{ email: dto.email.toLowerCase() }] : [])],
      },
    });
    if (existing) {
      throw new ConflictException(
        existing.username === username
          ? 'Username is already taken'
          : 'Email is already registered',
      );
    }

    const passwordHash = await bcrypt.hash(dto.password, SALT_ROUNDS);
    const user = await this.prisma.$transaction(async (tx) => {
      const created = await tx.user.create({
        data: {
          username,
          email: dto.email?.toLowerCase(),
          passwordHash,
          profile: { create: { displayName: dto.username } },
          wallets: { create: { currency: 'COIN', balance: 0 } },
        },
      });
      return created;
    });

    const tokens = await this.issueTokens(user);
    return { user, tokens };
  }

  async login(dto: LoginDto): Promise<{ user: User; tokens: TokenPair }> {
    const identifier = dto.identifier.trim().toLowerCase();
    const user = await this.prisma.user.findFirst({
      where: { OR: [{ username: identifier }, { email: identifier }], deletedAt: null },
    });
    if (!user) throw new UnauthorizedException('Invalid credentials');

    const ok = await bcrypt.compare(dto.password, user.passwordHash);
    if (!ok) throw new UnauthorizedException('Invalid credentials');
    if (user.status !== 'ACTIVE') {
      throw new ForbiddenException('Account is not active');
    }

    await this.prisma.user.update({ where: { id: user.id }, data: { lastLoginAt: new Date() } });
    const tokens = await this.issueTokens(user);
    return { user, tokens };
  }

  async refresh(refreshToken: string): Promise<{ user: User; tokens: TokenPair }> {
    const payload = await this.verifyRefreshToken(refreshToken);
    const tokenHash = sha256(refreshToken);
    const stored = await this.prisma.refreshToken.findUnique({ where: { tokenHash } });
    if (!stored || stored.revokedAt || stored.expiresAt < new Date()) {
      throw new UnauthorizedException('Refresh token is not valid');
    }

    const user = await this.prisma.user.findUnique({ where: { id: payload.sub } });
    if (!user || user.deletedAt || user.status !== 'ACTIVE') {
      throw new UnauthorizedException('Account is not active');
    }

    await this.prisma.refreshToken.update({
      where: { tokenHash },
      data: { revokedAt: new Date() },
    });

    const tokens = await this.issueTokens(user);
    return { user, tokens };
  }

  async logout(refreshToken: string): Promise<{ revoked: boolean }> {
    const tokenHash = sha256(refreshToken);
    const stored = await this.prisma.refreshToken.findUnique({ where: { tokenHash } });
    if (!stored) return { revoked: false };
    if (!stored.revokedAt) {
      await this.prisma.refreshToken.update({
        where: { tokenHash },
        data: { revokedAt: new Date() },
      });
    }
    return { revoked: true };
  }

  async issueTokens(user: User): Promise<TokenPair> {
    const accessPayload: AccessTokenPayload = {
      sub: user.id,
      username: user.username,
      role: user.role,
    };
    const accessToken = await this.jwt.signAsync(accessPayload, {
      secret: this.cfg.jwt.accessSecret,
      expiresIn: this.cfg.jwt.accessTtl,
    });

    const refreshPayload: RefreshTokenPayload = { sub: user.id, jti: randomUUID() };
    const refreshToken = await this.jwt.signAsync(refreshPayload, {
      secret: this.cfg.jwt.refreshSecret,
      expiresIn: this.cfg.jwt.refreshTtl,
    });

    await this.prisma.refreshToken.create({
      data: {
        userId: user.id,
        tokenHash: sha256(refreshToken),
        expiresAt: new Date(Date.now() + this.cfg.jwt.refreshTtl * 1000),
      },
    });

    await this.pruneExpiredTokens(user.id);

    return { accessToken, refreshToken, expiresIn: this.cfg.jwt.accessTtl };
  }

  private async verifyRefreshToken(token: string): Promise<RefreshTokenPayload> {
    try {
      return await this.jwt.verifyAsync<RefreshTokenPayload>(token, {
        secret: this.cfg.jwt.refreshSecret,
      });
    } catch {
      throw new UnauthorizedException('Refresh token is not valid');
    }
  }

  private async pruneExpiredTokens(userId: string): Promise<void> {
    await this.prisma.refreshToken.deleteMany({
      where: { userId, OR: [{ expiresAt: { lt: new Date() } }, { revokedAt: { not: null } }] },
    });
  }
}
