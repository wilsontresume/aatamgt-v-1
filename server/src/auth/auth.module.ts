import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { PassportModule } from '@nestjs/passport';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { JwtRefreshGuard } from './jwt-refresh.guard';
import { JwtRefreshStrategy } from './jwt-refresh.strategy';
import { JwtStrategy } from './jwt.strategy';
import { WalletModule } from '../wallet/wallet.module';
import { AnalyticsModule } from '../analytics/analytics.module';

@Module({
  imports: [PassportModule, JwtModule.register({}), WalletModule, AnalyticsModule],
  controllers: [AuthController],
  providers: [AuthService, JwtStrategy, JwtRefreshStrategy, JwtRefreshGuard],
  exports: [AuthService],
})
export class AuthModule {}
