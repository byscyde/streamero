import { Injectable } from '@nestjs/common';
import { conflict } from '../common/errors.js';
import { toPage, type PageQuery } from '../common/pagination.js';
import { presentTrack, presentVideo, trackFrom, trackSelect, videoFrom, videoSelect } from '../catalog/presenters.js';
import { DbService } from '../db/db.service.js';

export interface PlaybackEventInput {
  clientEventId: string;
  trackId?: string;
  videoId?: string;
  playedAt: string;
  durationPlayedMs: number;
  completed?: boolean;
  contextType?: string;
  contextId?: string;
  deviceId?: string;
}

/** A play counts towards play counts/charts after 30 seconds or when completed (whichever first). */
export const COUNTABLE_PLAY_MS = 30_000;

@Injectable()
export class PlaybackService {
  constructor(private readonly db: DbService) {}

  /**
   * Records plays idempotently (clientEventId is unique per user), so offline queues can be re-sent safely.
   * When the user disabled listening history, nothing user-linked is stored; only aggregate counters move.
   */
  async recordEvents(userId: string, events: PlaybackEventInput[]) {
    const user = await this.db.one('SELECT history_enabled FROM users WHERE id = $1', [userId]);
    let accepted = 0;
    let duplicates = 0;
    for (const e of events) {
      if (!e.trackId === !e.videoId) continue;
      const countable = e.completed || e.durationPlayedMs >= COUNTABLE_PLAY_MS;
      const playedAt = clampDate(e.playedAt);
      await this.db.tx(async (client) => {
        let isNew = true;
        if (user?.history_enabled) {
          const res = await this.db.query(
            `INSERT INTO playback_events (user_id, track_id, video_id, client_event_id, played_at, duration_played_ms, completed, context_type, context_id, device_id)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
             ON CONFLICT (user_id, client_event_id) DO NOTHING RETURNING id`,
            [userId, e.trackId ?? null, e.videoId ?? null, e.clientEventId, playedAt, Math.max(0, Math.round(e.durationPlayedMs)), !!e.completed,
              e.contextType ?? null, e.contextId ?? null, e.deviceId?.slice(0, 100) ?? null],
            client,
          );
          isNew = res.length > 0;
        } else {
          // Without history we still need idempotency for counters: use a short-lived Redis-free guard via the idempotency table.
          const res = await this.db.query(
            `INSERT INTO idempotency_keys (user_id, key, route, status, response) VALUES ($1, $2, 'playback-event', 200, '{}')
             ON CONFLICT DO NOTHING RETURNING 1 AS ok`,
            [userId, `pe:${e.clientEventId}`],
            client,
          );
          isNew = res.length > 0;
        }
        if (!isNew) {
          duplicates++;
          return;
        }
        accepted++;
        if (countable && e.trackId) await this.db.query('UPDATE tracks SET play_count = play_count + 1 WHERE id = $1', [e.trackId], client);
        if (countable && e.videoId) await this.db.query('UPDATE videos SET view_count = view_count + 1 WHERE id = $1', [e.videoId], client);
      });
    }
    return { accepted, duplicates };
  }

  /** Recently played tracks, de-duplicated (latest play per track). */
  async recentTracks(userId: string, page: PageQuery) {
    const rows = await this.db.query(
      `SELECT ${trackSelect('$1')}, r.last_played
       FROM (SELECT track_id, max(played_at) AS last_played FROM playback_events WHERE user_id = $1 AND track_id IS NOT NULL GROUP BY track_id) r
       JOIN ${trackFrom} ON t.id = r.track_id
       WHERE t.status = 'ready'
       ORDER BY r.last_played DESC LIMIT $2 OFFSET $3`,
      [userId, page.limit + 1, page.offset],
    );
    return toPage(rows.map((r) => ({ ...presentTrack(r), lastPlayedAt: r.last_played })), page);
  }

  /** Raw history (every play), newest first. */
  async history(userId: string, page: PageQuery) {
    const rows = await this.db.query(
      `SELECT pe.id AS event_id, pe.played_at, pe.duration_played_ms, pe.completed, pe.context_type, pe.context_id, ${trackSelect('$1')}
       FROM playback_events pe JOIN ${trackFrom} ON t.id = pe.track_id
       WHERE pe.user_id = $1 ORDER BY pe.played_at DESC LIMIT $2 OFFSET $3`,
      [userId, page.limit + 1, page.offset],
    );
    return toPage(
      rows.map((r) => ({
        id: r.event_id,
        playedAt: r.played_at,
        durationPlayedMs: r.duration_played_ms,
        completed: r.completed,
        context: r.context_type ? { type: r.context_type, id: r.context_id } : null,
        track: presentTrack(r),
      })),
      page,
    );
  }

  /** Recently used contexts (albums/playlists/artists) for "Jump back in". */
  async recentContexts(userId: string, limit = 12) {
    return this.db.query(
      `SELECT context_type AS type, context_id AS id, max(played_at) AS "lastPlayedAt"
       FROM playback_events WHERE user_id = $1 AND context_id IS NOT NULL AND context_type IN ('album', 'playlist', 'artist')
       GROUP BY context_type, context_id ORDER BY max(played_at) DESC LIMIT $2`,
      [userId, limit],
    );
  }

  async clearHistory(userId: string) {
    await this.db.query('DELETE FROM playback_events WHERE user_id = $1', [userId]);
    await this.db.query('DELETE FROM track_progress WHERE user_id = $1', [userId]);
  }

  /** Last-write-wins on the device timestamp, so an older offline update never overwrites newer progress. */
  async saveVideoProgress(userId: string, videoId: string, positionMs: number, durationMs: number, completed: boolean | undefined, updatedAt?: string) {
    const at = clampDate(updatedAt);
    const done = completed ?? (durationMs > 0 && positionMs >= durationMs * 0.95);
    const row = await this.db.one(
      `INSERT INTO video_progress (user_id, video_id, position_ms, duration_ms, completed, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (user_id, video_id) DO UPDATE SET position_ms = EXCLUDED.position_ms, duration_ms = EXCLUDED.duration_ms,
         completed = EXCLUDED.completed, updated_at = EXCLUDED.updated_at
       WHERE video_progress.updated_at <= EXCLUDED.updated_at
       RETURNING position_ms, completed, updated_at`,
      [userId, videoId, Math.max(0, Math.round(positionMs)), Math.max(0, Math.round(durationMs)), done, at],
    );
    return row ?? (await this.db.one('SELECT position_ms, completed, updated_at FROM video_progress WHERE user_id = $1 AND video_id = $2', [userId, videoId]));
  }

  async continueWatching(userId: string, limit = 20) {
    const rows = await this.db.query(
      `SELECT ${videoSelect('$1')} FROM video_progress vp JOIN ${videoFrom} ON v.id = vp.video_id
       WHERE vp.user_id = $1 AND NOT vp.completed AND vp.position_ms > 5000 AND v.status = 'ready'
       ORDER BY vp.updated_at DESC LIMIT $2`,
      [userId, limit],
    );
    return rows.map(presentVideo);
  }

  async saveTrackProgress(userId: string, trackId: string, positionMs: number) {
    await this.db.query(
      `INSERT INTO track_progress (user_id, track_id, position_ms) VALUES ($1, $2, $3)
       ON CONFLICT (user_id, track_id) DO UPDATE SET position_ms = EXCLUDED.position_ms, updated_at = now()`,
      [userId, trackId, Math.max(0, Math.round(positionMs))],
    );
  }

  /** Continue listening: long tracks (> 10 min) left part-way through. */
  async continueListening(userId: string, limit = 12) {
    const rows = await this.db.query(
      `SELECT ${trackSelect('$1')}, tp.position_ms AS resume_ms FROM track_progress tp JOIN ${trackFrom} ON t.id = tp.track_id
       WHERE tp.user_id = $1 AND t.status = 'ready' AND tp.position_ms > 30000 AND tp.position_ms < t.duration_ms - 30000
       ORDER BY tp.updated_at DESC LIMIT $2`,
      [userId, limit],
    );
    return rows.map((r) => ({ ...presentTrack(r), resumePositionMs: r.resume_ms }));
  }

  async getState(userId: string) {
    const row = await this.db.one('SELECT state, version, device_id, updated_at FROM playback_state WHERE user_id = $1', [userId]);
    return row ? { state: row.state, version: row.version, deviceId: row.device_id, updatedAt: row.updated_at } : { state: null, version: 0, deviceId: null, updatedAt: null };
  }

  /**
   * Compare-and-swap on `baseVersion`: a device may only overwrite the state it last saw.
   * On conflict the current state is returned so the client can decide (adopt or force with the new version).
   */
  async putState(userId: string, state: unknown, baseVersion: number, deviceId?: string) {
    const json = JSON.stringify(state);
    if (json.length > 256 * 1024) throw conflict('state_too_large', 'Playback state exceeds 256 KB');
    const row = await this.db.one(
      `INSERT INTO playback_state (user_id, state, version, device_id) VALUES ($1, $2, 1, $4)
       ON CONFLICT (user_id) DO UPDATE SET state = EXCLUDED.state, version = playback_state.version + 1,
         device_id = EXCLUDED.device_id, updated_at = now()
       WHERE playback_state.version = $3
       RETURNING version, updated_at`,
      [userId, json, baseVersion, deviceId ?? null],
    );
    if (!row) {
      const current = await this.getState(userId);
      throw conflict('version_conflict', 'Playback state changed on another device', current);
    }
    return { version: row.version, updatedAt: row.updated_at };
  }
}

function clampDate(v?: string): Date {
  const d = v ? new Date(v) : new Date();
  if (Number.isNaN(d.getTime())) return new Date();
  // Device clocks drift; never accept timestamps from the future.
  return d.getTime() > Date.now() ? new Date() : d;
}
