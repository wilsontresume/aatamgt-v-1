import { Module } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_PIPE } from '@nestjs/core';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import configuration from './config/configuration';
import { validate } from './config/env.validation';
import { AppConfig } from './config/configuration';
import { PinoLoggerService } from './common/logger/pino-logger.service';
import { AllExceptionsFilter } from './common/filters/all-exceptions.filter';
import { JwtAuthGuard } from './common/guards/jwt-auth.guard';
import { RolesGuard } from './common/guards/roles.guard';
import { ValidationPipe } from '@nestjs/common';
import { PrismaModule } from './prisma/prisma.module';
import { EventsModule } from './events/events.module';
import { HealthModule } from './health/health.module';
import { AuthModule } from './auth/auth.module';
import { UsersModule } from './users/users.module';
import { ProfilesModule } from './profiles/profiles.module';
import { WalletModule } from './wallet/wallet.module';
import { GamesModule } from './games/games.module';
import { MatchesModule } from './matches/matches.module';
import { RealtimeModule } from './realtime/realtime.module';
import { LeaderboardsModule } from './leaderboards/leaderboards.module';
import { RewardsModule } from './rewards/rewards.module';
import { AdsModule } from './ads/ads.module';
import { FriendsModule } from './friends/friends.module';
import { ChallengesModule } from './challenges/challenges.module';
import { NotificationsModule } from './notifications/notifications.module';
import { CosmeticsModule } from './cosmetics/cosmetics.module';
import { RankingsModule } from './rankings/rankings.module';
import { ShopModule } from './shop/shop.module';
import { AdminModule } from './admin/admin.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      envFilePath: ['.env'],
      load: [configuration],
      validate,
    }),
    ThrottlerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => {
        const app = config.get<AppConfig>('app') as AppConfig;
        return {
          throttlers: [
            { name: 'default', ttl: app.throttle.ttl * 1000, limit: app.throttle.limit },
          ],
        };
      },
    }),
    PrismaModule,
    EventsModule,
    HealthModule,
    AuthModule,
    UsersModule,
    ProfilesModule,
    WalletModule,
    GamesModule,
    MatchesModule,
    RealtimeModule,
    LeaderboardsModule,
    RewardsModule,
    AdsModule,
    FriendsModule,
    ChallengesModule,
    NotificationsModule,
    CosmeticsModule,
    RankingsModule,
    ShopModule,
    AdminModule,
  ],
  providers: [
    {
      provide: APP_PIPE,
      useValue: new ValidationPipe({
        whitelist: true,
        transform: true,
        forbidNonWhitelisted: true,
        transformOptions: { enableImplicitConversion: false },
      }),
    },
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    { provide: APP_GUARD, useClass: JwtAuthGuard },
    { provide: APP_GUARD, useClass: RolesGuard },
    {
      provide: APP_FILTER,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => {
        const app = config.get<AppConfig>('app') as AppConfig;
        return new AllExceptionsFilter(new PinoLoggerService(app?.logLevel ?? 'info'));
      },
    },
  ],
})
export class AppModule {}
