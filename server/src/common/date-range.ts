import { BadRequestException } from '@nestjs/common';

export const DAY_MS = 86_400_000;
export const DEFAULT_RANGE_DAYS = 14;
export const MAX_RANGE_DAYS = 366;

export interface DateRange {
  from: string;
  to: string;
  start: Date;
  endExclusive: Date;
}

export function utcToday(): string {
  return new Date().toISOString().slice(0, 10);
}

export function parseDay(value: string, field: string): Date {
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new BadRequestException(`\`${field}\` must be a valid YYYY-MM-DD date`);
  }
  return parsed;
}

export function shiftDays(day: string, deltaDays: number): string {
  const parsed = parseDay(day, 'day');
  return new Date(parsed.getTime() + deltaDays * DAY_MS).toISOString().slice(0, 10);
}

/** Iterates every UTC day of [from, to] inclusive. */
export function eachDay(from: string, to: string): string[] {
  const days: string[] = [];
  let cursor = parseDay(from, 'from');
  const end = parseDay(to, 'to');
  while (cursor.getTime() <= end.getTime()) {
    days.push(cursor.toISOString().slice(0, 10));
    cursor = new Date(cursor.getTime() + DAY_MS);
  }
  return days;
}

/**
 * Resolves an optional `{from, to}` day filter into a half-open UTC range
 * `[start, endExclusive)`, defaulting to the last `defaultDays` days and
 * validating order plus the maximum span. One source of truth for every
 * date-filtered admin surface (dashboard, economy).
 */
export function resolveRange(
  query: { from?: string; to?: string },
  defaultDays = DEFAULT_RANGE_DAYS,
): DateRange {
  const to = query.to ?? utcToday();
  const from = query.from ?? shiftDays(to, -(defaultDays - 1));
  const fromDate = parseDay(from, 'from');
  const toDate = parseDay(to, 'to');
  if (fromDate.getTime() > toDate.getTime()) {
    throw new BadRequestException('`from` must be on or before `to`');
  }
  if (toDate.getTime() - fromDate.getTime() > (MAX_RANGE_DAYS - 1) * DAY_MS) {
    throw new BadRequestException(`Date range cannot exceed ${MAX_RANGE_DAYS} days`);
  }
  return {
    from,
    to,
    start: fromDate,
    endExclusive: new Date(toDate.getTime() + DAY_MS),
  };
}
