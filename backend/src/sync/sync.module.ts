import { Controller, Get, Injectable, Module } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { SkipThrottle } from '@nestjs/throttler';
import { createHash } from 'node:crypto';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser } from '../common/decorators.js';
import { AppConfigModule } from '../appconfig/appconfig.module.js';
import { AppConfigService } from '../appconfig/appconfig.service.js';
import { DbService } from '../db/db.service.js';

/**
 * Cheap change detection for clients that poll (the app checks every 30 s): returns opaque version
 * strings for the shared catalog, the caller's own library and the remote app config (`configVersion`, equal to
 * the `version` of GET /v1/app/config). Clients refetch only what changed.
 */
@Injectable()
export class SyncService {
  constructor(
    private readonly db: DbService,
    private readonly appConfig: AppConfigService,
  ) {}

  async state(userId: string) {
    const configVersion = this.appConfig.version();
    const row = await this.db.one(
      `SELECT
        (SELECT concat_ws('|',
           (SELECT count(*) FROM tracks WHERE status = 'ready'), (SELECT max(updated_at) FROM tracks),
           (SELECT count(*) FROM albums), (SELECT max(updated_at) FROM albums),
           (SELECT count(*) FROM artists), (SELECT max(updated_at) FROM artists),
           (SELECT count(*) FROM videos WHERE status = 'ready'), (SELECT max(updated_at) FROM videos),
           (SELECT count(*) FROM subtitle_tracks), (SELECT max(updated_at) FROM lyrics),
           (SELECT count(*) FROM playlists WHERE is_editorial OR visibility = 'public'),
           (SELECT max(updated_at) FROM playlists WHERE is_editorial OR visibility = 'public'),
           (SELECT count(*) || ':' || coalesce(sum(position), 0) || ':' || bool_and(enabled)::text FROM home_sections))) AS catalog,
        (SELECT concat_ws('|',
           (SELECT count(*) || ':' || max(created_at) FROM liked_tracks WHERE user_id = $1),
           (SELECT count(*) || ':' || max(created_at) FROM saved_albums WHERE user_id = $1),
           (SELECT count(*) || ':' || max(created_at) FROM followed_artists WHERE user_id = $1),
           (SELECT count(*) || ':' || max(created_at) FROM liked_videos WHERE user_id = $1),
           (SELECT count(*) || ':' || max(created_at) FROM saved_playlists WHERE user_id = $1),
           (SELECT max(removed_at) FROM library_removals WHERE user_id = $1),
           (SELECT count(*) || ':' || max(p.updated_at) FROM playlists p
              WHERE p.owner_id = $1 OR EXISTS (SELECT 1 FROM playlist_collaborators pc WHERE pc.playlist_id = p.id AND pc.user_id = $1)),
           (SELECT max(played_at) FROM playback_events WHERE user_id = $1),
           (SELECT max(updated_at) FROM video_progress WHERE user_id = $1),
           (SELECT version FROM playback_state WHERE user_id = $1),
           (SELECT preferences_version FROM users WHERE id = $1))) AS library`,
      [userId],
    );
    const h = (s: string) => createHash('sha256').update(s ?? '').digest('base64url').slice(0, 16);
    return { catalogVersion: h(row.catalog), libraryVersion: h(row.library), configVersion: await configVersion, serverTime: new Date().toISOString() };
  }
}

@ApiTags('sync')
@ApiBearerAuth()
@SkipThrottle()
@Controller('v1/sync')
export class SyncController {
  constructor(private readonly sync: SyncService) {}

  @Get('state')
  state(@CurrentUser() user: AuthUser) {
    return this.sync.state(user.id);
  }
}

@Module({ imports: [AppConfigModule], controllers: [SyncController], providers: [SyncService] })
export class SyncModule {}
