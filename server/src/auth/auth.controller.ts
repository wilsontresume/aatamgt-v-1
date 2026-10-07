import { Body, Controller, Get, HttpCode, Post, UseGuards } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { AuthService } from './auth.service';
import { JwtRefreshGuard } from './jwt-refresh.guard';
import { Public } from '../common/decorators/public.decorator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { toPublicUser } from '../common/utils/user-view';
import { LoginDto, RefreshDto, RegisterDto } from './dto/auth.dto';

/** Small helper so AUTH_THROTTLE_* env vars actually reach these routes. */
function authThrottle(fallbackLimit: number) {
  const limit = Number(process.env.AUTH_THROTTLE_LIMIT);
  const ttl = Number(process.env.AUTH_THROTTLE_TTL);
  return {
    default: {
      limit: Number.isFinite(limit) && limit > 0 ? limit : fallbackLimit,
      ttl: (Number.isFinite(ttl) && ttl > 0 ? ttl : 60) * 1000,
    },
  };
}

const REGISTER_THROTTLE = authThrottle(10);
const LOGIN_THROTTLE = authThrottle(10);

@Controller('auth')
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Public()
  @Throttle(REGISTER_THROTTLE)
  @Post('register')
  async register(@Body() dto: RegisterDto) {
    const { user, tokens } = await this.auth.register(dto);
    return { user: toPublicUser(user), ...tokens };
  }

  @Public()
  @Throttle(LOGIN_THROTTLE)
  @Post('guest')
  async guest() {
    const { user, tokens } = await this.auth.guestLogin();
    return { user: toPublicUser(user), ...tokens };
  }

  @Public()
  @Throttle(LOGIN_THROTTLE)
  @HttpCode(200)
  @Post('login')
  async login(@Body() dto: LoginDto) {
    const { user, tokens } = await this.auth.login(dto);
    return { user: toPublicUser(user), ...tokens };
  }

  @Public()
  @Throttle({ default: { limit: 20, ttl: 60_000 } })
  @UseGuards(JwtRefreshGuard)
  @HttpCode(200)
  @Post('refresh')
  async refresh(@Body() dto: RefreshDto) {
    const { user, tokens } = await this.auth.refresh(dto.refreshToken);
    return { user: toPublicUser(user), ...tokens };
  }

  @Public()
  @HttpCode(200)
  @Post('logout')
  async logout(@Body() dto: RefreshDto) {
    return this.auth.logout(dto.refreshToken);
  }

  @Get('session')
  session(@CurrentUser() user: AuthUser) {
    return { id: user.id, username: user.username, role: user.role };
  }
}
