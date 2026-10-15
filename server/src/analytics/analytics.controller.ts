import { Body, Controller, Get, Post, Query } from '@nestjs/common';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsIn,
  IsObject,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';
import { Throttle } from '@nestjs/throttler';
import { AnalyticsService, CLIENT_EVENT_TYPES } from './analytics.service';
import { Public } from '../common/decorators/public.decorator';
import { Roles } from '../common/decorators/roles.decorator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';

const INSTALL_ID_PATTERN = /^[0-9a-fA-F-]{16,64}$/;

class ClientEventDto {
  @IsIn([...CLIENT_EVENT_TYPES])
  type: (typeof CLIENT_EVENT_TYPES)[number];

  @IsOptional()
  @IsString()
  @MaxLength(64)
  sessionId?: string;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  gameKey?: string;

  @IsOptional()
  @IsObject()
  data?: Record<string, unknown>;

  @IsOptional()
  @IsString()
  @MaxLength(128)
  dedupeKey?: string;
}

class AnalyticsEventsBody {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(20)
  @ValidateNested({ each: true })
  @Type(() => ClientEventDto)
  events: ClientEventDto[];

  @IsOptional()
  @IsString()
  @Matches(INSTALL_ID_PATTERN)
  installId?: string;

  @IsOptional()
  @IsString()
  @MaxLength(32)
  platform?: string;

  @IsOptional()
  @IsString()
  @MaxLength(32)
  version?: string;
}

class AnonymousEventsBody {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(20)
  @ValidateNested({ each: true })
  @Type(() => ClientEventDto)
  events: ClientEventDto[];

  @IsString()
  @Matches(INSTALL_ID_PATTERN)
  installId: string;

  @IsOptional()
  @IsString()
  @MaxLength(32)
  platform?: string;

  @IsOptional()
  @IsString()
  @MaxLength(32)
  version?: string;
}

class SummaryQuery {
  @IsString()
  from: string;

  @IsString()
  to: string;
}

@Controller('analytics')
export class AnalyticsController {
  constructor(private readonly analytics: AnalyticsService) {}

  /**
   * Signed-in client batch. The userId always comes from the token —
   * a client can never write events attributed to another account.
   */
  @Post('events')
  async ingestEvents(@CurrentUser() user: AuthUser | undefined, @Body() body: AnalyticsEventsBody) {
    if (!user) throw new Error('Authenticated route reached without a user');
    return this.analytics.ingestClientEvents(user.id, body);
  }

  /**
   * Pre-login batch (install / first launch / anonymous play), keyed by
   * a client-minted random UUID. Hard-capped: this route is public.
   */
  @Public()
  @Throttle({ default: { limit: 30, ttl: 60_000 } })
  @Post('anonymous')
  ingestAnonymous(@Body() body: AnonymousEventsBody) {
    return this.analytics.ingestAnonymousEvents(body);
  }

  /** Staff metrics: DAU/MAU, retention, acquisition, game, monetization. */
  @Get('summary')
  @Roles('ADMIN')
  summary(@Query() query: SummaryQuery) {
    return this.analytics.summary(query.from, query.to);
  }
}
