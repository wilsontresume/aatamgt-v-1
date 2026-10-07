import {
  evaluateInterstitial,
  InterstitialConfig,
  InterstitialState,
} from '../../src/ads/ads.service';

const RULES: InterstitialConfig = {
  afterWins: 3,
  afterLosses: 5,
  cooldownMatches: 2,
};

function state(overrides: Partial<InterstitialState> = {}): InterstitialState {
  return {
    royalPassActive: false,
    inProgress: false,
    winsSinceLastShow: 0,
    consecutiveLosses: 0,
    matchesSinceLastShow: 0,
    ...overrides,
  };
}

describe('evaluateInterstitial (Phase 8 pure rules)', () => {
  it('blocks on an active royal pass regardless of any trigger', () => {
    const verdict = evaluateInterstitial(
      state({ royalPassActive: true, winsSinceLastShow: 9, consecutiveLosses: 9, matchesSinceLastShow: 9 }),
      RULES,
    );
    expect(verdict).toEqual({ eligible: false, reason: 'ROYAL_PASS' });
  });

  it('blocks during an in-progress match even when a trigger is met', () => {
    const verdict = evaluateInterstitial(
      state({ inProgress: true, winsSinceLastShow: 3, matchesSinceLastShow: 3 }),
      RULES,
    );
    expect(verdict).toEqual({ eligible: false, reason: 'IN_PROGRESS' });
  });

  it('ranks royal pass above in-progress', () => {
    const verdict = evaluateInterstitial(state({ royalPassActive: true, inProgress: true }), RULES);
    expect(verdict.reason).toBe('ROYAL_PASS');
  });

  it('returns NOT_YET when nothing has happened', () => {
    expect(evaluateInterstitial(state(), RULES)).toEqual({ eligible: false, reason: 'NOT_YET' });
  });

  it('returns NOT_YET below every trigger', () => {
    const verdict = evaluateInterstitial(
      state({ winsSinceLastShow: 2, consecutiveLosses: 4, matchesSinceLastShow: 2 }),
      RULES,
    );
    expect(verdict).toEqual({ eligible: false, reason: 'NOT_YET' });
  });

  it('becomes eligible on the configured win threshold', () => {
    const verdict = evaluateInterstitial(
      state({ winsSinceLastShow: 3, matchesSinceLastShow: 3 }),
      RULES,
    );
    expect(verdict).toEqual({ eligible: true, reason: 'WINS' });
  });

  it('stays blocked one win short of the threshold', () => {
    const verdict = evaluateInterstitial(
      state({ winsSinceLastShow: 2, matchesSinceLastShow: 2 }),
      RULES,
    );
    expect(verdict.eligible).toBe(false);
    expect(verdict.reason).toBe('NOT_YET');
  });

  it('becomes eligible on the configured consecutive-loss threshold', () => {
    const verdict = evaluateInterstitial(
      state({ consecutiveLosses: 5, matchesSinceLastShow: 5 }),
      RULES,
    );
    expect(verdict).toEqual({ eligible: true, reason: 'LOSSES' });
  });

  it('stays blocked one loss short of the threshold', () => {
    const verdict = evaluateInterstitial(
      state({ consecutiveLosses: 4, matchesSinceLastShow: 4 }),
      RULES,
    );
    expect(verdict.eligible).toBe(false);
    expect(verdict.reason).toBe('NOT_YET');
  });

  it('applies the cooldown when a trigger is met too soon after a show', () => {
    const verdict = evaluateInterstitial(
      state({ winsSinceLastShow: 1, matchesSinceLastShow: 1 }),
      { afterWins: 1, afterLosses: 5, cooldownMatches: 2 },
    );
    expect(verdict).toEqual({ eligible: false, reason: 'COOLDOWN' });
  });

  it('opens exactly at the cooldown boundary', () => {
    const verdict = evaluateInterstitial(
      state({ winsSinceLastShow: 2, matchesSinceLastShow: 2 }),
      { afterWins: 2, afterLosses: 5, cooldownMatches: 2 },
    );
    expect(verdict).toEqual({ eligible: true, reason: 'WINS' });
  });

  it('prefers the win reason when both triggers fire', () => {
    const verdict = evaluateInterstitial(
      state({ winsSinceLastShow: 3, consecutiveLosses: 5, matchesSinceLastShow: 6 }),
      RULES,
    );
    expect(verdict).toEqual({ eligible: true, reason: 'WINS' });
  });

  it('is not eligible during cooldown without any trigger', () => {
    const verdict = evaluateInterstitial(state({ matchesSinceLastShow: 1 }), RULES);
    expect(verdict).toEqual({ eligible: false, reason: 'NOT_YET' });
  });
});
