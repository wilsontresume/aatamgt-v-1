/**
 * Shop catalog — the single source of truth for sellable products.
 *
 * Product keys are the *platform* product IDs (Google Play Billing /
 * App Store Connect configure the same IDs and own the prices). This
 * catalog deliberately contains NO prices: in production the store
 * client (Play Billing / StoreKit) is the only price source, so a
 * price change in the console is picked up without shipping an app.
 * Pure data with no I/O, shared by the service, the seed and specs.
 */
export type ProductKind = 'COINS' | 'ROYAL_PASS';

export interface ShopProduct {
  /** Platform product ID as registered in Play Console / App Store. */
  productKey: string;
  kind: ProductKind;
  /** Coin packs: coins granted. Royal Pass: 0. */
  coins: number;
  /** Royal Pass: entitlement days. Coin packs: 0. */
  passDays: number;
  /** Display title (store copy, not pricing). */
  title: string;
  sortOrder: number;
}

export const ROYAL_PASS_PRODUCT_KEY = 'com.aatamgt.royal_pass';

export const CATALOG: readonly ShopProduct[] = [
  {
    productKey: 'com.aatamgt.coins_100',
    kind: 'COINS',
    coins: 100,
    passDays: 0,
    title: '100 Coins',
    sortOrder: 0,
  },
  {
    productKey: 'com.aatamgt.coins_1000',
    kind: 'COINS',
    coins: 1000,
    passDays: 0,
    title: '1000 Coins',
    sortOrder: 10,
  },
  {
    productKey: 'com.aatamgt.coins_5500',
    kind: 'COINS',
    coins: 5500,
    passDays: 0,
    title: '5500 Coins',
    sortOrder: 20,
  },
  {
    productKey: 'com.aatamgt.coins_12000',
    kind: 'COINS',
    coins: 12000,
    passDays: 0,
    title: '12000 Coins',
    sortOrder: 30,
  },
  {
    productKey: 'com.aatamgt.coins_65000',
    kind: 'COINS',
    coins: 65000,
    passDays: 0,
    title: '65000 Coins',
    sortOrder: 40,
  },
  {
    productKey: 'com.aatamgt.coins_150000',
    kind: 'COINS',
    coins: 150000,
    passDays: 0,
    title: '150000 Coins',
    sortOrder: 50,
  },
  {
    productKey: ROYAL_PASS_PRODUCT_KEY,
    kind: 'ROYAL_PASS',
    coins: 0,
    passDays: 30,
    title: 'Royal Pass (30 days)',
    sortOrder: 60,
  },
];

export function findProduct(productKey: string): ShopProduct | undefined {
  return CATALOG.find((p) => p.productKey === productKey);
}
