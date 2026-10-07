import { Injectable, ServiceUnavailableException, UnprocessableEntityException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { AppConfig } from '../config/configuration';

/**
 * Phase 8 provider abstraction.
 *
 * The backend never trusts a client-side "ad completed" callback: coins
 * are only granted after the reward has been verified through this
 * interface. The stub verifier validates the server-issued session;
 * real providers plug in by implementing `verify` with a server-to-
 * server call to the provider's reward-validation API and registering
 * themselves in `AdVerifierRegistry`.
 */
export interface AdRewardVerificationContext {
  provider: string;
  tier: string;
  sessionId: string;
  userId: string;
  /** Untrusted client callback payload — forwarded, never assumed true. */
  payload?: Record<string, unknown>;
}

export interface AdRewardVerifier {
  readonly name: string;
  verify(ctx: AdRewardVerificationContext): Promise<void>;
}

/**
 * Built-in verifier for the `stub` provider (no external SDK). The
 * verification here IS the server-side session: it was minted by this
 * backend, is unexpired and unclaimed. A real provider instead
 * validates the provider's reward callback server-to-server.
 */
@Injectable()
export class StubAdVerifier implements AdRewardVerifier {
  readonly name = 'stub';

  async verify(ctx: AdRewardVerificationContext): Promise<void> {
    if (ctx.provider !== this.name) {
      throw new UnprocessableEntityException(
        `Session provider '${ctx.provider}' cannot be verified by '${this.name}'`,
      );
    }
    // A real implementation would now call the ad network's reward
    // verification endpoint with ctx.payload and reject on failure.
    return Promise.resolve();
  }
}

/** Placeholder for providers declared in config but not yet wired up. */
export class UnimplementedAdVerifier implements AdRewardVerifier {
  constructor(readonly name: string) {}

  verify(): Promise<void> {
    return Promise.reject(
      new ServiceUnavailableException(
        `Ad provider '${this.name}' has no reward verifier yet — implement AdRewardVerifier and register it`,
      ),
    );
  }
}

/** Maps the configured provider name to its verifier (abstraction seam). */
@Injectable()
export class AdVerifierRegistry {
  private readonly verifiers = new Map<string, AdRewardVerifier>();

  constructor(stub: StubAdVerifier, config: ConfigService) {
    this.register(stub);
    this.provider = (config.get<AppConfig>('app') as AppConfig).ads.provider;
  }

  provider: string;

  register(verifier: AdRewardVerifier): void {
    this.verifiers.set(verifier.name, verifier);
  }

  get(provider: string): AdRewardVerifier {
    return this.verifiers.get(provider) ?? new UnimplementedAdVerifier(provider);
  }

  active(): AdRewardVerifier {
    return this.get(this.provider);
  }
}
