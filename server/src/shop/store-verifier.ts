import {
  Injectable,
  Logger,
  ServiceUnavailableException,
  UnprocessableEntityException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createSign } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { AppConfig } from '../config/configuration';
import { PrismaService } from '../prisma/prisma.service';
import { ShopProduct } from './catalog';

/**
 * Phase 13 — store provider abstraction.
 *
 * The backend never grants anything from a client-side "purchase
 * succeeded" callback: every grant goes through a PurchaseVerifier
 * that asks the store itself. Google Play is wired first; Apple
 * StoreKit plugs in by registering a verifier for APPLE_APP_STORE.
 */
export type StorePurchaseState = 'PURCHASED' | 'PENDING' | 'CANCELED';

export interface StoreVerification {
  state: StorePurchaseState;
  orderId: string;
  purchaseTimeMs?: number;
  /** Store-reported purchaser, when the store provides it. */
  ownerAccountId?: string;
  raw: Record<string, unknown>;
}

export interface PurchaseVerifier {
  readonly platform: string;
  /**
   * Throws UnprocessableEntityException when the token is not real.
   * `opts.userId`, when present, asks the verifier to confirm the
   * token belongs to that account (ownership check).
   */
  verify(
    product: ShopProduct,
    purchaseToken: string,
    opts?: { userId?: string },
  ): Promise<StoreVerification>;
}

const ANDROIDPUBLISHER_SCOPE = 'https://www.googleapis.com/auth/androidpublisher';

/**
 * Real Google Play verification against the Play Developer API
 * (androidpublisher v3). Uses a service account with access to the
 * app's purchases; product purchases use purchases.products.get and
 * subscriptions use purchases.subscriptionsv2.get.
 */
@Injectable()
export class GooglePlayVerifier implements PurchaseVerifier {
  readonly platform = 'GOOGLE_PLAY';
  private readonly logger = new Logger(GooglePlayVerifier.name);
  private cachedToken?: { token: string; expiresAt: number };

  constructor(private readonly config: ConfigService) {}

  private get cfg(): AppConfig {
    return this.config.get<AppConfig>('app') as AppConfig;
  }

  async verify(
    product: ShopProduct,
    purchaseToken: string,
    opts?: { userId?: string },
  ): Promise<StoreVerification> {
    const { serviceAccount, packageName } = this.cfg.iap;
    if (!serviceAccount) {
      throw new ServiceUnavailableException(
        'Purchase verification is unavailable: Google Play service account not configured',
      );
    }
    const base =
      'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/' +
      encodeURIComponent(packageName);
    const url =
      product.kind === 'ROYAL_PASS'
        ? `${base}/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`
        : `${base}/purchases/products/${encodeURIComponent(product.productKey)}/tokens/${encodeURIComponent(purchaseToken)}`;

    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${await this.accessToken()}` },
    });
    if (res.status === 404) {
      throw new UnprocessableEntityException('Play did not recognise this purchase token');
    }
    if (!res.ok) {
      this.logger.warn(`Play Developer API ${res.status} for ${product.productKey}`);
      throw new ServiceUnavailableException('Google Play verification failed to respond');
    }
    const body = (await res.json()) as Record<string, unknown>;

    if (product.kind === 'ROYAL_PASS') {
      const subscriptionId = String(body.subscriptionId ?? '');
      if (subscriptionId && subscriptionId !== product.productKey) {
        throw new UnprocessableEntityException('Purchase token belongs to another product');
      }
      const verification: StoreVerification = {
        state: this.mapSubscriptionState(String(body.subscriptionState ?? '')),
        orderId: String(body.orderId ?? ''),
        ownerAccountId:
          typeof body.obfuscatedAccountId === 'string' ? body.obfuscatedAccountId : undefined,
        raw: body,
      };
      this.assertOwner(verification, opts);
      return verification;
    }

    const productId = String(body.productId ?? '');
    if (productId && productId !== product.productKey) {
      throw new UnprocessableEntityException('Purchase token belongs to another product');
    }
    const purchaseState = Number(body.purchaseState ?? -1);
    const verification: StoreVerification = {
      state: purchaseState === 0 ? 'PURCHASED' : purchaseState === 2 ? 'PENDING' : 'CANCELED',
      orderId: String(body.orderId ?? ''),
      purchaseTimeMs: Number(body.purchaseTime ?? 0) || undefined,
      ownerAccountId:
        typeof body.obfuscatedAccountId === 'string' ? body.obfuscatedAccountId : undefined,
      raw: body,
    };
    this.assertOwner(verification, opts);
    return verification;
  }

  /** Best-effort ownership check when Play echoes the account id we set. */
  private assertOwner(
    verification: StoreVerification,
    opts?: { userId?: string },
  ): void {
    if (
      opts?.userId &&
      verification.ownerAccountId &&
      verification.ownerAccountId !== opts.userId
    ) {
      throw new UnprocessableEntityException('Purchase token belongs to another user');
    }
  }

  private mapSubscriptionState(state: string): StorePurchaseState {
    switch (state) {
      case 'SUBSCRIPTION_STATE_ACTIVE':
      case 'SUBSCRIPTION_STATE_PAUSED':
        return 'PURCHASED';
      case 'SUBSCRIPTION_STATE_PENDING':
      case 'SUBSCRIPTION_STATE_DEFERRED':
        return 'PENDING';
      default:
        return 'CANCELED';
    }
  }

  private async accessToken(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    if (this.cachedToken && this.cachedToken.expiresAt > now + 60) {
      return this.cachedToken.token;
    }
    const key = this.loadServiceAccount();
    const issued = Math.floor(Date.now() / 1000);
    const claim = {
      iss: key.client_email,
      scope: ANDROIDPUBLISHER_SCOPE,
      aud: 'https://oauth2.googleapis.com/token',
      iat: issued,
      exp: issued + 3600,
    };
    const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
    const payload = Buffer.from(JSON.stringify(claim)).toString('base64url');
    const signer = createSign('RSA-SHA256');
    signer.update(`${header}.${payload}`);
    const assertion = `${header}.${payload}.${signer.sign(key.private_key, 'base64url')}`;

    const res = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion,
      }),
    });
    if (!res.ok) {
      throw new ServiceUnavailableException('Could not authenticate to the Google Play API');
    }
    const tokens = (await res.json()) as { access_token: string; expires_in: number };
    this.cachedToken = {
      token: tokens.access_token,
      expiresAt: issued + Number(tokens.expires_in ?? 3600),
    };
    return tokens.access_token;
  }

  private loadServiceAccount(): { client_email: string; private_key: string } {
    const raw = this.cfg.iap.serviceAccount;
    const text = existsSync(raw) ? readFileSync(raw, 'utf8') : raw;
    try {
      return JSON.parse(text) as { client_email: string; private_key: string };
    } catch {
      throw new ServiceUnavailableException('GOOGLE_PLAY_SERVICE_ACCOUNT is not valid JSON');
    }
  }
}

/**
 * Development store simulator. Tokens are rows in DevStorePurchase,
 * minted by the dev issue endpoint — exactly as Google Play would
 * mint them after a completed store transaction. The verification
 * here IS the server-side check: unknown tokens, product mismatches
 * and tokens owned by another user are all rejected. Forced out of
 * production by config (iap.devStore is always false there).
 */
@Injectable()
export class DevStoreVerifier implements PurchaseVerifier {
  readonly platform = 'GOOGLE_PLAY';

  constructor(private readonly prisma: PrismaService) {}

  async verify(
    product: ShopProduct,
    purchaseToken: string,
    opts?: { userId?: string },
  ): Promise<StoreVerification> {
    const row = await this.prisma.devStorePurchase.findUnique({
      where: { purchaseToken },
    });
    if (!row) {
      throw new UnprocessableEntityException('Purchase token was not issued by the store');
    }
    if (row.productKey !== product.productKey) {
      throw new UnprocessableEntityException('Purchase token belongs to another product');
    }
    if (opts?.userId !== undefined && row.userId !== opts.userId) {
      throw new UnprocessableEntityException('Purchase token belongs to another user');
    }
    return {
      state:
        row.state === 'PURCHASED' ? 'PURCHASED' : row.state === 'PENDING' ? 'PENDING' : 'CANCELED',
      orderId: row.orderId,
      purchaseTimeMs: row.issuedAt.getTime(),
      raw: { orderId: row.orderId, state: row.state, source: 'dev-store' },
    };
  }
}

/** Placeholder for platforms declared but not yet wired up. */
export class UnimplementedStoreVerifier implements PurchaseVerifier {
  constructor(readonly platform: string) {}

  verify(): Promise<StoreVerification> {
    return Promise.reject(
      new ServiceUnavailableException(
        `Store provider '${this.platform}' has no purchase verifier yet — implement PurchaseVerifier and register it`,
      ),
    );
  }
}

/** Maps a platform to its verifier (the StoreKit/Play seam). */
@Injectable()
export class StoreVerifierRegistry {
  private readonly verifiers = new Map<string, PurchaseVerifier>();
  private readonly logger = new Logger(StoreVerifierRegistry.name);

  constructor(config: ConfigService, prisma: PrismaService) {
    const iap = (config.get<AppConfig>('app') as AppConfig).iap;
    if (iap.devStore) {
      // Dev/test: the simulator stands in for Google Play itself.
      this.logger.warn('IAP dev store simulator enabled — NOT for production');
      this.register(new DevStoreVerifier(prisma));
    } else {
      this.register(new GooglePlayVerifier(config));
    }
    this.register(new UnimplementedStoreVerifier('APPLE_APP_STORE'));
  }

  register(verifier: PurchaseVerifier): void {
    this.verifiers.set(verifier.platform, verifier);
  }

  get(platform: string): PurchaseVerifier {
    const found = this.verifiers.get(platform);
    if (!found) {
      throw new ServiceUnavailableException(`No verifier for store platform '${platform}'`);
    }
    return found;
  }
}
