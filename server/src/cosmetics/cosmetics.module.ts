import { Module } from '@nestjs/common';
import { CosmeticsController } from './cosmetics.controller';
import { CosmeticsService } from './cosmetics.service';
import { WalletModule } from '../wallet/wallet.module';
import { AnalyticsModule } from '../analytics/analytics.module';

@Module({
  imports: [WalletModule, AnalyticsModule],
  controllers: [CosmeticsController],
  providers: [CosmeticsService],
  exports: [CosmeticsService],
})
export class CosmeticsModule {}
