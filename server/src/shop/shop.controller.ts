import { Body, Controller, Get, HttpCode, Param, Post } from '@nestjs/common';
import { IsIn, IsString, MinLength } from 'class-validator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { Public } from '../common/decorators/public.decorator';
import { ShopService } from './shop.service';

class DevIssueDto {
  @IsString()
  @MinLength(1)
  productId: string;
}

class DevStateDto {
  @IsIn(['PENDING', 'PURCHASED', 'CANCELED'])
  state: string;
}

class DevTokenParam {
  @IsString()
  @MinLength(1)
  token: string;
}

@Controller('shop')
export class ShopController {
  constructor(private readonly shop: ShopService) {}

  /** Public catalog: platform product IDs, never prices. */
  @Public()
  @Get('products')
  products() {
    return this.shop.catalog();
  }

  /** The signed-in player's subscription/entitlement state. */
  @Get('entitlements')
  entitlements(@CurrentUser() auth: AuthUser) {
    return this.shop.royalPassStatus(auth.id);
  }

  // --- Dev store simulator (503 outside dev/test) ----------------------------

  @Post('dev/issue')
  @HttpCode(200)
  devIssue(@CurrentUser() auth: AuthUser, @Body() dto: DevIssueDto) {
    return this.shop.devIssue(auth.id, dto.productId);
  }

  @Post('dev/store/:token/state')
  @HttpCode(200)
  devSetState(@Param() params: DevTokenParam, @Body() dto: DevStateDto) {
    return this.shop.devSetState(params.token, dto.state);
  }

  @Get('dev/owned')
  devOwned(@CurrentUser() auth: AuthUser) {
    return this.shop.devOwned(auth.id);
  }
}
