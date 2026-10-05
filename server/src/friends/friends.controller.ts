import { Body, Controller, Delete, Get, HttpCode, Param, Post } from '@nestjs/common';
import { IsString, Matches } from 'class-validator';
import { FriendsService } from './friends.service';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';

class FriendTargetDto {
  @IsString()
  @Matches(/^[a-zA-Z0-9_]{3,24}$/)
  username: string;
}

@Controller('friends')
export class FriendsController {
  constructor(private readonly friends: FriendsService) {}

  @Get()
  list(@CurrentUser() auth: AuthUser) {
    return this.friends.list(auth.id);
  }

  @Post('requests')
  @HttpCode(200)
  request(@CurrentUser() auth: AuthUser, @Body() dto: FriendTargetDto) {
    return this.friends.request(auth.id, dto.username);
  }

  @Post('requests/:id/accept')
  @HttpCode(200)
  accept(@CurrentUser() auth: AuthUser, @Param('id') id: string) {
    return this.friends.respond(auth.id, id, 'accept');
  }

  @Post('requests/:id/decline')
  @HttpCode(200)
  decline(@CurrentUser() auth: AuthUser, @Param('id') id: string) {
    return this.friends.respond(auth.id, id, 'decline');
  }

  @Post('block')
  @HttpCode(200)
  block(@CurrentUser() auth: AuthUser, @Body() dto: FriendTargetDto) {
    return this.friends.block(auth.id, dto.username);
  }

  @Delete(':id')
  remove(@CurrentUser() auth: AuthUser, @Param('id') id: string) {
    return this.friends.remove(auth.id, id);
  }
}
