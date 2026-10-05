import { Body, Controller, Get, Param, Patch, Post, Query } from '@nestjs/common';
import { IsArray, IsIn, IsInt, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';
import { Type } from 'class-transformer';
import { AdminService, CompleteMatchInput } from './admin.service';
import { Roles } from '../common/decorators/roles.decorator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { PaginationQuery } from '../common/dto/pagination.query';

class UserStatusBody {
  @IsIn(['ACTIVE', 'SUSPENDED', 'BANNED'])
  status: 'ACTIVE' | 'SUSPENDED' | 'BANNED';

  @IsOptional()
  @IsString()
  @MaxLength(255)
  reason?: string;
}

class PlayerResultBody {
  @IsString()
  userId: string;

  @IsIn(['WIN', 'LOSS', 'DRAW', 'ABANDONED'])
  result: 'WIN' | 'LOSS' | 'DRAW' | 'ABANDONED';

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  score?: number;
}

class FinalizeMatchBody implements CompleteMatchInput {
  @IsIn(['COMPLETED', 'ABANDONED', 'CANCELLED', 'PAUSED', 'ACTIVE'])
  status: CompleteMatchInput['status'];

  @IsOptional()
  @IsArray()
  @Type(() => PlayerResultBody)
  players?: PlayerResultBody[];

  @IsOptional()
  @IsString()
  @MaxLength(255)
  reason?: string;
}

class AdjustWalletBody {
  @Type(() => Number)
  @IsInt()
  @Min(-1_000_000)
  @Max(1_000_000)
  amount: number;

  @IsOptional()
  @IsString()
  @MaxLength(255)
  memo?: string;
}

class AdminListQuery extends PaginationQuery {
  @IsOptional()
  @IsString()
  q?: string;

  @IsOptional()
  @IsIn(['PENDING', 'ACTIVE', 'PAUSED', 'COMPLETED', 'ABANDONED', 'CANCELLED'])
  status?: string;
}

@Controller('admin')
export class AdminController {
  constructor(private readonly admin: AdminService) {}

  @Roles('MODERATOR', 'ADMIN')
  @Get('stats')
  stats() {
    return this.admin.stats();
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('users')
  users(@Query() query: AdminListQuery) {
    return this.admin.users(query);
  }

  @Roles('ADMIN')
  @Patch('users/:id/status')
  status(@CurrentUser() actor: AuthUser, @Param('id') id: string, @Body() dto: UserStatusBody) {
    return this.admin.setUserStatus(actor.id, id, dto.status, dto.reason);
  }

  @Roles('MODERATOR', 'ADMIN')
  @Get('matches')
  matches(@Query() query: AdminListQuery) {
    return this.admin.matches(query);
  }

  @Roles('ADMIN')
  @Patch('matches/:id/finalize')
  finalize(
    @CurrentUser() actor: AuthUser,
    @Param('id') id: string,
    @Body() dto: FinalizeMatchBody,
  ) {
    return this.admin.finalizeMatch(actor.id, id, dto);
  }

  @Roles('ADMIN')
  @Post('wallets/:userId/adjust')
  adjust(
    @CurrentUser() actor: AuthUser,
    @Param('userId') userId: string,
    @Body() dto: AdjustWalletBody,
  ) {
    return this.admin.adjustWallet(actor.id, userId, dto.amount, dto.memo);
  }

  @Roles('ADMIN')
  @Get('audit')
  audit(@Query() query: PaginationQuery) {
    return this.admin.auditLog(query);
  }
}
