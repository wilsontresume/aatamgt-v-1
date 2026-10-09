import { Body, Controller, Headers, HttpCode, Post } from '@nestjs/common';
import { Public } from '../common/decorators/public.decorator';
import { ShopService } from './shop.service';

/**
 * Google Play Real-time developer notifications (Pub/Sub push).
 * Refunds, revocations, expiries and renewals land here and are
 * applied server-side; the push identity is verified in production.
 */
@Controller('hooks')
export class HooksController {
  constructor(private readonly shop: ShopService) {}

  @Public()
  @Post('rtdn')
  @HttpCode(200)
  rtdn(@Headers('authorization') authorization: string | undefined, @Body() body: unknown) {
    return this.shop.handleRtdn(authorization, body);
  }
}
