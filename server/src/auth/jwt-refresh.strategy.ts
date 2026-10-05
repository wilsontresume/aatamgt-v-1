import { Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PassportStrategy } from '@nestjs/passport';
import { AppConfig } from '../config/configuration';
import { RefreshTokenPayload } from './auth.service';
import { ExtractJwt, Strategy } from 'passport-jwt';

@Injectable()
export class JwtRefreshStrategy extends PassportStrategy(Strategy, 'jwt-refresh') {
  constructor(config: ConfigService) {
    const cfg = config.get<AppConfig>('app') as AppConfig;
    super({
      jwtFromRequest: ExtractJwt.fromBodyField('refreshToken'),
      secretOrKey: cfg.jwt.refreshSecret,
      ignoreExpiration: false,
    });
  }

  validate(payload: RefreshTokenPayload): RefreshTokenPayload {
    if (!payload?.sub || !payload?.jti) throw new UnauthorizedException('Invalid refresh token');
    return payload;
  }
}
