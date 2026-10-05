import { Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PassportStrategy } from '@nestjs/passport';
import { AuthUser } from '../common/decorators/current-user.decorator';
import { AppConfig } from '../config/configuration';
import { AccessTokenPayload } from './auth.service';
import { ExtractJwt, Strategy } from 'passport-jwt';

@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy, 'jwt') {
  constructor(config: ConfigService) {
    const cfg = config.get<AppConfig>('app') as AppConfig;
    super({
      jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(),
      secretOrKey: cfg.jwt.accessSecret,
      ignoreExpiration: false,
    });
  }

  validate(payload: AccessTokenPayload): AuthUser {
    if (!payload?.sub) throw new UnauthorizedException('Invalid access token');
    return {
      id: payload.sub,
      username: payload.username,
      role: payload.role as AuthUser['role'],
    };
  }
}
