import { Controller, Get, Inject, Param, Query, Res } from '@nestjs/common';
import { ApiBearerAuth, ApiQuery, ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser, OptionalAuth, Public } from '../common/decorators.js';
import { badRequest, notFound } from '../common/errors.js';
import { PageQuery } from '../common/pagination.js';
import { UUID_RE, uuidPipe } from '../common/uuid.js';
import { DbService } from '../db/db.service.js';
import { STORAGE } from '../storage/storage.module.js';
import type { StorageDriver } from '../storage/storage.driver.js';
import { CatalogService } from './catalog.service.js';

@ApiTags('catalog')
@ApiBearerAuth()
@Controller('v1')
export class CatalogController {
  constructor(private readonly catalog: CatalogService) {}

  @Get('tracks')
  @ApiQuery({ name: 'ids', description: 'Comma separated track ids (max 200)' })
  tracks(@Query('ids') ids: string, @CurrentUser() user: AuthUser) {
    const list = (ids ?? '').split(',').map((s) => s.trim()).filter(Boolean);
    if (list.length === 0 || list.length > 200 || !list.every((id) => UUID_RE.test(id))) {
      throw badRequest('invalid_ids', 'Provide 1-200 comma separated track UUIDs');
    }
    return this.catalog.tracksByIds(list, user.id).then((items) => ({ items }));
  }

  @Get('tracks/:id')
  track(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser) {
    return this.catalog.track(id, user.id);
  }

  @Get('tracks/:id/lyrics')
  lyrics(@Param('id', uuidPipe) id: string) {
    return this.catalog.lyrics(id);
  }

  @Get('artists')
  artists(@Query() page: PageQuery) {
    return this.catalog.artists(page);
  }

  @Get('artists/:id')
  artist(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser) {
    return this.catalog.artist(id, user.id);
  }

  @Get('artists/:id/tracks')
  artistTracks(@Param('id', uuidPipe) id: string, @Query() page: PageQuery, @CurrentUser() user: AuthUser) {
    return this.catalog.artistTracks(id, user.id, page);
  }

  @Get('albums')
  @ApiQuery({ name: 'sort', required: false, enum: ['recent', 'title'] })
  albums(@Query() page: PageQuery, @Query('sort') sort?: 'recent' | 'title') {
    return this.catalog.albums(page, sort === 'title' ? 'title' : 'recent');
  }

  @Get('albums/:id')
  album(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser) {
    return this.catalog.album(id, user.id);
  }

  @Get('videos')
  @ApiQuery({ name: 'genre', required: false })
  videos(@Query() page: PageQuery, @CurrentUser() user: AuthUser, @Query('genre') genre?: string) {
    return this.catalog.videos(user.id, page, genre);
  }

  @Get('videos/:id')
  video(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser) {
    return this.catalog.video(id, user.id);
  }

  @Get('genres')
  genres() {
    return this.catalog.genres();
  }

  @Get('genres/:name/tracks')
  genreTracks(@Param('name') name: string, @Query() page: PageQuery, @CurrentUser() user: AuthUser) {
    return this.catalog.tracksByTag('genre', name.slice(0, 80), user.id, page);
  }

  @Get('moods/:name/tracks')
  moodTracks(@Param('name') name: string, @Query() page: PageQuery, @CurrentUser() user: AuthUser) {
    return this.catalog.tracksByTag('mood', name.slice(0, 80), user.id, page);
  }
}

/** Artwork is addressed by unguessable asset ids, is not sensitive, and is cached forever by clients/CDNs. */
@ApiTags('catalog')
@Controller('v1/artwork')
export class ArtworkController {
  constructor(
    private readonly db: DbService,
    @Inject(STORAGE) private readonly storage: StorageDriver,
  ) {}

  @Public()
  @OptionalAuth()
  @Get(':id')
  @ApiQuery({ name: 'size', required: false, enum: ['small', 'large'] })
  async artwork(@Param('id', uuidPipe) id: string, @Query('size') size: string | undefined, @Res() res: Response) {
    const asset = await this.db.one(
      `SELECT storage_key, mime_type FROM media_assets WHERE id = $1 AND kind IN ('artwork', 'thumbnail', 'avatar')`,
      [id],
    );
    if (!asset) throw notFound('Artwork');
    const key = asset.storage_key.endsWith('/') ? `${asset.storage_key}${size === 'small' ? 'small' : 'large'}.jpg` : asset.storage_key;
    const obj = await this.storage.get(key);
    if (!obj) throw notFound('Artwork');
    res.setHeader('Content-Type', asset.mime_type);
    res.setHeader('Content-Length', String(obj.contentLength));
    res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    obj.stream.pipe(res);
  }
}
