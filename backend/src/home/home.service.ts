import { Injectable, Logger } from '@nestjs/common';
import { albumFrom, albumSelect, artworkUrl, presentAlbum, presentTrack, presentVideo, trackFrom, trackSelect, videoFrom, videoSelect } from '../catalog/presenters.js';
import { DbService } from '../db/db.service.js';
import { PlaybackService } from '../playback/playback.service.js';
import { PlaylistsService } from '../playlists/playlists.service.js';
import { RecommendationsService } from '../recommendations/recommendations.service.js';

type Item = { type: string; [k: string]: unknown };

export interface HomeSection {
  id: string;
  kind: string;
  title: string;
  subtitle?: string;
  layout: 'carousel' | 'grid' | 'list' | 'hero' | 'chips';
  items: Item[];
}

const LAYOUT: Record<string, HomeSection['layout']> = {
  continue_listening: 'list',
  recently_played: 'carousel',
  made_for_you: 'carousel',
  continue_watching: 'carousel',
  favorite_artists: 'carousel',
  recently_added: 'carousel',
  trending: 'list',
  album_recommendations: 'carousel',
  music_videos: 'carousel',
  featured_playlists: 'carousel',
  genres: 'chips',
  moods: 'chips',
  editorial: 'hero',
};

/** Backend-driven home feed. Sections, order and titles come from `home_sections` (editable in the admin). */
@Injectable()
export class HomeService {
  private readonly logger = new Logger(HomeService.name);
  constructor(
    private readonly db: DbService,
    private readonly recs: RecommendationsService,
    private readonly playback: PlaybackService,
    private readonly playlists: PlaylistsService,
  ) {}

  async feed(userId: string) {
    const [user, sections, catalogSize] = await Promise.all([
      this.db.one('SELECT display_name FROM users WHERE id = $1', [userId]),
      this.db.query('SELECT id, kind, title, config FROM home_sections WHERE enabled ORDER BY position'),
      this.db.one(`SELECT count(*)::int AS n FROM tracks WHERE status = 'ready'`),
    ]);
    const built = await Promise.all(
      sections.map(async (s): Promise<HomeSection | null> => {
        try {
          const items = await this.load(s.kind, userId, s.config ?? {});
          if (!items.length) return null;
          return { id: s.id, kind: s.kind, title: s.title, subtitle: s.config?.subtitle, layout: LAYOUT[s.kind] ?? 'carousel', items };
        } catch (err) {
          // One failing shelf must not break the whole home screen.
          this.logger.error({ err, kind: s.kind }, 'Home section failed');
          return null;
        }
      }),
    );
    return {
      greeting: greeting(new Date().getHours(), user?.display_name),
      isCatalogEmpty: catalogSize?.n === 0,
      sections: built.filter((s): s is HomeSection => !!s),
    };
  }

  private async load(kind: string, userId: string, config: Record<string, any>): Promise<Item[]> {
    switch (kind) {
      case 'continue_listening':
        return (await this.playback.continueListening(userId)).map((t) => ({ type: 'track', ...t }));
      case 'recently_played': {
        const contexts = await this.playback.recentContexts(userId, 10);
        const items: Item[] = [];
        if (contexts.length) {
          const albumIds = contexts.filter((c) => c.type === 'album').map((c) => c.id);
          const playlistIds = contexts.filter((c) => c.type === 'playlist').map((c) => c.id);
          const [albums, playlists] = await Promise.all([
            albumIds.length ? this.db.query(`SELECT ${albumSelect} FROM ${albumFrom} WHERE al.id = ANY($1::uuid[])`, [albumIds]) : [],
            playlistIds.length
              ? Promise.all(playlistIds.map((id) => this.playlists.get(id, { id: userId, role: 'user' }, { limit: 1, offset: 0 }).catch(() => null)))
              : [],
          ]);
          for (const c of contexts) {
            if (c.type === 'album') {
              const a = albums.find((x: any) => x.id === c.id);
              if (a) items.push({ type: 'album', ...presentAlbum(a) });
            } else if (c.type === 'playlist') {
              const p = (playlists as any[]).find((x) => x?.playlist.id === c.id);
              if (p) items.push({ type: 'playlist', ...p.playlist });
            }
          }
        }
        const tracks = await this.playback.recentTracks(userId, { limit: 12, offset: 0 });
        return [...items, ...tracks.items.map((t) => ({ type: 'track', ...t }))].slice(0, 16);
      }
      case 'made_for_you':
        return (await this.recs.mixes(userId)).map((m) => ({ type: 'mix', ...m }));
      case 'continue_watching':
        return (await this.playback.continueWatching(userId, 12)).map((v) => ({ type: 'video', ...v }));
      case 'favorite_artists':
        return (await this.recs.favoriteArtists(userId, 12)).map((a) => ({ type: 'artist', ...a }));
      case 'recently_added': {
        const rows = await this.db.query(
          `SELECT ${albumSelect} FROM ${albumFrom} WHERE EXISTS (SELECT 1 FROM tracks t WHERE t.album_id = al.id AND t.status = 'ready')
           ORDER BY al.created_at DESC LIMIT 16`,
        );
        return rows.map((r) => ({ type: 'album', ...presentAlbum(r) }));
      }
      case 'trending':
        return (await this.recs.trending(userId, Number(config.limit ?? 10))).map((t) => ({ type: 'track', ...t }));
      case 'album_recommendations':
        return (await this.recs.albumRecommendations(userId, 12)).map((a) => ({ type: 'album', ...a }));
      case 'music_videos': {
        const rows = await this.db.query(
          `SELECT ${videoSelect('$1')} FROM ${videoFrom} WHERE v.status = 'ready' ORDER BY (v.track_id IS NOT NULL) DESC, v.created_at DESC LIMIT 12`,
          [userId],
        );
        return rows.map((r) => ({ type: 'video', ...presentVideo(r) }));
      }
      case 'featured_playlists':
        return (await this.playlists.editorial({ limit: 12, offset: 0 })).items.map((p) => ({ type: 'playlist', ...p }));
      case 'genres':
      case 'moods': {
        const col = kind === 'genres' ? 'genres' : 'moods';
        const rows = await this.db.query(
          `SELECT x AS name, count(*)::int AS track_count,
             (SELECT al.artwork_asset_id FROM tracks t2 JOIN albums al ON al.id = t2.album_id
              WHERE x = ANY(t2.${col}) AND al.artwork_asset_id IS NOT NULL ORDER BY t2.play_count DESC LIMIT 1) AS art
           FROM tracks t, unnest(t.${col}) x WHERE t.status = 'ready' GROUP BY x ORDER BY track_count DESC LIMIT 16`,
        );
        return rows.map((r) => ({ type: kind === 'genres' ? 'genre' : 'mood', name: r.name, trackCount: r.track_count, artworkUrl: artworkUrl(r.art) }));
      }
      case 'editorial': {
        // config: { trackIds?: string[], playlistId?: string }
        if (config.playlistId) {
          const p = await this.playlists.get(config.playlistId, { id: userId, role: 'user' }, { limit: 1, offset: 0 }).catch(() => null);
          return p ? [{ type: 'playlist', ...p.playlist }] : [];
        }
        if (Array.isArray(config.trackIds) && config.trackIds.length) {
          const rows = await this.db.query(`SELECT ${trackSelect('$1')} FROM ${trackFrom} WHERE t.id = ANY($2::uuid[]) AND t.status = 'ready'`, [userId, config.trackIds]);
          return rows.map((r) => ({ type: 'track', ...presentTrack(r) }));
        }
        return [];
      }
      default:
        return [];
    }
  }
}

export function greeting(hour: number, name?: string) {
  const part = hour < 5 ? 'Good night' : hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  return name ? `${part}, ${name.split(' ')[0]}` : part;
}
