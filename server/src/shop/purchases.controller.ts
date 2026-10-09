import { Body, Controller, Get, HttpCode, Post } from '@nestjs/common';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsIn,
  IsOptional,
  IsString,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { PLATFORMS, ShopService, SubmitPurchaseInput } from './shop.service';

class SubmitPurchaseDto implements SubmitPurchaseInput {
  @IsString()
  @MinLength(1)
  productId: string;

  @IsString()
  @MinLength(1)
  purchaseToken: string;

  @IsOptional()
  @IsIn([...PLATFORMS])
  platform?: string;
}

class RestoreItemDto {
  @IsString()
  @MinLength(1)
  productId: string;

  @IsString()
  @MinLength(1)
  purchaseToken: string;
}

class RestoreDto {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(50)
  @ValidateNested({ each: true })
  @Type(() => RestoreItemDto)
  items: RestoreItemDto[];
}

/**
 * Purchase pipeline endpoints. A purchase is only ever granted
 * after the store verifier confirms the token server-side — the
 * client's billing callback is treated as a claim, not a fact.
 */
@Controller('purchases')
export class PurchasesController {
  constructor(private readonly shop: ShopService) {}

  /** Verify + settle one store transaction (idempotent on the token). */
  @Post()
  @HttpCode(200)
  submit(@CurrentUser() auth: AuthUser, @Body() dto: SubmitPurchaseDto) {
    return this.shop.submit(auth.id, dto);
  }

  /** Re-check store-owned tokens and settle anything unprocessed. */
  @Post('restore')
  @HttpCode(200)
  restore(@CurrentUser() auth: AuthUser, @Body() dto: RestoreDto) {
    return this.shop.restore(auth.id, dto.items);
  }

  /** This account's verified purchase history. */
  @Get()
  list(@CurrentUser() auth: AuthUser) {
    return this.shop.list(auth.id);
  }
}
