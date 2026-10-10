import {
  BadRequestException,
  Injectable,
  Logger,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash } from 'node:crypto';
import { Prisma } from '@prisma/client';
import { AppConfig } from '../config/configuration';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { CATALOG, ShopProduct, findProduct, ROYAL_PASS_PRODUCT_KEY } from './catalog';
import { SystemConfigService } from '../config/system-config.service';
import { StoreVerification, StoreVerifierRegistry } from './store-verifier';

export const PLATFORMS = ['GOOGLE_PLAY', 'APPLE_APP_STORE'] as const;
export type Platform = (typeof PLATFORMS)[number];

export interface SubmitPurchaseInput {
  productId: string;
  purchaseToken: string;
  platform?: string;
}

export interface RestoreItemInput {
  productId: string;
  purchaseToken: string;
}

export interface RoyalPassStatus {
  key: string;
  active: boolean;
  expiresAt: string | null;
  expiresAtUnix: number | null;
}

export interface SubmitResult {
  status: 'granted' | 'pending' | 'canceled' | 'already_processed';
  purchase: {
    id: string;
    productKey: string;
    state: string;
    orderId: string | null;
    grantedAt: string | null;
  };
  coinsBalance: number;
  royalPass: RoyalPassStatus;
}

const DAY_MS = 86_400_000;

/** Google RTDN notification types (subscriptions / one-time products). */
const SUB_RECOVERED = 1;
const SUB_RENEWED = 2;
const SUB_CANCELED = 3;
const SUB_PURCHASED = 4;
const SUB_EXPIRED = 6;
const SUB_RESTARTED = 7;
const SUB_REVOKED = 12;
const ONETIME_PURCHASED = 4;
const ONETIME_CANCELED = 11;

/**
 * Phase 13 — purchase pipeline.
 *
 * Grants happen only after a store verifier confirms the purchase
 * with the platform itself; a client "success" callback is never
 * enough. (platform, purchaseToken) is unique, so replays of the
 * same store token are idempotent end to end.
 */
@Injectable()
export class ShopService {
  private readonly logger = new Logger(ShopService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly wallet: WalletService,
    private readonly registry: StoreVerifierRegistry,
    private readonly config: ConfigService,
    private readonly systemConfig: SystemConfigService,
  ) {}

  private get cfg(): AppConfig {
    return this.config.get<AppConfig>('app') as AppConfig;
  }

  // --- Catalog ---------------------------------------------------------------

  /**
   * Public catalog. Items never carry prices — in production the
   * store client owns pricing. `prices` appears only when the dev
   * store simulator is on (fixture prices for the simulator).
   * Royal Pass duration and availability are admin-configurable
   * (Phase 15); disabled products disappear from the catalog.
   */
  async catalog() {
    const iap = this.cfg.iap;
    const passEnabled = await this.systemConfig.boolean('shop.royal_pass_enabled');
    const passDays = await this.systemConfig.number('shop.royal_pass_days');
    const items = CATALOG.filter(
      (p) => passEnabled || p.productKey !== ROYAL_PASS_PRODUCT_KEY,
    ).map((p) => {
      const isPass = p.productKey === ROYAL_PASS_PRODUCT_KEY;
      return {
        productKey: p.productKey,
        kind: p.kind,
        coins: p.coins,
        passDays: isPass ? passDays : p.passDays,
        title: isPass ? `Royal Pass (${passDays} days)` : p.title,
        sortOrder: p.sortOrder,
      };
    });
    return {
      devStore: iap.devStore,
      items,
      prices: iap.devStore ? iap.devPrices : undefined,
    };
  }

  // --- Submission (verification + grant) --------------------------------------

  async submit(userId: string, input: SubmitPurchaseInput): Promise<SubmitResult> {
    const platform = this.normalizePlatform(input.platform);
    const product = this.resolveProduct(input.productId);
    await this.assertAvailable(product);
    if (!input.purchaseToken) {
      throw new BadRequestException('purchaseToken is required');
    }
    const token = input.purchaseToken;

    // Fast idempotent replay: the store token already settled.
    const existing = await this.prisma.purchase.findUnique({
      where: { platform_purchaseToken: { platform, purchaseToken: token } },
    });
    if (existing) return this.envelope(userId, 'already_processed', existing);

    const verifier = this.registry.get(platform);
    const verification = await verifier.verify(product, token, { userId });
    return this.settle(userId, platform, product, token, verification);
  }

  /**
   * Restore: re-checks a set of store-owned tokens (Play Billing
   * queryPurchases) and settles any that were never processed.
   * Best-effort per token — a bad token is reported, not fatal.
   * Every token still goes through full server-side verification.
   */
  async restore(userId: string, items: RestoreItemInput[]) {
    const platform: Platform = 'GOOGLE_PLAY';
    const verifier = this.registry.get(platform);
    const results: Array<Record<string, unknown>> = [];
    for (const item of items) {
      const product = findProduct(item.productId);
      if (!product) {
        results.push({ productId: item.productId, status: 'unknown_product' });
        continue;
      }
      try {
        await this.assertAvailable(product);
        const existing = await this.prisma.purchase.findUnique({
          where: {
            platform_purchaseToken: { platform, purchaseToken: item.purchaseToken },
          },
        });
        if (existing) {
          results.push({ productId: item.productId, status: 'already_processed' });
          continue;
        }
        const verification = await verifier.verify(product, item.purchaseToken, { userId });
        const settled = await this.settle(
          userId,
          platform,
          product,
          item.purchaseToken,
          verification,
        );
        results.push({ productId: item.productId, status: settled.status });
      } catch (error) {
        const message = error instanceof Error ? error.message : 'verification failed';
        results.push({ productId: item.productId, status: 'rejected', message });
      }
    }
    const wallet = await this.wallet.getBalance(userId);
    return {
      results,
      coinsBalance: wallet.balance,
      royalPass: await this.royalPassStatus(userId),
    };
  }

  private async settle(
    userId: string,
    platform: Platform,
    product: ShopProduct,
    token: string,
    verification: StoreVerification,
  ): Promise<SubmitResult> {
    const now = new Date();
    const passDays = await this.passDaysFor(product);
    if (verification.state === 'PENDING') {
      const row = await this.upsertUnsettled(userId, platform, product, token, verification, {
        state: 'PENDING',
        verifiedAt: now,
      }, passDays);
      return this.envelope(userId, 'pending', row);
    }
    if (verification.state === 'CANCELED') {
      // The store already considers it refunded/canceled — audit only.
      const row = await this.upsertUnsettled(userId, platform, product, token, verification, {
        state: 'REFUNDED',
        verifiedAt: now,
        revokedAt: now,
        revocationReason: 'store_canceled',
      }, passDays);
      return this.envelope(userId, 'canceled', row);
    }

    // PURCHASED — grant, with full idempotency on the store token.
    try {
      if (product.kind === 'COINS') {
        // Wallet first: its idempotency key makes the credit exactly-once
        // even if the process dies before the purchase row lands.
        const credit = await this.wallet.credit(userId, product.coins, {
          type: 'PURCHASE',
          idempotencyKey: this.walletKey('iap', platform, token),
          memo: `IAP ${product.productKey}`,
        });
        const purchase = await this.prisma.purchase.create({
          data: {
            userId,
            productKey: product.productKey,
            platform,
            purchaseToken: token,
            orderId: verification.orderId || null,
            state: 'GRANTED',
            coinAmount: product.coins,
            passDays: 0,
            verifiedAt: now,
            grantedAt: now,
            rawVerification: verification.raw as Prisma.InputJsonValue,
          },
        });
        return this.envelope(userId, 'granted', purchase, credit.wallet.balance);
      }
      const purchase = await this.grantPass(userId, platform, product, token, verification, passDays);
      return this.envelope(userId, 'granted', purchase);
    } catch (error) {
      if (this.isUniqueViolation(error)) {
        const row = await this.prisma.purchase.findUnique({
          where: { platform_purchaseToken: { platform, purchaseToken: token } },
        });
        if (row) return this.envelope(userId, 'already_processed', row);
      }
      throw error;
    }
  }

  /** Royal Pass: expiry extension + purchase row in one transaction. */
  private grantPass(
    userId: string,
    platform: Platform,
    product: ShopProduct,
    token: string,
    verification: StoreVerification,
    passDays: number,
  ) {
    const now = new Date();
    return this.prisma.$transaction(async (tx) => {
      const rows = await tx.$queryRaw<
        Array<{ royalPassExpiresAt: Date | null }>
      >`SELECT royalPassExpiresAt FROM User WHERE id = ${userId} FOR UPDATE`;
      const current = rows[0]?.royalPassExpiresAt ?? null;
      const base = current && current.getTime() > now.getTime() ? current : now;
      const next = new Date(base.getTime() + passDays * DAY_MS);
      await tx.user.update({
        where: { id: userId },
        data: { royalPassExpiresAt: next },
      });
      return tx.purchase.create({
        data: {
          userId,
          productKey: product.productKey,
          platform,
          purchaseToken: token,
          orderId: verification.orderId || null,
          state: 'GRANTED',
          coinAmount: 0,
          passDays,
          entitlementPreviousExpiresAt: current,
          entitlementExpiresAt: next,
          verifiedAt: now,
          grantedAt: now,
          rawVerification: verification.raw as Prisma.InputJsonValue,
        },
      });
    });
  }

  /** Stores a non-grantable verification outcome (pending/canceled). */
  private async upsertUnsettled(
    userId: string,
    platform: Platform,
    product: ShopProduct,
    token: string,
    verification: StoreVerification,
    data: {
      state: 'PENDING' | 'REFUNDED';
      verifiedAt: Date;
      revokedAt?: Date;
      revocationReason?: string;
    },
    passDays: number,
  ) {
    try {
      return await this.prisma.purchase.create({
        data: {
          userId,
          productKey: product.productKey,
          platform,
          purchaseToken: token,
          orderId: verification.orderId || null,
          state: data.state,
          coinAmount: product.coins,
          passDays,
          verifiedAt: data.verifiedAt,
          revokedAt: data.revokedAt,
          revocationReason: data.revocationReason,
          rawVerification: verification.raw as Prisma.InputJsonValue,
        },
      });
    } catch (error) {
      if (this.isUniqueViolation(error)) {
        const row = await this.prisma.purchase.findUnique({
          where: { platform_purchaseToken: { platform, purchaseToken: token } },
        });
        if (row) return row;
      }
      throw error;
    }
  }

  // --- Reads -----------------------------------------------------------------

  async list(userId: string) {
    const rows = await this.prisma.purchase.findMany({
      where: { userId },
      orderBy: { createdAt: 'desc' },
      take: 100,
    });
    return { items: rows.map((row) => this.summary(row)) };
  }

  async royalPassStatus(userId: string): Promise<RoyalPassStatus> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { royalPassExpiresAt: true },
    });
    const expiresAt = user?.royalPassExpiresAt ?? null;
    return {
      key: ROYAL_PASS_PRODUCT_KEY,
      active: expiresAt !== null && expiresAt.getTime() > Date.now(),
      expiresAt: expiresAt ? expiresAt.toISOString() : null,
      expiresAtUnix: expiresAt ? Math.floor(expiresAt.getTime() / 1000) : null,
    };
  }

  // --- Refunds / revocations -------------------------------------------------

  /**
   * Reverses a granted purchase: coins are clawed back (never below
   * zero) and a Royal Pass grant is rolled back to its previous
   * expiry when it is the one still backing the account. Idempotent.
   */
  async revoke(
    platform: Platform,
    purchaseToken: string,
    reason: 'REFUNDED' | 'REVOKED' | 'EXPIRED',
    detail?: string,
  ): Promise<{ handled: boolean; status: string }> {
    const purchase = await this.prisma.purchase.findUnique({
      where: { platform_purchaseToken: { platform, purchaseToken } },
    });
    if (!purchase) return { handled: false, status: 'unknown_token' };
    if (purchase.state !== 'GRANTED' && purchase.state !== 'PENDING') {
      return { handled: true, status: `already_${purchase.state.toLowerCase()}` };
    }

    if (purchase.coinAmount > 0) {
      const wallet = await this.wallet.getBalance(purchase.userId);
      const clawback = Math.min(wallet.balance, purchase.coinAmount);
      if (clawback > 0) {
        await this.wallet.debit(purchase.userId, clawback, {
          type: 'PURCHASE',
          idempotencyKey: this.walletKey('iap_refund', platform, purchaseToken),
          memo: `Refund ${purchase.productKey}`,
        });
      }
    }

    if (purchase.entitlementExpiresAt) {
      await this.prisma.$transaction(async (tx) => {
        const rows = await tx.$queryRaw<
          Array<{ royalPassExpiresAt: Date | null }>
        >`SELECT royalPassExpiresAt FROM User WHERE id = ${purchase.userId} FOR UPDATE`;
        const current = rows[0]?.royalPassExpiresAt ?? null;
        if (
          current &&
          current.getTime() === purchase.entitlementExpiresAt?.getTime()
        ) {
          await tx.user.update({
            where: { id: purchase.userId },
            data: { royalPassExpiresAt: purchase.entitlementPreviousExpiresAt },
          });
        }
      });
    }

    await this.prisma.purchase.update({
      where: { id: purchase.id },
      data: {
        state: reason,
        revokedAt: new Date(),
        revocationReason: detail ?? reason,
      },
    });
    return { handled: true, status: 'revoked' };
  }

  // --- Real-time developer notifications (refunds/revocations) ---------------

  /**
   * Google Play RTDN push (Pub/Sub). Verifies the push identity in
   * production (fail-closed when unconfigured) and applies the
   * purchase-state changes: refunds/revokes roll back grants,
   * renewals extend the Royal Pass, recoveries re-verify + re-grant.
   */
  async handleRtdn(authorization: string | undefined, body: unknown) {
    if (!this.cfg.iap.devStore) {
      if (!this.cfg.iap.rtdnAudience) {
        throw new ServiceUnavailableException(
          'RTDN endpoint is not configured (GOOGLE_PUBSUB_AUDIENCE missing)',
        );
      }
      await this.assertGooglePush(authorization, this.cfg.iap.rtdnAudience);
    }
    const payload = this.decodeRtdn(body);
    if (payload.testNotification) return { handled: 'test' };

    const actions: Array<Record<string, unknown>> = [];
    const sub = payload.subscriptionNotification;
    const oneTime = payload.oneTimeProductNotification;

    if (sub) {
      const token = String(sub.purchaseToken ?? '');
      const type = Number(sub.notificationType ?? -1);
      if (!token) throw new BadRequestException('notification missing purchaseToken');
      if (type === SUB_CANCELED) {
        // Cancelled, not yet expired: access runs to the paid-through
        // date, so nothing changes until EXPIRED arrives.
        actions.push({ token, action: 'cancel_acknowledged' });
      } else if (type === SUB_RENEWED) {
        actions.push({ token, action: (await this.renewPass(token)) ?? 'noop' });
      } else if (type === SUB_EXPIRED) {
        actions.push({ token, ...(await this.revoke('GOOGLE_PLAY', token, 'EXPIRED', 'rtdn_expired')) });
      } else if (type === SUB_REVOKED) {
        actions.push({ token, ...(await this.revoke('GOOGLE_PLAY', token, 'REVOKED', 'rtdn_revoked')) });
      } else if (
        type === SUB_RECOVERED ||
        type === SUB_PURCHASED ||
        type === SUB_RESTARTED
      ) {
        actions.push({ token, action: await this.recover(token, sub.subscriptionId) });
      } else {
        actions.push({ token, action: 'ignored', notificationType: type });
      }
    }

    if (oneTime) {
      const token = String(oneTime.purchaseToken ?? '');
      const type = Number(oneTime.notificationType ?? -1);
      if (!token) throw new BadRequestException('notification missing purchaseToken');
      if (type === ONETIME_CANCELED) {
        actions.push({ token, ...(await this.revoke('GOOGLE_PLAY', token, 'REFUNDED', 'rtdn_refunded')) });
      } else if (type === ONETIME_PURCHASED) {
        actions.push({ token, action: await this.recover(token, oneTime.productId) });
      } else {
        actions.push({ token, action: 'ignored', notificationType: type });
      }
    }

    return { handled: true, actions };
  }

  /** Re-verify a revoked/canceled purchase the store now calls good. */
  private async recover(token: string, _hint?: string): Promise<string> {
    const purchase = await this.prisma.purchase.findUnique({
      where: { platform_purchaseToken: { platform: 'GOOGLE_PLAY', purchaseToken: token } },
    });
    if (!purchase) return 'unknown_token';
    if (purchase.state === 'GRANTED') return 'noop';
    const product = findProduct(purchase.productKey);
    if (!product) return 'unknown_product';
    const verifier = this.registry.get('GOOGLE_PLAY');
    try {
      const verification = await verifier.verify(product, token, {
        userId: purchase.userId,
      });
      if (verification.state !== 'PURCHASED') return 'store_still_not_purchased';
      if (product.kind === 'COINS') {
        await this.wallet.credit(purchase.userId, product.coins, {
          type: 'PURCHASE',
          idempotencyKey: this.walletKey('iap_recover', 'GOOGLE_PLAY', token),
          memo: `IAP recovery ${product.productKey}`,
        });
      } else {
        await this.grantPass(
          purchase.userId,
          'GOOGLE_PLAY',
          product,
          token,
          verification,
          await this.passDaysFor(product),
        );
      }
      await this.prisma.purchase.update({
        where: { id: purchase.id },
        data: { state: 'GRANTED', revokedAt: null, revocationReason: null },
      });
      return 'recovered';
    } catch {
      return 'verification_failed';
    }
  }

  /** Renewal: extend the Royal Pass by another passDays window. */
  private async renewPass(token: string): Promise<string | null> {
    const purchase = await this.prisma.purchase.findUnique({
      where: { platform_purchaseToken: { platform: 'GOOGLE_PLAY', purchaseToken: token } },
    });
    if (!purchase) return null;
    if (purchase.state !== 'GRANTED' || purchase.passDays <= 0) return 'noop';
    const now = new Date();
    await this.prisma.$transaction(async (tx) => {
      const rows = await tx.$queryRaw<
        Array<{ royalPassExpiresAt: Date | null }>
      >`SELECT royalPassExpiresAt FROM User WHERE id = ${purchase.userId} FOR UPDATE`;
      const current = rows[0]?.royalPassExpiresAt ?? null;
      const base = current && current.getTime() > now.getTime() ? current : now;
      const next = new Date(base.getTime() + purchase.passDays * DAY_MS);
      await tx.user.update({
        where: { id: purchase.userId },
        data: { royalPassExpiresAt: next },
      });
      await tx.purchase.update({
        where: { id: purchase.id },
        data: {
          entitlementPreviousExpiresAt: current,
          entitlementExpiresAt: next,
        },
      });
    });
    return 'renewed';
  }

  private decodeRtdn(body: unknown): {
    testNotification?: unknown;
    subscriptionNotification?: { notificationType?: number; purchaseToken?: string; subscriptionId?: string };
    oneTimeProductNotification?: { notificationType?: number; purchaseToken?: string; productId?: string };
  } {
    const envelope = body as { message?: { data?: string } };
    const data = envelope?.message?.data;
    if (typeof data !== 'string' || data.length === 0) {
      throw new BadRequestException('RTDN push missing message.data');
    }
    try {
      return JSON.parse(Buffer.from(data, 'base64').toString('utf8'));
    } catch {
      throw new BadRequestException('RTDN message.data is not valid JSON');
    }
  }

  /**
   * Verifies the Pub/Sub push JWT (RS256 against Google's certs,
   * audience claim checked). Fail-closed: any doubt rejects the push.
   */
  private async assertGooglePush(authorization: string | undefined, audience: string) {
    if (!authorization?.startsWith('Bearer ')) {
      throw new ServiceUnavailableException('RTDN push is not authenticated');
    }
    const token = authorization.slice('Bearer '.length);
    const parts = token.split('.');
    if (parts.length !== 3) throw new ServiceUnavailableException('RTDN push is not authenticated');
    const [headerB64, payloadB64, sigB64] = parts;
    try {
      const header = JSON.parse(Buffer.from(headerB64, 'base64url').toString('utf8'));
      if (header.alg !== 'RS256') throw new Error('alg');
      const claims = JSON.parse(Buffer.from(payloadB64, 'base64url').toString('utf8'));
      if (claims.aud !== audience) throw new Error('aud');
      if (Number(claims.exp ?? 0) * 1000 < Date.now()) throw new Error('exp');
      const certs = await this.googleCerts();
      const key = certs[String(header.kid ?? '')];
      if (!key) throw new Error('kid');
      const { createVerify } = await import('node:crypto');
      const verify = createVerify('RSA-SHA256');
      verify.update(`${headerB64}.${payloadB64}`);
      const ok = verify.verify(
        key,
        Buffer.from(sigB64.replace(/-/g, '+').replace(/_/g, '/'), 'base64'),
      );
      if (!ok) throw new Error('signature');
    } catch {
      throw new ServiceUnavailableException('RTDN push failed verification');
    }
  }

  private certsCache?: { keys: Record<string, string>; fetchedAt: number };

  private async googleCerts(): Promise<Record<string, string>> {
    if (this.certsCache && Date.now() - this.certsCache.fetchedAt < 86_400_000) {
      return this.certsCache.keys;
    }
    const res = await fetch('https://www.googleapis.com/oauth2/v1/certs');
    if (!res.ok) throw new ServiceUnavailableException('Could not fetch Google certs');
    const keys = (await res.json()) as Record<string, string>;
    this.certsCache = { keys, fetchedAt: Date.now() };
    return keys;
  }

  // --- Dev store simulator (never reachable in production) --------------------

  /** Mints a store token exactly as Play would after a purchase. */
  async devIssue(userId: string, productId: string) {
    this.assertDevStore();
    const product = this.resolveProduct(productId);
    await this.assertAvailable(product);
    const token = `dst_${createHash('sha256')
      .update(`${userId}:${productId}:${Date.now()}:${Math.random()}`)
      .digest('hex')}`;
    const row = await this.prisma.devStorePurchase.create({
      data: {
        purchaseToken: token,
        orderId: `dev.order.${token.slice(-12)}`,
        productKey: product.productKey,
        userId,
        state: 'PURCHASED',
      },
    });
    return {
      productId: row.productKey,
      purchaseToken: row.purchaseToken,
      orderId: row.orderId,
      state: row.state,
    };
  }

  /** Simulates store-side state changes (refund, pending, …). */
  async devSetState(purchaseToken: string, state: string) {
    this.assertDevStore();
    if (!['PENDING', 'PURCHASED', 'CANCELED'].includes(state)) {
      throw new BadRequestException('state must be PENDING, PURCHASED or CANCELED');
    }
    const row = await this.prisma.devStorePurchase.findUnique({
      where: { purchaseToken },
    });
    if (!row) throw new NotFoundException('Unknown dev store token');
    await this.prisma.devStorePurchase.update({
      where: { purchaseToken },
      data: { state: state as 'PENDING' | 'PURCHASED' | 'CANCELED' },
    });
    return { purchaseToken: row.purchaseToken, state };
  }

  /** Everything the dev store thinks this account owns (for restore). */
  async devOwned(userId: string) {
    this.assertDevStore();
    const rows = await this.prisma.devStorePurchase.findMany({
      where: { userId },
      orderBy: { issuedAt: 'desc' },
    });
    return {
      items: rows.map((row) => ({
        productId: row.productKey,
        purchaseToken: row.purchaseToken,
        state: row.state,
      })),
    };
  }

  // --- Helpers ----------------------------------------------------------------


  private normalizePlatform(platform?: string): Platform {
    const value = platform ?? 'GOOGLE_PLAY';
    if (!(PLATFORMS as readonly string[]).includes(value)) {
      throw new BadRequestException(`Unknown store platform '${value}'`);
    }
    return value as Platform;
  }

  private resolveProduct(productId: string): ShopProduct {
    const product = findProduct(productId);
    if (!product) throw new NotFoundException('Unknown product');
    return product;
  }

  /** Live Royal Pass duration — static defaults for coin products. */
  private async passDaysFor(product: ShopProduct): Promise<number> {
    if (product.productKey !== ROYAL_PASS_PRODUCT_KEY) return product.passDays;
    return this.systemConfig.number('shop.royal_pass_days');
  }

  /** Admin-disabled products can be neither bought, issued nor restored. */
  private async assertAvailable(product: ShopProduct): Promise<void> {
    if (product.productKey !== ROYAL_PASS_PRODUCT_KEY) return;
    if (!(await this.systemConfig.boolean('shop.royal_pass_enabled'))) {
      throw new BadRequestException('Royal Pass is currently unavailable');
    }
  }

  private walletKey(prefix: string, platform: string, token: string): string {
    const digest = createHash('sha256').update(token).digest('hex');
    return `${prefix}:${platform}:${digest}`;
  }

  private isUniqueViolation(error: unknown): boolean {
    return (
      error instanceof Prisma.PrismaClientKnownRequestError &&
      error.code === 'P2002'
    );
  }

  private summary(row: {
    id: string;
    productKey: string;
    state: string;
    orderId: string | null;
    grantedAt: Date | null;
  }) {
    return {
      id: row.id,
      productKey: row.productKey,
      state: row.state,
      orderId: row.orderId,
      grantedAt: row.grantedAt ? row.grantedAt.toISOString() : null,
    };
  }

  private async envelope(
    userId: string,
    status: SubmitResult['status'],
    purchase: Parameters<ShopService['summary']>[0],
    knownBalance?: number,
  ): Promise<SubmitResult> {
    const balance =
      knownBalance ?? (await this.wallet.getBalance(userId)).balance;
    return {
      status,
      purchase: this.summary(purchase),
      coinsBalance: balance,
      royalPass: await this.royalPassStatus(userId),
    };
  }

  private assertDevStore(): void {
    if (!this.cfg.iap.devStore) {
      throw new ServiceUnavailableException('Dev store simulator is disabled');
    }
  }
}
