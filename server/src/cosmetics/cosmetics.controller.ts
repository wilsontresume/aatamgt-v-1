import { Controller, Get, HttpCode, Param, Post } from '@nestjs/common';
import { Matches } from 'class-validator';
import { CosmeticsService } from './cosmetics.service';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';

class CosmeticKeyParam {
  @Matches(/^[a-z0-9_-]{3,64}$/)
  key: string;
}

@Controller('cosmetics')
export class CosmeticsController {
  constructor(private readonly cosmetics: CosmeticsService) {}

  @Get()
  list(@CurrentUser() auth: AuthUser) {
    return this.cosmetics.list(auth.id);
  }

  @Post(':key/claim')
  @HttpCode(200)
  claim(@CurrentUser() auth: AuthUser, @Param() params: CosmeticKeyParam) {
    return this.cosmetics.claim(auth.id, params.key);
  }

  @Post(':key/purchase')
  @HttpCode(200)
  purchase(@CurrentUser() auth: AuthUser, @Param() params: CosmeticKeyParam) {
    return this.cosmetics.purchase(auth.id, params.key);
  }

  @Post(':key/equip')
  @HttpCode(200)
  equip(@CurrentUser() auth: AuthUser, @Param() params: CosmeticKeyParam) {
    return this.cosmetics.equip(auth.id, params.key);
  }

  @Post(':key/grant')
  @HttpCode(200)
  grant(@CurrentUser() auth: AuthUser, @Param() params: CosmeticKeyParam) {
    return this.cosmetics.grant(auth.id, params.key);
  }
}
