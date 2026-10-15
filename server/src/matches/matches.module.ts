import { Module } from '@nestjs/common';
import { GamesModule } from '../games/games.module';
import { RankingsModule } from '../rankings/rankings.module';
import { AnalyticsModule } from '../analytics/analytics.module';
import { WalletModule } from '../wallet/wallet.module';
import { TiersModule } from '../matchmaking/tiers.module';
import { MatchesController } from './matches.controller';
import { MatchesService } from './matches.service';
import { MatchClockService } from './match-clock.service';

@Module({
  imports: [GamesModule, RankingsModule, AnalyticsModule, WalletModule, TiersModule],
  controllers: [MatchesController],
  providers: [MatchesService, MatchClockService],
  exports: [MatchesService, MatchClockService],
})
export class MatchesModule {}
