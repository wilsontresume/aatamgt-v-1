import { Controller, Get, Param, Post, Query } from '@nestjs/common';
import { IsIn } from 'class-validator';
import { LeaderboardsService } from './leaderboards.service';
import { Public } from '../common/decorators/public.decorator';
import { LeaderboardPeriod } from '@prisma/client';

class PeriodQuery {
  @IsIn(['DAILY', 'WEEKLY', 'ALL_TIME'])
  period: LeaderboardPeriod = 'ALL_TIME';
}

@Controller('leaderboards')
export class LeaderboardsController {
  constructor(private readonly leaderboards: LeaderboardsService) {}

  @Public()
  @Get(':key')
  async get(@Param('key') key: string, @Query() query: PeriodQuery) {
    return this.leaderboards.get(key, query.period);
  }

  @Post(':key/refresh')
  async refresh(@Param('key') key: string, @Query() query: PeriodQuery) {
    const count = await this.leaderboards.refresh(key, query.period);
    return { key, period: query.period, entries: count };
  }
}
