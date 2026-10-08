import { PrismaClient, Role } from '@prisma/client';
import * as bcrypt from 'bcryptjs';

/**
 * Development-only seed. Refuses to run in production.
 * Creates platform fixtures only: users, profiles, wallets and the game catalog.
 * No matches, no results, no economy events are fabricated.
 */
const GAMES = [
  {
    key: 'aadu-puli-aattam',
    name: 'Aadu Puli Aattam',
    slug: 'aadu-puli-aattam',
    description: 'Asymmetric hunt game for 2 players. Rules ship in a later phase.',
    minPlayers: 2,
    maxPlayers: 2,
  },
  {
    key: 'solah-seedi',
    name: 'Solah Seedi',
    slug: 'solah-seedi',
    description:
      '16 Soldiers — classic war game for 2 players on a 37-point board. Capture every enemy piece or break through their triangle.',
    minPlayers: 2,
    maxPlayers: 2,
  },
  {
    key: 'nine-mens-morris',
    name: "Nine Men's Morris",
    slug: 'nine-mens-morris',
    description:
      "Nine Men's Morris — classic mill game for 2 players on a 24-point board. Place nine pieces, then slide (fly when three remain) and form mills to capture.",
    minPlayers: 2,
    maxPlayers: 2,
  },
];

const DEV_PASSWORD = process.env.SEED_PASSWORD ?? 'Password123!';

export async function seed(prisma: PrismaClient): Promise<void> {
  if (process.env.NODE_ENV === 'production') {
    throw new Error('Refusing to seed a production database');
  }

  for (const game of GAMES) {
    await prisma.game.upsert({
      where: { key: game.key },
      update: { name: game.name, description: game.description },
      create: game,
    });
  }

  const users: { username: string; role: Role; email: string }[] = [
    { username: 'admin', role: 'ADMIN', email: 'admin@aatamgt.local' },
    { username: 'demo', role: 'USER', email: 'demo@aatamgt.local' },
    { username: 'demo2', role: 'USER', email: 'demo2@aatamgt.local' },
  ];

  const passwordHash = await bcrypt.hash(DEV_PASSWORD, 10);

  for (const entry of users) {
    const user = await prisma.user.upsert({
      where: { username: entry.username },
      update: {},
      create: {
        username: entry.username,
        email: entry.email,
        passwordHash,
        role: entry.role,
        emailVerified: true,
        profile: {
          create: {
            displayName: entry.username === 'admin' ? 'Platform Admin' : entry.username,
            isPublic: true,
          },
        },
        wallets: { create: { currency: 'COIN', balance: 1000 } },
      },
      include: { wallets: true },
    });
    if (user.wallets.length === 0) {
      await prisma.wallet.create({ data: { userId: user.id, currency: 'COIN', balance: 1000 } });
    }
  }

  await prisma.leaderboardEntry.deleteMany({ where: { key: 'global' } });
  const profiles = await prisma.profile.findMany({
    where: { isPublic: true },
    select: { userId: true, rating: true },
    take: 100,
  });
  const ranked = profiles.sort((a, b) => b.rating - a.rating || a.userId.localeCompare(b.userId));
  await prisma.leaderboardEntry.createMany({
    data: ranked.map((row, index) => ({
      key: 'global',
      period: 'ALL_TIME' as const,
      userId: row.userId,
      score: row.rating,
      rank: index + 1,
    })),
  });
}

const isDirectRun = require.main === module;
if (isDirectRun) {
  const prisma = new PrismaClient();
  seed(prisma)
    .then(async () => {
      await prisma.$disconnect();
    })
    .catch(async (error) => {
      console.error(error);
      await prisma.$disconnect();
      process.exit(1);
    });
}
