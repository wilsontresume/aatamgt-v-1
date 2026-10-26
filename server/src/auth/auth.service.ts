import {
  ConflictException,
  ForbiddenException,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { User } from '@prisma/client';
import { randomBytes, randomUUID } from 'node:crypto';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { sha256 } from '../common/crypto.service';
import { AppConfig } from '../config/configuration';
import { SystemConfigService } from '../config/system-config.service';
import { AnalyticsService } from '../analytics/analytics.service';
import { LoginDto, RegisterDto, SocialLoginDto } from './dto/auth.dto';
import { SocialIdentity, SocialVerifier } from './social-verify';
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
  private readonly socialVerifier: SocialVerifier;

  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
    private readonly wallet: WalletService,
    private readonly systemConfig: SystemConfigService,
    private readonly analytics: AnalyticsService,
  ) {
    this.cfg = this.config.get<AppConfig>('app') as AppConfig;
    this.socialVerifier = new SocialVerifier(this.cfg);
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

    // Phase 7: welcome grant. Server-computed, idempotent per user — the
    // client never asks for a specific amount and cannot replay it.
    // Phase 15: the amount is the live admin-configured bonus.
    const bonus = await this.systemConfig.number('coins.registration_bonus');
    await this.wallet.credit(user.id, bonus, {
      type: 'REGISTRATION_BONUS',
      refType: 'registration',
      refId: user.id,
      idempotencyKey: `registration:${user.id}`,
      memo: 'Registration bonus',
    });

    const tokens = await this.issueTokens(user);
    void this.analytics.record({
      type: 'registration',
      userId: user.id,
      dedupeKey: `registration:${user.id}`,
    });
    return { user, tokens };
  }

  /**
   * Guest sign-in: creates a throwaway account server-side. The generated
   * password is random, hashed, and never returned to the client — the client
   * only ever receives session tokens.
   */
  async guestLogin(): Promise<{ user: User; tokens: TokenPair }> {
    const passwordHash = await bcrypt.hash(randomBytes(32).toString('base64url'), SALT_ROUNDS);
    let user: User | null = null;

    for (let attempt = 0; attempt < 4 && !user; attempt++) {
      const username = `guest_${randomUUID().replace(/-/g, '').slice(0, 8)}`;
      try {
        user = await this.prisma.$transaction(
          async (tx) =>
            tx.user.create({
              data: {
                username,
                passwordHash,
                isGuest: true,
                profile: { create: { displayName: `Guest ${username.slice(-4).toUpperCase()}` } },
                wallets: { create: { currency: 'COIN', balance: 0 } },
              },
            }),
        );
      } catch (error) {
        if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') {
          continue;
        }
        throw error;
      }
    }

    if (!user) throw new ConflictException('Could not allocate a guest username');

    // Guest welcome grant: the same server-computed, admin-configurable
    // amount as the registration bonus, idempotent per user (guest login
    // always makes a fresh account, so the key can never be replayed).
    const bonus = await this.systemConfig.number('coins.registration_bonus');
    await this.wallet.credit(user.id, bonus, {
      type: 'REGISTRATION_BONUS',
      refType: 'guest_registration',
      refId: user.id,
      idempotencyKey: `guest-registration:${user.id}`,
      memo: 'Guest welcome bonus',
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

  /**
   * Social sign-in / guest upgrade.
   *
   * - The provider token is always verified server-side first; the identity
   *   (subject + email) comes from the provider, never from the client.
   * - Existing identity → normal login of the linked account.
   * - Caller is a logged-in guest → the identity is attached to that same
   *   account: progress/coins/matches are kept and the account stops being
   *   a disposable guest.
   * - No session → a brand-new registered account is created (with the
   *   registration bonus).
   */
  async socialLogin(
    dto: SocialLoginDto,
    authorizationHeader?: string,
  ): Promise<{ user: User; tokens: TokenPair; upgraded: boolean }> {
    const currentUserId = await this.resolveBearerUser(authorizationHeader);
    return this.socialLoginVerified(dto, currentUserId);
  }

  /**
   * Best-effort resolution of the caller from an optional Bearer header.
   * The social route is public (login without a session), so a bad or
   * missing token just means "no guest to upgrade" — never an error.
   */
  private async resolveBearerUser(authorizationHeader?: string): Promise<string | null> {
    if (!authorizationHeader) return null;
    const [scheme, token] = authorizationHeader.split(' ');
    if (scheme !== 'Bearer' || !token) return null;
    try {
      const payload = await this.jwt.verifyAsync<AccessTokenPayload>(token, {
        secret: this.cfg.jwt.accessSecret,
      });
      return payload.sub ?? null;
    } catch {
      return null;
    }
  }

  private async socialLoginVerified(
    dto: SocialLoginDto,
    currentUserId?: string | null,
  ): Promise<{ user: User; tokens: TokenPair; upgraded: boolean }> {
    const identity = await this.socialVerifier.verify(dto.provider, dto.token);

    const linked = await this.prisma.socialAccount.findUnique({
      where: { provider_subject: { provider: identity.provider, subject: identity.subject } },
      include: { user: true },
    });

    if (linked) {
      const user = linked.user;
      if (user.deletedAt || user.status !== 'ACTIVE') {
        throw new ForbiddenException('Account is not active');
      }
      // Caller had a session and asked to *link* this identity to it, but
      // it belongs to another account: refuse instead of silently switching
      // the session to a different account.
      if (currentUserId && linked.userId !== currentUserId) {
        throw new ConflictException('This social account is already linked to another user');
      }
      await this.prisma.user.update({
        where: { id: user.id },
        data: { lastLoginAt: new Date() },
      });
      const tokens = await this.issueTokens(user);
      return { user, tokens, upgraded: false };
    }

    if (currentUserId) {
      return this.linkSocialIdentity(identity, currentUserId);
    }

    return this.createAccountFromSocial(identity);
  }

  /** Attach a fresh social identity to the caller's (guest) account. */
  private async linkSocialIdentity(
    identity: SocialIdentity,
    userId: string,
  ): Promise<{ user: User; tokens: TokenPair; upgraded: boolean }> {
    const user = await this.prisma.user.findFirst({
      where: { id: userId, deletedAt: null },
    });
    if (!user) throw new UnauthorizedException('Account is not active');
    if (user.status !== 'ACTIVE') throw new ForbiddenException('Account is not active');

    try {
      await this.prisma.socialAccount.create({
        data: {
          provider: identity.provider,
          subject: identity.subject,
          email: identity.email,
          name: identity.name,
          userId: user.id,
        },
      });
    } catch (error) {
      if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') {
        throw new ConflictException('This social account is already linked');
      }
      throw error;
    }

    const wasGuest = user.isGuest;
    const updated = await this.prisma.user.update({
      where: { id: user.id },
      data: {
        ...(wasGuest ? { isGuest: false } : {}),
        // A provider-verified email upgrades the placeholder guest email.
        ...(identity.email && identity.emailVerified && !user.email
          ? { email: identity.email, emailVerified: true }
          : {}),
        lastLoginAt: new Date(),
      },
    });

    if (wasGuest) {
      void this.analytics.record({
        type: 'guest_conversion',
        userId: user.id,
        data: { provider: identity.provider },
        dedupeKey: `guest_conversion:${user.id}`,
      });
    }

    const tokens = await this.issueTokens(updated);
    return { user: updated, tokens, upgraded: wasGuest };
  }

  /** Fresh social sign-in with no session: create a registered account. */
  private async createAccountFromSocial(
    identity: SocialIdentity,
  ): Promise<{ user: User; tokens: TokenPair; upgraded: boolean }> {
    if (identity.email) {
      const existing = await this.prisma.user.findFirst({
        where: { email: identity.email },
      });
      if (existing) {
        throw new ConflictException(
          'An account with this email already exists — sign in as that guest first to link it',
        );
      }
    }

    const passwordHash = await bcrypt.hash(randomBytes(32).toString('base64url'), SALT_ROUNDS);
    const base = this.socialUsernameBase(identity);
    let user: User | null = null;

    for (let attempt = 0; attempt < 4 && !user; attempt++) {
      const username =
        attempt === 0 ? base : `${base.slice(0, 18)}_${randomUUID().replace(/-/g, '').slice(0, 5)}`;
      try {
        user = await this.prisma.$transaction(async (tx) => {
          const created = await tx.user.create({
            data: {
              username,
              email: identity.email,
              passwordHash,
              emailVerified: identity.emailVerified,
              profile: { create: { displayName: identity.name ?? username } },
              wallets: { create: { currency: 'COIN', balance: 0 } },
              socialAccounts: {
                create: {
                  provider: identity.provider,
                  subject: identity.subject,
                  email: identity.email,
                  name: identity.name,
                },
              },
            },
          });
          return created;
        });
      } catch (error) {
        if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') {
          continue;
        }
        throw error;
      }
    }

    if (!user) throw new ConflictException('Could not allocate a username');

    const bonus = await this.systemConfig.number('coins.registration_bonus');
    await this.wallet.credit(user.id, bonus, {
      type: 'REGISTRATION_BONUS',
      refType: 'social_registration',
      refId: user.id,
      idempotencyKey: `social-registration:${user.id}`,
      memo: 'Registration bonus',
    });

    const tokens = await this.issueTokens(user);
    void this.analytics.record({
      type: 'registration',
      userId: user.id,
      dedupeKey: `registration:${user.id}`,
    });
    return { user, tokens, upgraded: false };
  }

  /** 3-24 chars of letters/numbers/underscores, unique by retry. */
  private socialUsernameBase(identity: SocialIdentity): string {
    const raw = (identity.name ?? identity.email?.split('@')[0] ?? identity.subject)
      .toLowerCase()
      .replace(/[^a-z0-9_]/g, '_')
      .replace(/_+/g, '_')
      .replace(/^_|_$/g, '');
    const safe = raw.slice(0, 24);
    if (safe.length >= 3) return safe;
    return `user_${randomUUID().replace(/-/g, '').slice(0, 8)}`;
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
