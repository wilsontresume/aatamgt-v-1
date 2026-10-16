import { Controller, Get, Query } from '@nestjs/common';
import { IsOptional, Matches } from 'class-validator';
import { AdminDashboardService } from './dashboard.service';
import { Roles } from '../common/decorators/roles.decorator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';

const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

class DashboardQuery {
  @IsOptional()
  @Matches(ISO_DAY, { message: '`from` must be a valid YYYY-MM-DD date' })
  from?: string;

  @IsOptional()
  @Matches(ISO_DAY, { message: '`to` must be a valid YYYY-MM-DD date' })
  to?: string;

  @IsOptional()
  @Matches(/^[a-z0-9-]{3,64}$/, { message: '`gameKey` must be a game key' })
  gameKey?: string;
}

/**
 * Aggregated dashboard metrics. Read-only: MODERATOR and ADMIN may view;
 * the recent-audit slice is populated only for ADMIN (matching the
 * ADMIN-only rule on GET /admin/audit).
 */
@Controller('admin/dashboard')
export class AdminDashboardController {
  constructor(private readonly dashboard: AdminDashboardService) {}

  @Roles('MODERATOR', 'ADMIN')
  @Get()
  summary(@Query() query: DashboardQuery, @CurrentUser() actor: AuthUser) {
    return this.dashboard.summary(query, actor.role);
  }
}
