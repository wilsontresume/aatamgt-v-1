import { Controller, Get, HttpCode, Post } from '@nestjs/common';
import { RewardsService } from './rewards.service';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';

@Controller('rewards')
export class RewardsController {
  constructor(private readonly rewards: RewardsService) {}

  @Get('daily')
  status(@CurrentUser() auth: AuthUser) {
    return this.rewards.status(auth.id);
  }

  @Post('daily/claim')
  @HttpCode(200)
  claim(@CurrentUser() auth: AuthUser) {
    return this.rewards.claim(auth.id);
  }
}
