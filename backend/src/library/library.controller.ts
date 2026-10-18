import { Body, Controller, Delete, Get, HttpCode, Param, Put, Query, Post } from '@nestjs/common';
import { ApiBearerAuth, ApiProperty, ApiQuery, ApiTags } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { ArrayMaxSize, IsArray, IsIn, IsISO8601, IsUUID, ValidateNested } from 'class-validator';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser } from '../common/decorators.js';
import { badRequest } from '../common/errors.js';
import { PageQuery } from '../common/pagination.js';
import { uuidPipe } from '../common/uuid.js';
import { LibraryService, type LibraryItemType, type LibrarySort } from './library.service.js';

const TYPES = ['track', 'album', 'artist', 'video', 'playlist'] as const;

class LibraryChangeDto {
  @ApiProperty({ enum: TYPES }) @IsIn(TYPES) type: LibraryItemType;
  @ApiProperty() @IsUUID() id: string;
  @ApiProperty({ enum: ['add', 'remove'] }) @IsIn(['add', 'remove']) op: 'add' | 'remove';
  @ApiProperty({ description: 'When the change happened on the device (ISO 8601)' }) @IsISO8601() at: string;
}

class LibrarySyncDto {
  @ApiProperty({ type: [LibraryChangeDto] })
  @IsArray()
  @ArrayMaxSize(500)
  @ValidateNested({ each: true })
  @Type(() => LibraryChangeDto)
  changes: LibraryChangeDto[];
}

const sortOf = (s?: string): LibrarySort => (s === 'title' || s === 'artist' ? s : 'recent');

@ApiTags('library')
@ApiBearerAuth()
@Controller('v1/me')
export class LibraryController {
  constructor(private readonly library: LibraryService) {}

  @Get('library')
  summary(@CurrentUser() user: AuthUser) {
    return this.library.summary(user.id);
  }

  @Get('library/ids')
  ids(@CurrentUser() user: AuthUser) {
    return this.library.ids(user.id);
  }

  @Get('library/changes')
  @ApiQuery({ name: 'since', description: 'ISO 8601 timestamp of the last sync' })
  changes(@CurrentUser() user: AuthUser, @Query('since') since: string) {
    const d = new Date(since ?? '');
    if (Number.isNaN(d.getTime())) throw badRequest('invalid_since', 'since must be an ISO 8601 timestamp');
    return this.library.changes(user.id, d);
  }

  @Post('library/sync')
  @HttpCode(200)
  sync(@CurrentUser() user: AuthUser, @Body() dto: LibrarySyncDto) {
    return this.library.sync(user.id, dto.changes);
  }

  @Get('liked/tracks')
  @ApiQuery({ name: 'sort', required: false, enum: ['recent', 'title', 'artist'] })
  @ApiQuery({ name: 'q', required: false, description: 'Filter by title, artist or album' })
  liked(@CurrentUser() user: AuthUser, @Query() page: PageQuery, @Query('sort') sort?: string, @Query('q') q?: string) {
    return this.library.likedTracks(user.id, page, sortOf(sort), q?.slice(0, 100));
  }

  @Get('albums')
  albums(@CurrentUser() user: AuthUser, @Query() page: PageQuery, @Query('sort') sort?: string) {
    return this.library.savedAlbums(user.id, page, sortOf(sort));
  }

  @Get('following/artists')
  artists(@CurrentUser() user: AuthUser, @Query() page: PageQuery, @Query('sort') sort?: string) {
    return this.library.followedArtists(user.id, page, sortOf(sort));
  }

  @Get('liked/videos')
  videos(@CurrentUser() user: AuthUser, @Query() page: PageQuery) {
    return this.library.likedVideos(user.id, page);
  }

  @Get('playlists')
  playlists(@CurrentUser() user: AuthUser, @Query() page: PageQuery, @Query('sort') sort?: string) {
    return this.library.playlists(user.id, page, sortOf(sort));
  }

  @Put('liked/tracks/:id')
  saveTrack(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.library.set(user.id, 'track', id, true);
  }

  @Delete('liked/tracks/:id')
  removeTrack(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.library.set(user.id, 'track', id, false);
  }

  @Put('albums/:id')
  saveAlbum(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.library.set(user.id, 'album', id, true);
  }

  @Delete('albums/:id')
  removeAlbum(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.library.set(user.id, 'album', id, false);
  }

  @Put('following/artists/:id')
  saveArtist(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.library.set(user.id, 'artist', id, true);
  }

  @Delete('following/artists/:id')
  removeArtist(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.library.set(user.id, 'artist', id, false);
  }

  @Put('liked/videos/:id')
  saveVideo(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.library.set(user.id, 'video', id, true);
  }

  @Delete('liked/videos/:id')
  removeVideo(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.library.set(user.id, 'video', id, false);
  }

  @Put('saved/playlists/:id')
  savePlaylist(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.library.set(user.id, 'playlist', id, true);
  }

  @Delete('saved/playlists/:id')
  removePlaylist(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.library.set(user.id, 'playlist', id, false);
  }

}
