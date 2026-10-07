import { Body, Controller, Get, HttpCode, Post } from '@nestjs/common';
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

  /**
   * Rewarded-ad grant (Phase 7 stub). Body: { tier: BONUS|STANDARD,
   * idempotencyKey: <per-view unique key> }. No ad SDK yet — when one
   * lands, the key becomes the SDK-verified reward token.
   */
  @Post('ad')
  @HttpCode(200)
  claimAd(@CurrentUser() auth: AuthUser, @Body() body: Record<string, unknown>) {
    const tier = typeof body?.tier === 'string' ? body.tier : '';
    const idempotencyKey = typeof body?.idempotencyKey === 'string' ? body.idempotencyKey : '';
    return this.rewards.claimRewardedAd(auth.id, tier, idempotencyKey);
  }
}
