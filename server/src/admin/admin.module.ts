import { Module } from '@nestjs/common';
import { WalletModule } from '../wallet/wallet.module';
import { AdminController } from './admin.controller';
import { AdminDashboardController } from './dashboard.controller';
import { AdminService } from './admin.service';
import { AdminDashboardService } from './dashboard.service';

@Module({
  imports: [WalletModule],
  controllers: [AdminController, AdminDashboardController],
  providers: [AdminService, AdminDashboardService],
  exports: [AdminService],
})
export class AdminModule {}
