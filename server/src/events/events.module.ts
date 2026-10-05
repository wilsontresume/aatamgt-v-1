import { Global, Module } from '@nestjs/common';
import { MatchEventsService } from './match-events.service';

@Global()
@Module({
  providers: [MatchEventsService],
  exports: [MatchEventsService],
})
export class EventsModule {}
