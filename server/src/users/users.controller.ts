import { Body, Controller, Delete, Get, Patch } from '@nestjs/common';
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
