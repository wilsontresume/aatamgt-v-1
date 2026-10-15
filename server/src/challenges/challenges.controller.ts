import { Body, Controller, Get, HttpCode, Param, Post } from '@nestjs/common';
import { IsOptional, IsString, Matches } from 'class-validator';
import { ChallengesService } from './challenges.service';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';

class CreateChallengeBody {
  @IsString()
  @Matches(/^[a-z0-9-]{3,64}$/)
  gameKey: string;

  @IsOptional()
  @IsString()
  @Matches(/^[a-zA-Z0-9_]{3,24}$/)
  inviteeUsername?: string;

  @IsOptional()
  @IsString()
  @Matches(/^[a-z0-9-]{3,64}$/)
  tierId?: string;
}

@Controller('challenges')
export class ChallengesController {
  constructor(private readonly challenges: ChallengesService) {}

  @Post()
  @HttpCode(200)
  create(@CurrentUser() auth: AuthUser, @Body() dto: CreateChallengeBody) {
    return this.challenges.create(auth.id, dto);
  }

  @Get()
  inbox(@CurrentUser() auth: AuthUser) {
    return this.challenges.inbox(auth.id);
  }

  @Get(':code')
  get(@CurrentUser() auth: AuthUser, @Param('code') code: string) {
    return this.challenges.get(auth.id, code);
  }

  @Post(':code/accept')
  @HttpCode(200)
  accept(@CurrentUser() auth: AuthUser, @Param('code') code: string) {
    return this.challenges.accept(auth.id, code);
  }

  @Post(':code/decline')
  @HttpCode(200)
  decline(@CurrentUser() auth: AuthUser, @Param('code') code: string) {
    return this.challenges.decline(auth.id, code);
  }

  @Post(':code/cancel')
  @HttpCode(200)
  cancel(@CurrentUser() auth: AuthUser, @Param('code') code: string) {
    return this.challenges.cancel(auth.id, code);
  }
}
