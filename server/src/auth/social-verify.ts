import { ForbiddenException, UnauthorizedException } from '@nestjs/common';
import { AppConfig } from '../config/configuration';

export type SocialProvider = 'google' | 'facebook';

export interface SocialIdentity {
  provider: SocialProvider;
  /** Stable provider-side user id (Google `sub`, Facebook user id). */
  subject: string;
  email: string | null;
  name: string | null;
  emailVerified: boolean;
}

/**
 * Server-side verification of social sign-in tokens.
 *
 * The client only ever hands us an opaque provider token; the identity
 * (subject/email) always comes from the provider itself, so a client can
 * never claim someone else's social account. Providers are optional: when
 * the corresponding env vars are unset the provider answers "not
 * configured" and no token is ever accepted.
 */
export class SocialVerifier {
  constructor(private readonly cfg: AppConfig) {}

  isConfigured(provider: SocialProvider): boolean {
    const oauth = this.cfg.oauth;
    if (!oauth) return false;
    if (provider === 'google') return Boolean(oauth.googleClientId);
    return Boolean(oauth.facebookAppId && oauth.facebookAppSecret);
  }

  async verify(provider: SocialProvider, token: string): Promise<SocialIdentity> {
    if (provider === 'google') return this.verifyGoogle(token);
    return this.verifyFacebook(token);
  }

  /**
   * Google ID tokens are verified by Google itself: tokeninfo rejects
   * forged signatures and returns the audience we must match against our
   * own client id.
   */
  private async verifyGoogle(token: string): Promise<SocialIdentity> {
    const clientId = this.cfg.oauth?.googleClientId;
    if (!clientId) throw new ForbiddenException('Google sign-in is not configured');

    const res = await fetch(
      `https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(token)}`,
    ).catch(() => null);
    if (!res || !res.ok) throw new UnauthorizedException('Google token is not valid');

    const info = (await res.json().catch(() => null)) as {
      aud?: string;
      sub?: string;
      email?: string;
      email_verified?: string;
      name?: string;
    } | null;
    if (!info || info.aud !== clientId || !info.sub) {
      throw new UnauthorizedException('Google token is not valid');
    }

    return {
      provider: 'google',
      subject: info.sub,
      email: info.email?.toLowerCase() ?? null,
      name: info.name ?? null,
      emailVerified: info.email_verified === 'true',
    };
  }

  /**
   * Facebook tokens are checked against the app token (app_id|secret) via
   * debug_token, then the identity is read from /me with the user token.
   */
  private async verifyFacebook(token: string): Promise<SocialIdentity> {
    const appId = this.cfg.oauth?.facebookAppId;
    const appSecret = this.cfg.oauth?.facebookAppSecret;
    if (!appId || !appSecret) throw new ForbiddenException('Facebook sign-in is not configured');

    const appToken = encodeURIComponent(`${appId}|${appSecret}`);
    const debugRes = await fetch(
      `https://graph.facebook.com/debug_token?input_token=${encodeURIComponent(token)}&access_token=${appToken}`,
    ).catch(() => null);
    if (!debugRes || !debugRes.ok) throw new UnauthorizedException('Facebook token is not valid');

    const debug = (await debugRes.json().catch(() => null)) as {
      data?: { is_valid?: boolean; app_id?: string; user_id?: string };
    } | null;
    const data = debug?.data;
    if (!data?.is_valid || data.app_id !== appId || !data.user_id) {
      throw new UnauthorizedException('Facebook token is not valid');
    }

    const meRes = await fetch(
      `https://graph.facebook.com/me?fields=id,name,email&access_token=${encodeURIComponent(token)}`,
    ).catch(() => null);
    if (!meRes || !meRes.ok) throw new UnauthorizedException('Facebook token is not valid');

    const me = (await meRes.json().catch(() => null)) as {
      id?: string;
      name?: string;
      email?: string;
    } | null;
    if (!me || me.id !== data.user_id) {
      throw new UnauthorizedException('Facebook token is not valid');
    }

    return {
      provider: 'facebook',
      subject: data.user_id,
      email: me.email?.toLowerCase() ?? null,
      name: me.name ?? null,
      // Facebook emails are verified by the provider; no flag surfaced.
      emailVerified: Boolean(me.email),
    };
  }
}
