import { Body, Controller, Get, HttpCode, Post, UseGuards } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { AuthService } from './auth.service';
import { JwtRefreshGuard } from './jwt-refresh.guard';
import { Public } from '../common/decorators/public.decorator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { toPublicUser } from '../common/utils/user-view';
import { LoginDto, RefreshDto, RegisterDto } from './dto/auth.dto';

@Controller('auth')
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Public()
  @Throttle({ default: { limit: 5, ttl: 60_000 } })
  @Post('register')
  async register(@Body() dto: RegisterDto) {
    const { user, tokens } = await this.auth.register(dto);
    return { user: toPublicUser(user), ...tokens };
  }

  @Public()
  @Throttle({ default: { limit: 5, ttl: 60_000 } })
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
