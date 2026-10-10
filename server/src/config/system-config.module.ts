import { Global, Module } from '@nestjs/common';
import { SystemConfigService } from './system-config.service';

/** Runtime configuration store — global so auth, rewards, ads, shop and
 *  the admin dashboard all read the same live values. */
@Global()
@Module({
  providers: [SystemConfigService],
  exports: [SystemConfigService],
})
export class SystemConfigModule {}
