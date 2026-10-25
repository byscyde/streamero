import { Module } from '@nestjs/common';
import { APP_FILTER, APP_GUARD } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { LoggerModule } from 'nestjs-pino';
import { AdminModule } from './admin/admin.module.js';
import { AppConfigModule } from './appconfig/appconfig.module.js';
import { AuthModule } from './auth/auth.module.js';
import { CatalogModule } from './catalog/catalog.module.js';
import { AllExceptionsFilter } from './common/exception.filter.js';
import { RedisThrottlerStorage } from './common/redis-throttler.storage.js';
import { loadConfig } from './config/config.js';
import { CoreModule } from './core.module.js';
import { DownloadsModule } from './downloads/downloads.module.js';
import { HealthModule } from './health/health.module.js';
import { HomeModule } from './home/home.module.js';
import { LibraryModule } from './library/library.module.js';
import { PlaybackModule } from './playback/playback.module.js';
import { PlaylistsModule } from './playlists/playlists.module.js';
import { RecommendationsModule } from './recommendations/recommendations.module.js';
import { RedisModule, RedisService } from './redis/redis.module.js';
import { SearchModule } from './search/search.module.js';
import { StreamingModule } from './streaming/streaming.module.js';
import { SyncModule } from './sync/sync.module.js';
import { UsersModule } from './users/users.module.js';
import { YoutubeModule } from './youtube/youtube.module.js';

const config = loadConfig();

@Module({
  imports: [
    LoggerModule.forRoot({
      pinoHttp: {
        level: config.LOG_LEVEL,
        // Never log credentials, tokens or signed media URLs.
        redact: { paths: ['req.headers.authorization', 'req.headers.cookie', 'req.body.password', 'req.body.refreshToken', 'req.body.token'], censor: '[redacted]' },
        serializers: {
          req: (req: any) => ({ id: req.id, method: req.method, url: String(req.url).replace(/\/v1\/media\/[^/?]+/, '/v1/media/[token]').split('?')[0] }),
        },
        autoLogging: { ignore: (req: any) => ['/healthz', '/readyz', '/metrics'].includes(req.url) },
        transport: config.NODE_ENV === 'development' ? { target: 'pino-pretty', options: { singleLine: true } } : undefined,
        genReqId: (req: any, res: any) => {
          const id = (req.headers['x-request-id'] as string)?.slice(0, 64) || crypto.randomUUID();
          res.setHeader('x-request-id', id);
          return id;
        },
      },
    }),
    CoreModule,
    ThrottlerModule.forRootAsync({
      imports: [RedisModule],
      inject: [RedisService],
      useFactory: (redis: RedisService) => ({
        throttlers: [{ name: 'default', ttl: 60_000, limit: 300 }],
        storage: new RedisThrottlerStorage(redis),
        skipIf: () => config.NODE_ENV === 'test',
      }),
    }),
    AuthModule,
    UsersModule,
    CatalogModule,
    StreamingModule,
    LibraryModule,
    PlaylistsModule,
    PlaybackModule,
    SearchModule,
    RecommendationsModule,
    HomeModule,
    DownloadsModule,
    YoutubeModule,
    AppConfigModule,
    SyncModule,
    AdminModule,
    HealthModule,
  ],
  providers: [
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    { provide: APP_FILTER, useClass: AllExceptionsFilter },
  ],
})
export class AppModule {}
