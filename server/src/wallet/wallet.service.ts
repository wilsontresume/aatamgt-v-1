import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
  UnprocessableEntityException,
} from '@nestjs/common';
import { Prisma, Wallet, WalletTransaction, WalletTxType } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { PaginationQuery, Paginated } from '../common/dto/pagination.query';

class VersionConflictError extends Error {
  constructor() {
    super('wallet version conflict');
  }
}

export interface TransferInput {
  userId: string;
  amount: number;
  type: WalletTxType;
  refType?: string;
  refId?: string;
  idempotencyKey?: string;
  memo?: string;
  currency?: string;
}

export interface TransferResult {
  transaction: WalletTransaction;
  wallet: Wallet;
  replayed: boolean;
}

const MAX_ATTEMPTS = 5;

@Injectable()
export class WalletService {
  constructor(private readonly prisma: PrismaService) {}

  async getOrCreate(userId: string, currency = 'COIN'): Promise<Wallet> {
    const existing = await this.prisma.wallet.findUnique({
      where: { userId_currency: { userId, currency } },
    });
    if (existing) return existing;
    return this.prisma.wallet.create({ data: { userId, currency, balance: 0 } });
  }

  async getBalance(userId: string, currency = 'COIN'): Promise<Wallet> {
    return this.getOrCreate(userId, currency);
  }

  async listTransactions(
    userId: string,
    query: PaginationQuery,
  ): Promise<Paginated<WalletTransaction>> {
    const wallet = await this.getOrCreate(userId);
    const where = { walletId: wallet.id };
    const [items, total] = await Promise.all([
      this.prisma.walletTransaction.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: query.skip,
        take: query.limit,
      }),
      this.prisma.walletTransaction.count({ where }),
    ]);
    return { items, page: query.page, limit: query.limit, total };
  }

  async credit(userId: string, amount: number, input: Omit<TransferInput, 'userId' | 'amount'>) {
    if (amount <= 0) throw new BadRequestException('Credit amount must be positive');
    return this.apply({ ...input, userId, amount });
  }

  async debit(userId: string, amount: number, input: Omit<TransferInput, 'userId' | 'amount'>) {
    if (amount <= 0) throw new BadRequestException('Debit amount must be positive');
    return this.apply({ ...input, userId, amount: -amount });
  }

  /**
   * Applies a signed amount atomically: wallet row, version bump and ledger row
   * are committed together. Idempotency keys make retries safe.
   */
  async apply(input: TransferInput): Promise<TransferResult> {
    if (!Number.isInteger(input.amount) || input.amount === 0) {
      throw new BadRequestException('amount must be a non-zero integer');
    }

    if (input.idempotencyKey) {
      const replay = await this.findByIdempotencyKey(input.idempotencyKey);
      if (replay) return replay;
    }

    let lastConflict = false;
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      try {
        return await this.execute(input);
      } catch (error) {
        if (error instanceof VersionConflictError) {
          lastConflict = true;
          continue;
        }
        if (
          error instanceof Prisma.PrismaClientKnownRequestError &&
          error.code === 'P2002' &&
          input.idempotencyKey
        ) {
          const replay = await this.findByIdempotencyKey(input.idempotencyKey);
          if (replay) return replay;
        }
        throw error;
      }
    }
    if (lastConflict) throw new ConflictException('Wallet is busy, please retry');
    throw new ConflictException('Unable to apply wallet operation');
  }

  private async execute(input: TransferInput): Promise<TransferResult> {
    const currency = input.currency ?? 'COIN';
    return this.prisma.$transaction(async (tx) => {
      const wallet = await tx.wallet.findUnique({
        where: { userId_currency: { userId: input.userId, currency } },
      });
      if (!wallet) throw new NotFoundException('Wallet not found');

      const nextBalance = wallet.balance + input.amount;
      if (nextBalance < 0) {
        throw new UnprocessableEntityException('Insufficient balance');
      }

      const updated = await tx.wallet.updateMany({
        where: { id: wallet.id, version: wallet.version },
        data: { balance: { increment: input.amount }, version: { increment: 1 } },
      });
      if (updated.count === 0) throw new VersionConflictError();

      const row = await tx.walletTransaction.create({
        data: {
          walletId: wallet.id,
          amount: input.amount,
          balanceAfter: nextBalance,
          type: input.type,
          refType: input.refType,
          refId: input.refId,
          idempotencyKey: input.idempotencyKey,
          memo: input.memo,
        },
      });

      const fresh = await tx.wallet.findUniqueOrThrow({ where: { id: wallet.id } });
      return { transaction: row, wallet: fresh, replayed: false };
    });
  }

  private async findByIdempotencyKey(key: string): Promise<TransferResult | null> {
    const row = await this.prisma.walletTransaction.findUnique({
      where: { idempotencyKey: key },
      include: { wallet: true },
    });
    if (!row) return null;
    return { transaction: row, wallet: row.wallet, replayed: true };
  }
}
