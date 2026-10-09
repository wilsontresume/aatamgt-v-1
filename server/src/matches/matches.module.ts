import { Module } from '@nestjs/common';
import { GamesModule } from '../games/games.module';
import { RankingsModule } from '../rankings/rankings.module';
import { MatchesController } from './matches.controller';
import { MatchesService } from './matches.service';
import { MatchClockService } from './match-clock.service';

@Module({
  imports: [GamesModule, RankingsModule],
  controllers: [MatchesController],
  providers: [MatchesService, MatchClockService],
  exports: [MatchesService, MatchClockService],
})
export class MatchesModule {}
