import { Module } from '@nestjs/common';
import { WalletModule } from '../wallet/wallet.module';
import { HooksController } from './hooks.controller';
import { PurchasesController } from './purchases.controller';
import { ShopController } from './shop.controller';
import { ShopService } from './shop.service';
import { StoreVerifierRegistry } from './store-verifier';
import { AnalyticsModule } from '../analytics/analytics.module';

@Module({
  imports: [WalletModule, AnalyticsModule],
  controllers: [ShopController, PurchasesController, HooksController],
  providers: [ShopService, StoreVerifierRegistry],
  exports: [ShopService],
})
export class ShopModule {}
