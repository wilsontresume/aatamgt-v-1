import { Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PassportStrategy } from '@nestjs/passport';
import { AuthUser } from '../common/decorators/current-user.decorator';
import { PrismaService } from '../prisma/prisma.service';
import { AppConfig } from '../config/configuration';
import { AccessTokenPayload } from './auth.service';
import { ExtractJwt, Strategy } from 'passport-jwt';

@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy, 'jwt') {
  constructor(config: ConfigService, private readonly prisma: PrismaService) {
    const cfg = config.get<AppConfig>('app') as AppConfig;
    super({
      jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(),
      secretOrKey: cfg.jwt.accessSecret,
      ignoreExpiration: false,
    });
  }

  /**
   * The token proves who is calling; the ACCOUNT decides what they may
   * do. Identity, role, status and deletion are re-read on every request
   * so a ban, suspension, demotion or deletion takes effect immediately
   * instead of surviving inside an unexpired access token (or a
   * WebSocket handshake) until its TTL runs out.
   */
  async validate(payload: AccessTokenPayload): Promise<AuthUser> {
    if (!payload?.sub) throw new UnauthorizedException('Invalid access token');
    const user = await this.prisma.user.findUnique({
      where: { id: payload.sub },
      select: { username: true, role: true, status: true, deletedAt: true },
    });
    if (!user || user.deletedAt) throw new UnauthorizedException('Invalid access token');
    if (user.status !== 'ACTIVE') throw new UnauthorizedException('Account is not active');
    return {
      id: payload.sub,
      username: user.username,
      role: user.role,
    };
  }
}
