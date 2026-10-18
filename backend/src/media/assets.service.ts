import { Inject, Injectable, Logger } from '@nestjs/common';
import { DbService, type Queryable } from '../db/db.service.js';
import { STORAGE } from '../storage/storage.module.js';
import type { StorageDriver } from '../storage/storage.driver.js';

/** Every column that can reference a media asset. Keep in sync with migrations. */
const REFERENCES: [table: string, column: string][] = [
  ['users', 'avatar_asset_id'],
  ['artists', 'artwork_asset_id'],
  ['albums', 'artwork_asset_id'],
  ['tracks', 'original_asset_id'],
  ['track_renditions', 'asset_id'],
  ['videos', 'original_asset_id'],
  ['videos', 'hls_asset_id'],
  ['videos', 'thumbnail_asset_id'],
  ['videos', 'preview_asset_id'],
  ['videos', 'audio_asset_id'],
  ['subtitle_tracks', 'asset_id'],
  ['subtitle_tracks', 'original_asset_id'],
  ['playlists', 'artwork_asset_id'],
];

@Injectable()
export class AssetsService {
  private readonly logger = new Logger(AssetsService.name);
  constructor(
    private readonly db: DbService,
    @Inject(STORAGE) private readonly storage: StorageDriver,
  ) {}

  async referenceCount(assetId: string, client?: Queryable): Promise<number> {
    const sql = REFERENCES.map(([t, c]) => `(SELECT count(*) FROM ${t} WHERE ${c} = $1)`).join(' + ');
    const row = await this.db.one(`SELECT (${sql})::int AS n`, [assetId], client);
    return row?.n ?? 0;
  }

  /**
   * Deletes an asset row and its stored bytes only when nothing references it any more, so removing
   * one catalog entry can never delete media shared with another (e.g. album artwork, reused originals).
   */
  async deleteIfUnreferenced(assetIds: (string | null | undefined)[]) {
    const deleted: string[] = [];
    for (const id of new Set(assetIds.filter((x): x is string => !!x))) {
      const key = await this.db.tx(async (client) => {
        const asset = await this.db.one('SELECT storage_key FROM media_assets WHERE id = $1 FOR UPDATE', [id], client);
        if (!asset) return null;
        if ((await this.referenceCount(id, client)) > 0) return null;
        await this.db.query('DELETE FROM download_grants WHERE asset_id = $1', [id], client);
        await this.db.query('DELETE FROM media_assets WHERE id = $1', [id], client);
        return asset.storage_key as string;
      });
      if (!key) continue;
      try {
        if (key.endsWith('/')) await this.storage.deletePrefix(key);
        else await this.storage.delete(key);
        deleted.push(id);
      } catch (err) {
        // The row is gone; orphaned bytes are reported by the storage audit in the admin dashboard.
        this.logger.error({ err, assetId: id }, 'Failed to delete stored media');
      }
    }
    return deleted;
  }
}
