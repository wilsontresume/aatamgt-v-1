import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { MatchesModule } from '../matches/matches.module';
import { RealtimeGateway } from './realtime.gateway';

@Module({
  imports: [JwtModule.register({}), MatchesModule],
  providers: [RealtimeGateway],
  exports: [RealtimeGateway],
})
export class RealtimeModule {}
