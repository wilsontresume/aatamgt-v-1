import { Controller, Get, Query } from '@nestjs/common';
import { WalletService } from './wallet.service';
import { CurrentUser, AuthUser } from '../common/decorators/current-user.decorator';
import { PaginationQuery } from '../common/dto/pagination.query';

@Controller('wallet')
export class WalletController {
  constructor(private readonly wallet: WalletService) {}

  @Get()
  async balance(@CurrentUser() auth: AuthUser) {
    const wallet = await this.wallet.getBalance(auth.id);
    return {
      currency: wallet.currency,
      balance: wallet.balance,
      lockedBalance: wallet.lockedBalance,
      version: wallet.version,
    };
  }

  @Get('transactions')
  async transactions(@CurrentUser() auth: AuthUser, @Query() query: PaginationQuery) {
    const page = await this.wallet.listTransactions(auth.id, query);
    return {
      items: page.items.map((row) => ({
        id: row.id,
        amount: row.amount,
        balanceAfter: row.balanceAfter,
        type: row.type,
        refType: row.refType,
        refId: row.refId,
        memo: row.memo,
        createdAt: row.createdAt.toISOString(),
      })),
      page: page.page,
      limit: page.limit,
      total: page.total,
    };
  }
}
