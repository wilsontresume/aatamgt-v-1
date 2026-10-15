import { Module } from '@nestjs/common';
import { PrismaModule } from '../prisma/prisma.module';
import { GamesModule } from '../games/games.module';
import { MatchesModule } from '../matches/matches.module';
import { WalletModule } from '../wallet/wallet.module';
import { TiersModule } from './tiers.module';
import { MatchmakingService } from './matchmaking.service';
import { MatchmakingController } from './matchmaking.controller';
import { MatchAiDriver } from './match-ai.driver';

@Module({
  imports: [PrismaModule, GamesModule, MatchesModule, WalletModule, TiersModule],
  controllers: [MatchmakingController],
  providers: [MatchmakingService, MatchAiDriver],
  exports: [MatchmakingService, MatchAiDriver],
})
export class MatchmakingModule {}
