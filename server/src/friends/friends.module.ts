import { Module } from '@nestjs/common';
import { FriendsController } from './friends.controller';
import { FriendsService } from './friends.service';
import { NotificationsModule } from '../notifications/notifications.module';
import { AnalyticsModule } from '../analytics/analytics.module';
import { RealtimeModule } from '../realtime/realtime.module';

@Module({
  imports: [NotificationsModule, AnalyticsModule, RealtimeModule],
  controllers: [FriendsController],
  providers: [FriendsService],
  exports: [FriendsService],
})
export class FriendsModule {}
