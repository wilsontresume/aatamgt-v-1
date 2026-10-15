import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { MatchesModule } from '../matches/matches.module';
import { RealtimeGateway } from './realtime.gateway';
import { UserPresenceService } from './user-presence.service';

@Module({
  imports: [JwtModule.register({}), MatchesModule],
  providers: [RealtimeGateway, UserPresenceService],
  exports: [RealtimeGateway, UserPresenceService],
})
export class RealtimeModule {}
