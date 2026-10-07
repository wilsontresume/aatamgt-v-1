import { Body, Controller, Get, HttpCode, Post } from '@nestjs/common';
import { AdsService } from './ads.service';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';

@Controller('ads')
export class AdsController {
  constructor(private readonly ads: AdsService) {}

  /** Server-driven ad config — unit IDs and rules never live client-side. */
  @Get('config')
  config() {
    return this.ads.configView();
  }

  /** Rewarded flow step 1: the backend mints the ad opportunity. */
  @Post('rewarded/session')
  @HttpCode(200)
  async rewardedSession(@CurrentUser() auth: AuthUser, @Body() body: Record<string, unknown>) {
    const tier = typeof body?.tier === 'string' ? body.tier : '';
    const session = await this.ads.createRewardedSession(auth.id, tier);
    return {
      sessionId: session.id,
      nonce: session.nonce,
      provider: session.provider,
      tier: session.tier,
      expiresAt: session.expiresAt.toISOString(),
    };
  }

  /**
   * Rewarded flow final step: validates the reward server-side, then
   * issues coins. A client-only callback without a server-minted
   * session is rejected here.
   */
  @Post('rewarded/redeem')
  @HttpCode(200)
  redeem(@CurrentUser() auth: AuthUser, @Body() body: Record<string, unknown>) {
    const nonce = typeof body?.nonce === 'string' ? body.nonce : '';
    const payload =
      body?.payload && typeof body.payload === 'object' && !Array.isArray(body.payload)
        ? (body.payload as Record<string, unknown>)
        : undefined;
    return this.ads.redeemRewarded(auth.id, nonce, payload);
  }

  /** Frequency rules evaluated with server-side config after a match. */
  @Get('interstitial/eligibility')
  eligibility(@CurrentUser() auth: AuthUser) {
    return this.ads.interstitialEligibility(auth.id);
  }

  /** Client reports a finished presentation; powers the cooldown. */
  @Post('interstitial/shown')
  @HttpCode(200)
  shown(@CurrentUser() auth: AuthUser, @Body() body: Record<string, unknown>) {
    const matchId = typeof body?.matchId === 'string' ? body.matchId : '';
    return this.ads.recordInterstitialShow(auth.id, matchId);
  }
}
