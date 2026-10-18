import { Controller, Get, Header, Inject, Module, Res } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { SkipThrottle } from '@nestjs/throttler';
import type { Response } from 'express';
import { Public } from '../common/decorators.js';
import { DbService } from '../db/db.service.js';
import { RedisService } from '../redis/redis.module.js';
import { STORAGE } from '../storage/storage.module.js';
import type { StorageDriver } from '../storage/storage.driver.js';
import { registry } from './metrics.js';

@ApiTags('health')
@SkipThrottle()
@Controller()
export class HealthController {
  constructor(
    private readonly db: DbService,
    private readonly redis: RedisService,
    @Inject(STORAGE) private readonly storage: StorageDriver,
  ) {}

  /** Liveness: the process is up. */
  @Public()
  @Get('healthz')
  live() {
    return { status: 'ok' };
  }

  /** Readiness: dependencies reachable. Returns 503 when not ready so load balancers stop routing. */
  @Public()
  @Get('readyz')
  async ready(@Res({ passthrough: true }) res: Response) {
    const [database, redis, storage] = await Promise.all([this.db.ping(), this.redis.ping(), this.storage.ping().catch(() => false)]);
    const ok = database && redis && storage;
    res.status(ok ? 200 : 503);
    return { status: ok ? 'ready' : 'degraded', checks: { database, redis, storage } };
  }

  /** Prometheus metrics. Expose only on the internal network (see infra/nginx.conf). */
  @Public()
  @Get('metrics')
  @Header('Content-Type', registry.contentType)
  metrics() {
    return registry.metrics();
  }
}

@Module({ controllers: [HealthController] })
export class HealthModule {}
