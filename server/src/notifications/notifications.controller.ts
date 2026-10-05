import { Body, Controller, Get, Patch, Post, Query } from '@nestjs/common';
import { IsArray, IsIn, IsOptional, IsString } from 'class-validator';
import { PaginationQuery } from '../common/dto/pagination.query';
import { NotificationsService } from './notifications.service';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';

class ListQuery extends PaginationQuery {
  @IsOptional()
  @IsIn(['true', 'false'])
  unreadOnly?: string;
}

class MarkReadDto {
  @IsOptional()
  @IsArray()
  @IsString({ each: true })
  ids?: string[];
}

@Controller('notifications')
export class NotificationsController {
  constructor(private readonly notifications: NotificationsService) {}

  @Get()
  list(@CurrentUser() auth: AuthUser, @Query() query: ListQuery) {
    return this.notifications.list(auth.id, query, query.unreadOnly === 'true');
  }

  @Get('unread-count')
  async unread(@CurrentUser() auth: AuthUser) {
    return { count: await this.notifications.unreadCount(auth.id) };
  }

  @Patch('read-all')
  async readAll(@CurrentUser() auth: AuthUser) {
    return { updated: await this.notifications.markAllRead(auth.id) };
  }

  @Post('read')
  async read(@CurrentUser() auth: AuthUser, @Body() dto: MarkReadDto) {
    return { updated: await this.notifications.markRead(auth.id, dto.ids) };
  }
}
