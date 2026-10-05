import { Body, Controller, Get, Param, Patch } from '@nestjs/common';
import { ProfilesService } from './profiles.service';
import { Public } from '../common/decorators/public.decorator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { UpdateProfileDto } from '../users/dto/user.dto';

@Controller('profiles')
export class ProfilesController {
  constructor(private readonly profiles: ProfilesService) {}

  @Get('me')
  async me(@CurrentUser() auth: AuthUser) {
    const profile = await this.profiles.getById(auth.id);
    return this.profiles.serialize(profile);
  }

  @Patch('me')
  async update(@CurrentUser() auth: AuthUser, @Body() dto: UpdateProfileDto) {
    const profile = await this.profiles.update(auth.id, dto);
    return this.profiles.serialize(profile);
  }

  @Public()
  @Get(':username')
  async byUsername(@Param('username') username: string) {
    const profile = await this.profiles.getByUsername(username);
    return this.profiles.serialize(profile);
  }
}
