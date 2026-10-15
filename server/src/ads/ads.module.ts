import { Module } from '@nestjs/common';
import { AdsController } from './ads.controller';
import { AdsService } from './ads.service';
import { AdVerifierRegistry, StubAdVerifier } from './ad-verifier';
import { WalletModule } from '../wallet/wallet.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { AnalyticsModule } from '../analytics/analytics.module';

@Module({
  imports: [WalletModule, NotificationsModule, AnalyticsModule],
  controllers: [AdsController],
  providers: [AdsService, StubAdVerifier, AdVerifierRegistry],
  exports: [AdsService],
})
export class AdsModule {}
