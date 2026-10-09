import { Controller, Get, Post, Query } from '@nestjs/common';
import { Type } from 'class-transformer';
import { IsIn, IsInt, IsOptional, IsString, Max, Min } from 'class-validator';
import { RankingsService } from './rankings.service';
import { RATED_GAME_KEYS } from './ranks';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { Public } from '../common/decorators/public.decorator';
import { Roles } from '../common/decorators/roles.decorator';

class LeaderboardQuery {
  @IsIn([...RATED_GAME_KEYS])
  gameKey: string;

  @IsOptional()
  @IsString()
  season?: string;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;
}

class HistoryQuery {
  @IsOptional()
  @IsIn([...RATED_GAME_KEYS])
  gameKey?: string;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(50)
  limit?: number;
}

@Controller('rankings')
export class RankingsController {
  constructor(private readonly rankings: RankingsService) {}

  /** The signed-in player's per-game rating, rank tier, record and position. */
  @Get('summary')
  summary(@CurrentUser() user: AuthUser) {
    return this.rankings.summary(user.id);
  }

  /** Top rated competitors for a game — public so standings can be browsed. */
  @Public()
  @Get('leaderboard')
  leaderboard(@Query() query: LeaderboardQuery) {
    return this.rankings.leaderboard(query.gameKey, query.season, query.limit);
  }

  /** The signed-in player's rating movement history (win/loss + deltas). */
  @Get('history')
  history(@CurrentUser() user: AuthUser, @Query() query: HistoryQuery) {
    return this.rankings.history(user.id, query.gameKey, query.limit);
  }

  /** Season rollover — administrators only. */
  @Roles('ADMIN')
  @Post('seasons')
  startSeason() {
    return this.rankings.startNextSeason();
  }
}
