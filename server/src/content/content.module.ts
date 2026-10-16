import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { AdminModule } from '../admin/admin.module';
import { PrismaModule } from '../prisma/prisma.module';
import { AppConfig } from '../config/configuration';
import { StorageService } from './storage/storage.service';
import { AssetsService } from './assets.service';
import { ContentManifestService } from './content-manifest.service';
import { AssetsAdminController } from './assets.admin.controller';
import { ContentAdminController } from './content.admin.controller';
import { ContentPublicController } from './content.public.controller';

@Module({
  imports: [PrismaModule, AdminModule, ConfigModule],
  controllers: [
    AssetsAdminController,
    ContentAdminController,
    ContentPublicController,
  ],
  providers: [
    AssetsService,
    ContentManifestService,
    {
      provide: StorageService,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => {
        const app = config.get<AppConfig>('app') as AppConfig;
        return new StorageService(app.assets);
      },
    },
  ],
  exports: [AssetsService, ContentManifestService, StorageService],
})
export class ContentModule {}
