import { Body, Controller, Delete, Get, NotFoundException, Param, Patch } from '@nestjs/common';
import { UsersService } from './users.service';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { toPublicUser } from '../common/utils/user-view';
import { UpdateUserDto } from './dto/user.dto';

@Controller('users')
export class UsersController {
  constructor(private readonly users: UsersService) {}

  @Get('me')
  async me(@CurrentUser() auth: AuthUser) {
    const user = await this.users.findById(auth.id);
    return toPublicUser(user);
  }

  /**
   * Soft player-ID lookup for friend challenges: resolves a username to a
   * public identity (id + username) without exposing emails or status.
   * 404 for unknown, soft-deleted or banned accounts.
   */
  @Get('lookup/:username')
  async lookup(@Param('username') username: string) {
    let user;
    try {
      user = await this.users.findByUsername(username);
    } catch {
      throw new NotFoundException('User not found');
    }
    if (user.status !== 'ACTIVE') throw new NotFoundException('User not found');
    return { id: user.id, username: user.username };
  }

  @Patch('me')
  async update(@CurrentUser() auth: AuthUser, @Body() dto: UpdateUserDto) {
    const user = await this.users.update(auth.id, dto);
    return toPublicUser(user);
  }

  @Delete('me')
  async remove(@CurrentUser() auth: AuthUser) {
    const user = await this.users.softDelete(auth.id);
    return { id: user.id, deletedAt: user.deletedAt?.toISOString() ?? null };
  }
}
