import { Controller, Get, HttpStatus, Inject, Injectable, Logger, Module, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { AppError, badRequest } from '../common/errors.js';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { RedisService } from '../redis/redis.module.js';

/**
 * YouTube *discovery* through the official YouTube Data API v3. Playback happens on the client through
 * the official embedded IFrame player (foreground only, YouTube branding and ads intact).
 * This module never downloads, extracts or proxies YouTube media streams.
 */
@Injectable()
export class YoutubeService {
  private readonly logger = new Logger(YoutubeService.name);
  constructor(
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    private readonly redis: RedisService,
  ) {}

  get enabled() {
    return !!this.config.YOUTUBE_API_KEY;
  }

  async search(q: string, pageToken?: string) {
    if (!this.enabled) throw new AppError(HttpStatus.NOT_IMPLEMENTED, 'youtube_not_configured', 'YouTube discovery is not configured');
    const query = q.trim().slice(0, 100);
    if (!query) throw badRequest('missing_query', 'q is required');
    const cacheKey = `yt:search:${query.toLowerCase()}:${pageToken ?? ''}`;
    const cached = await this.redis.client.get(cacheKey).catch(() => null);
    if (cached) return JSON.parse(cached);
    const url = new URL('https://www.googleapis.com/youtube/v3/search');
    url.search = new URLSearchParams({
      part: 'snippet',
      type: 'video',
      videoEmbeddable: 'true',
      safeSearch: 'moderate',
      maxResults: '20',
      q: query,
      key: this.config.YOUTUBE_API_KEY,
      ...(pageToken ? { pageToken } : {}),
    }).toString();
    const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) {
      this.logger.warn({ status: res.status }, 'YouTube API request failed');
      throw new AppError(HttpStatus.BAD_GATEWAY, 'youtube_unavailable', 'YouTube search is temporarily unavailable');
    }
    const body: any = await res.json();
    const result = {
      nextPageToken: body.nextPageToken ?? null,
      items: (body.items ?? []).map((i: any) => ({
        videoId: i.id?.videoId,
        title: i.snippet?.title,
        channelTitle: i.snippet?.channelTitle,
        publishedAt: i.snippet?.publishedAt,
        thumbnailUrl: i.snippet?.thumbnails?.high?.url ?? i.snippet?.thumbnails?.default?.url ?? null,
        // Clients must open this with the official player and honour YouTube's Terms of Service.
        embedUrl: `https://www.youtube.com/embed/${i.id?.videoId}`,
        watchUrl: `https://www.youtube.com/watch?v=${i.id?.videoId}`,
      })),
      attribution: 'Results provided by YouTube',
    };
    await this.redis.client.set(cacheKey, JSON.stringify(result), 'EX', 3600).catch(() => undefined);
    return result;
  }
}

@ApiTags('youtube')
@ApiBearerAuth()
@Controller('v1/youtube')
export class YoutubeController {
  constructor(private readonly yt: YoutubeService) {}

  @Get('status')
  status() {
    return { enabled: this.yt.enabled, backgroundPlayback: false, downloads: false };
  }

  @Get('search')
  search(@Query('q') q: string, @Query('pageToken') pageToken?: string) {
    return this.yt.search(q ?? '', pageToken?.slice(0, 100));
  }
}

@Module({ controllers: [YoutubeController], providers: [YoutubeService] })
export class YoutubeModule {}
