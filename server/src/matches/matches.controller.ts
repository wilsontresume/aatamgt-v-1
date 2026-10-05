import { Body, Controller, Get, HttpCode, Param, Post, Query } from '@nestjs/common';
import { Type } from 'class-transformer';
import { IsIn, IsInt, IsObject, IsOptional, IsString, Matches, Min } from 'class-validator';
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

@Controller('matches')
export class MatchesController {
  constructor(private readonly matches: MatchesService) {}

  @Post()
  async create(@CurrentUser() auth: AuthUser, @Body() dto: CreateMatchBody) {
    const match = await this.matches.create(auth.id, dto);
    return this.matches.serialize(match);
  }

  @Get()
  async mine(@CurrentUser() auth: AuthUser) {
    const list = await this.matches.listMy(auth.id);
    return { items: list.map((m) => this.matches.serialize(m)) };
  }

  @Get(':id')
  async get(@Param('id') id: string, @Query('history') history?: string) {
    const limit = history ? Number(history) : 50;
    const match = await this.matches.getMatch(id, { includeHistory: limit });
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
}
