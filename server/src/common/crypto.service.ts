import { Injectable } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { createHash } from 'node:crypto';

export const sha256 = (value: string): string => createHash('sha256').update(value).digest('hex');

export const newId = (): string => randomUUID();

@Injectable()
export class CryptoService {
  hashToken(token: string): string {
    return sha256(token);
  }

  newIdempotencyKey(): string {
    return newId();
  }
}
