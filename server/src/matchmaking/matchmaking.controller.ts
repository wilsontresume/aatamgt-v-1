import { Body, Controller, Delete, Get, HttpCode, Post, Query } from '@nestjs/common';
import { IsString, Matches } from 'class-validator';
import { MatchmakingService } from './matchmaking.service';
import { TiersService } from './tiers.service';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';

class QueueBody {
  @IsString()
  @Matches(/^[a-z0-9-]{3,64}$/)
  gameKey: string;

  @IsString()
  @Matches(/^[a-z0-9-]{3,64}$/)
  tierId: string;
}

@Controller()
export class MatchmakingController {
  constructor(
    private readonly matchmaking: MatchmakingService,
    private readonly tiers: TiersService,
  ) {}

  /** Active tier catalog for the game-entry screen (DB-backed). */
  @Get('tiers')
  async listTiers(@Query('gameKey') gameKey?: string) {
    return { items: await this.tiers.list(gameKey) };
  }

  @Get('matchmaking/status')
  async status(@CurrentUser() auth: AuthUser) {
    return this.matchmaking.status(auth.id);
  }

  @Post('matchmaking/queue')
  @HttpCode(200)
  async queue(@CurrentUser() auth: AuthUser, @Body() dto: QueueBody) {
    return this.matchmaking.queue(auth.id, dto);
  }

  @Delete('matchmaking/queue')
  @HttpCode(200)
  async cancel(@CurrentUser() auth: AuthUser) {
    return this.matchmaking.cancel(auth.id);
  }
}
