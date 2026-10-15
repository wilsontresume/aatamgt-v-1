import { Module } from '@nestjs/common';
import { PrismaModule } from '../prisma/prisma.module';
import { AdminModule } from '../admin/admin.module';
import { TiersService } from './tiers.service';
import { TiersAdminController } from './tiers-admin.controller';

@Module({
  imports: [PrismaModule, AdminModule],
  controllers: [TiersAdminController],
  providers: [TiersService],
  exports: [TiersService],
})
export class TiersModule {}
