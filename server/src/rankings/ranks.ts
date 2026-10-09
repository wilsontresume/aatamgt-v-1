/**
 * Competitive ranking vocabulary (Phase 14): the three rated games,
 * the six rank tiers, and the Elo calculation shared by every rating
 * write. Pure data + pure functions — the client mirrors these bands
 * for offline display, the server owns them for computation.
 */

export const START_RATING = 1000;
/** K-factor for per-game seasonal ratings (same math as the legacy profile Elo). */
export const RATING_K = 16;

export const RATED_GAME_KEYS = [
  'aadu-puli-aattam',
  'solah-seedi',
  'nine-mens-morris',
] as const;

export type RatedGameKey = (typeof RATED_GAME_KEYS)[number];

export function isRatedGame(gameKey: string): gameKey is RatedGameKey {
  return (RATED_GAME_KEYS as readonly string[]).includes(gameKey);
}

export interface RankTier {
  key: string;
  name: string;
  /** Inclusive lower bound of the tier. */
  min: number;
}

/** Bronze → Master. Everyone starts at 1000 (Bronze). */
export const RANK_TIERS: readonly RankTier[] = [
  { key: 'bronze', name: 'Bronze', min: 0 },
  { key: 'silver', name: 'Silver', min: 1100 },
  { key: 'gold', name: 'Gold', min: 1300 },
  { key: 'platinum', name: 'Platinum', min: 1500 },
  { key: 'diamond', name: 'Diamond', min: 1700 },
  { key: 'master', name: 'Master', min: 1900 },
];

export function rankForRating(rating: number): RankTier & { index: number } {
  let index = 0;
  for (let i = 0; i < RANK_TIERS.length; i += 1) {
    if (rating >= RANK_TIERS[i].min) index = i;
  }
  const tier = RANK_TIERS[index];
  return { ...tier, index };
}

/**
 * Elo delta for a two-player result: score is 1 (win), 0 (loss) or
 * 0.5 (draw); expected is computed from the two ratings.
 */
export function eloDelta(rating: number, opponentRating: number, score: number): number {
  const expected = 1 / (1 + Math.pow(10, (opponentRating - rating) / 400));
  return Math.round(RATING_K * (score - expected));
}
