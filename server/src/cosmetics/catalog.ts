/**
 * Cosmetic catalog — the single source of truth for what exists in the
 * inventory system. Pure data with no I/O so it can be shared by the
 * Prisma seed and by integration specs (the test DB runs migrations only).
 *
 * Client mirrors presentation defaults from these keys, but ownership and
 * equipped state always come from the server.
 */
export type CosmeticCategoryKey =
  | 'BOARD_SKIN'
  | 'PROFILE_PICTURE'
  | 'PROFILE_FRAME'
  | 'VICTORY_ANIMATION'
  | 'CAPTURE_ANIMATION';

export type CosmeticTierKey = 'FREE' | 'PREMIUM';

export interface CosmeticSeed {
  key: string;
  category: CosmeticCategoryKey;
  name: string;
  description: string;
  tier: CosmeticTierKey;
  price: number;
  grantedByDefault: boolean;
  sortOrder: number;
}

export const CATEGORY_ORDER: readonly CosmeticCategoryKey[] = [
  'BOARD_SKIN',
  'PROFILE_PICTURE',
  'PROFILE_FRAME',
  'VICTORY_ANIMATION',
  'CAPTURE_ANIMATION',
];

export const CATALOG: readonly CosmeticSeed[] = [
  // --- Board skins -------------------------------------------------------
  {
    key: 'board_classic',
    category: 'BOARD_SKIN',
    name: 'Classic Board',
    description: 'The familiar tournament surface.',
    tier: 'FREE',
    price: 0,
    grantedByDefault: true,
    sortOrder: 0,
  },
  {
    key: 'board_woodland',
    category: 'BOARD_SKIN',
    name: 'Woodland Board',
    description: 'Warm timber tones for a rustic table.',
    tier: 'FREE',
    price: 0,
    grantedByDefault: false,
    sortOrder: 10,
  },
  {
    key: 'board_midnight',
    category: 'BOARD_SKIN',
    name: 'Midnight Board',
    description: 'Deep indigo surface with silver lines.',
    tier: 'PREMIUM',
    price: 250,
    grantedByDefault: false,
    sortOrder: 20,
  },
  // --- Profile pictures ---------------------------------------------------
  {
    key: 'pfp_default',
    category: 'PROFILE_PICTURE',
    name: 'Classic Avatar',
    description: 'The standard initial badge.',
    tier: 'FREE',
    price: 0,
    grantedByDefault: true,
    sortOrder: 0,
  },
  {
    key: 'pfp_sunset',
    category: 'PROFILE_PICTURE',
    name: 'Sunset Avatar',
    description: 'A warm amber glow behind your initial.',
    tier: 'FREE',
    price: 0,
    grantedByDefault: false,
    sortOrder: 10,
  },
  {
    key: 'pfp_nebula',
    category: 'PROFILE_PICTURE',
    name: 'Nebula Avatar',
    description: 'A swirl of violet and blue.',
    tier: 'PREMIUM',
    price: 200,
    grantedByDefault: false,
    sortOrder: 20,
  },
  // --- Profile frames -----------------------------------------------------
  {
    key: 'frame_none',
    category: 'PROFILE_FRAME',
    name: 'No Frame',
    description: 'Plain and unframed.',
    tier: 'FREE',
    price: 0,
    grantedByDefault: true,
    sortOrder: 0,
  },
  {
    key: 'frame_silver',
    category: 'PROFILE_FRAME',
    name: 'Silver Frame',
    description: 'A polished silver ring.',
    tier: 'FREE',
    price: 0,
    grantedByDefault: false,
    sortOrder: 10,
  },
  {
    key: 'frame_gold',
    category: 'PROFILE_FRAME',
    name: 'Gold Frame',
    description: 'A shining gold ring.',
    tier: 'PREMIUM',
    price: 300,
    grantedByDefault: false,
    sortOrder: 20,
  },
  // --- Victory animations -------------------------------------------------
  {
    key: 'victory_none',
    category: 'VICTORY_ANIMATION',
    name: 'No Victory Effect',
    description: 'Quiet victories.',
    tier: 'FREE',
    price: 0,
    grantedByDefault: true,
    sortOrder: 0,
  },
  {
    key: 'victory_confetti',
    category: 'VICTORY_ANIMATION',
    name: 'Confetti',
    description: 'A burst of colourful paper.',
    tier: 'FREE',
    price: 0,
    grantedByDefault: false,
    sortOrder: 10,
  },
  {
    key: 'victory_fireworks',
    category: 'VICTORY_ANIMATION',
    name: 'Fireworks',
    description: 'Golden sparks over the board.',
    tier: 'PREMIUM',
    price: 350,
    grantedByDefault: false,
    sortOrder: 20,
  },
  // --- Capture animations -------------------------------------------------
  {
    key: 'capture_none',
    category: 'CAPTURE_ANIMATION',
    name: 'No Capture Effect',
    description: 'Captures play out silently.',
    tier: 'FREE',
    price: 0,
    grantedByDefault: true,
    sortOrder: 0,
  },
  {
    key: 'capture_flash',
    category: 'CAPTURE_ANIMATION',
    name: 'Flash',
    description: 'A quick ring of light at the capture point.',
    tier: 'FREE',
    price: 0,
    grantedByDefault: false,
    sortOrder: 10,
  },
  {
    key: 'capture_shockwave',
    category: 'CAPTURE_ANIMATION',
    name: 'Shockwave',
    description: 'A heavy pulse radiating from the board.',
    tier: 'PREMIUM',
    price: 250,
    grantedByDefault: false,
    sortOrder: 20,
  },
];

export const CATALOG_BY_KEY: ReadonlyMap<string, CosmeticSeed> = new Map(
  CATALOG.map((item) => [item.key, item]),
);

/** The one default cosmetic per category (granted + auto-equipped). */
export const DEFAULT_KEY_BY_CATEGORY: ReadonlyMap<CosmeticCategoryKey, string> = new Map(
  CATALOG.filter((item) => item.grantedByDefault).map((item) => [item.category, item.key]),
);

export function catalogItem(key: string): CosmeticSeed | undefined {
  return CATALOG_BY_KEY.get(key);
}
