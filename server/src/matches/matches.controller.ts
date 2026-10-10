import {
  Body,
  Controller,
  ForbiddenException,
  Get,
  HttpCode,
  Param,
  Post,
  Query,
} from '@nestjs/common';
import { Type } from 'class-transformer';
import {
  IsIn,
  IsInt,
  IsObject,
  IsOptional,
  IsString,
  Matches,
  Max,
  Min,
} from 'class-validator';
import { MatchesService } from './matches.service';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';

class CreateMatchBody {
  @IsString()
  @Matches(/^[a-z0-9-]{3,64}$/)
  gameKey: string;

  @IsOptional()
  @IsIn(['CASUAL', 'RANKED', 'PRIVATE'])
  mode?: 'CASUAL' | 'RANKED' | 'PRIVATE';

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  stakeCoins?: number;
}

class SubmitMoveBody {
  @IsObject()
  payload: Record<string, unknown>;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  clientSeq?: number;
}

class MatchViewQuery {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  @Max(200)
  history?: number;
}

@Controller('matches')
export class MatchesController {
  constructor(private readonly matches: MatchesService) {}

  @Post()
  async create(@CurrentUser() auth: AuthUser, @Body() dto: CreateMatchBody) {
    const match = await this.matches.create(auth.id, dto);
    return this.matches.serialize(match);
  }

  @Get()
  async mine(@CurrentUser() auth: AuthUser, @Query('status') status?: string) {
    const list = await this.matches.listMy(auth.id, status);
    return { items: list.map((m) => this.matches.serialize(m)) };
  }

  /**
   * Match snapshots are participant-only: the board state, move history
   * and player list are gameplay data, so an unrelated account gets 403
   * instead of a horizontal read of any match id it can guess.
   */
  @Get(':id')
  async get(
    @CurrentUser() auth: AuthUser,
    @Param('id') id: string,
    @Query() query: MatchViewQuery,
  ) {
    const match = await this.matches.getMatch(id, { includeHistory: query.history ?? 50 });
    if (!match.players.some((p) => p.userId === auth.id)) {
      throw new ForbiddenException('Only match participants can view this match');
    }
    return {
      ...this.matches.serialize(match),
      moves: match.moves.map((m) => ({
        seq: m.seq,
        userId: m.userId,
        payload: m.payload,
        serverAt: m.serverAt.toISOString(),
      })),
    };
  }

  @Post(':id/join')
  @HttpCode(200)
  async join(@CurrentUser() auth: AuthUser, @Param('id') id: string) {
    const match = await this.matches.join(auth.id, id);
    return this.matches.serialize(match);
  }

  @Post(':id/leave')
  @HttpCode(200)
  async leave(@CurrentUser() auth: AuthUser, @Param('id') id: string) {
    const match = await this.matches.leave(auth.id, id);
    return this.matches.serialize(match);
  }

  @Post(':id/moves')
  @HttpCode(200)
  async move(@CurrentUser() auth: AuthUser, @Param('id') id: string, @Body() dto: SubmitMoveBody) {
    return this.matches.submitMove(auth.id, id, dto);
  }

  /** Server-decided resignation: the opponent wins, both records update. */
  @Post(':id/resign')
  @HttpCode(200)
  async resign(@CurrentUser() auth: AuthUser, @Param('id') id: string) {
    const outcome = await this.matches.resign(auth.id, id);
    return {
      ok: true,
      matchId: id,
      stateVersion: outcome.stateVersion,
      completed: {
        reason: outcome.completion.reason,
        winnerSeat: outcome.completion.winnerSeat,
        results: Object.fromEntries(outcome.results),
      },
    };
  }

  /** Starts a fresh match with swapped seats; idempotent per match. */
  @Post(':id/rematch')
  @HttpCode(200)
  async rematch(@CurrentUser() auth: AuthUser, @Param('id') id: string) {
    const match = await this.matches.rematch(auth.id, id);
    return this.matches.serialize(match);
  }
}
