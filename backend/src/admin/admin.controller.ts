import { Body, Controller, Delete, Get, HttpCode, Param, ParseIntPipe, Patch, Post, Put, Query, Req } from '@nestjs/common';
import { ApiBearerAuth, ApiBody, ApiConsumes, ApiCreatedResponse, ApiNoContentResponse, ApiOkResponse, ApiProperty, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { PASSWORD_MSG, PASSWORD_RULE } from '../auth/auth.dto.js';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsBoolean,
  IsEmail,
  IsIn,
  IsInt,
  IsObject,
  IsOptional,
  IsString,
  IsUUID,
  Length,
  Matches,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import type { Request } from 'express';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser, RequireRole } from '../common/decorators.js';
import { badRequest } from '../common/errors.js';
import { PageQuery } from '../common/pagination.js';
import { uuidPipe } from '../common/uuid.js';
import { JobsService } from '../ingestion/jobs.service.js';
import { UploadsService, type UploadPurpose } from '../ingestion/uploads.service.js';
import { validateImportUrl } from '../ingestion/importers.js';
import { AdminService } from './admin.service.js';
import { Inject } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../config/config.js';

class CreateUploadDto {
  @ApiProperty() @IsString() @Length(1, 255) filename: string;
  @ApiProperty() @IsInt() @Min(1) totalBytes: number;
  @ApiProperty({ enum: ['media', 'subtitle', 'artwork'] }) @IsIn(['media', 'subtitle', 'artwork']) purpose: UploadPurpose;
  @ApiPropertyOptional() @IsOptional() @IsObject() options?: Record<string, unknown>;
}

class UrlImportDto {
  @ApiProperty() @IsString() @MaxLength(2048) url: string;
  @ApiProperty({ description: 'Who owns the rights / why STREAMERO may store this file. Recorded in provenance.' })
  @IsString()
  @Length(5, 1000)
  authorizationNote: string;
  @ApiPropertyOptional() @IsOptional() @IsObject() overrides?: Record<string, unknown>;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() force?: boolean;
}

class PathImportDto {
  @ApiProperty({ description: 'Absolute path inside IMPORT_ALLOWED_DIRS (file or folder)' }) @IsString() @MaxLength(1024) path: string;
  @ApiProperty() @IsString() @Length(5, 1000) authorizationNote: string;
  @ApiPropertyOptional() @IsOptional() @IsObject() overrides?: Record<string, unknown>;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() force?: boolean;
}

class ReprocessDto {
  @ApiPropertyOptional() @IsOptional() @IsUUID() trackId?: string;
  @ApiPropertyOptional() @IsOptional() @IsUUID() videoId?: string;
}

class TrackPatchDto {
  @ApiPropertyOptional() @IsOptional() @IsString() @Length(1, 500) title?: string;
  @ApiPropertyOptional() @IsOptional() @IsString() @Length(1, 300) artistName?: string;
  @ApiPropertyOptional({ nullable: true }) @IsOptional() @IsUUID() albumId?: string | null;
  @ApiPropertyOptional({ nullable: true }) @IsOptional() @IsInt() @Min(1) trackNumber?: number | null;
  @ApiPropertyOptional() @IsOptional() @IsInt() @Min(1) discNumber?: number;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() explicit?: boolean;
  @ApiPropertyOptional({ type: [String] }) @IsOptional() @IsArray() @ArrayMaxSize(20) @IsString({ each: true }) genres?: string[];
  @ApiPropertyOptional({ type: [String] }) @IsOptional() @IsArray() @ArrayMaxSize(20) @IsString({ each: true }) moods?: string[];
  @ApiPropertyOptional() @IsOptional() @IsBoolean() downloadable?: boolean;
  @ApiPropertyOptional({ nullable: true }) @IsOptional() @IsString() @MaxLength(15) isrc?: string | null;
}

class BulkDto {
  @ApiProperty({ type: [String] }) @IsArray() @ArrayMaxSize(500) @IsUUID('all', { each: true }) ids: string[];
  @ApiProperty({ enum: ['set_downloadable', 'set_explicit', 'add_genre', 'reprocess', 'delete'] })
  @IsIn(['set_downloadable', 'set_explicit', 'add_genre', 'reprocess', 'delete'])
  action: string;
  @ApiPropertyOptional() @IsOptional() value?: unknown;
}

class LyricsDto {
  @ApiProperty({ description: 'LRC (synchronised) or plain text' }) @IsString() @Length(1, 100_000) content: string;
  @ApiPropertyOptional() @IsOptional() @IsString() @MaxLength(200) source?: string;
  @ApiPropertyOptional({ description: 'Licence / attribution note' }) @IsOptional() @IsString() @MaxLength(500) license?: string;
}

class AlbumPatchDto {
  @ApiPropertyOptional() @IsOptional() @IsString() @Length(1, 300) title?: string;
  @ApiPropertyOptional() @IsOptional() @IsIn(['album', 'single', 'ep', 'compilation']) albumType?: string;
  @ApiPropertyOptional({ nullable: true }) @IsOptional() @IsString() releaseDate?: string | null;
  @ApiPropertyOptional({ type: [String] }) @IsOptional() @IsArray() @IsString({ each: true }) genres?: string[];
  @ApiPropertyOptional({ nullable: true }) @IsOptional() @IsString() @MaxLength(200) label?: string | null;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() explicit?: boolean;
  @ApiPropertyOptional() @IsOptional() @IsUUID() artistId?: string;
}

class ArtistPatchDto {
  @ApiPropertyOptional() @IsOptional() @IsString() @Length(1, 300) name?: string;
  @ApiPropertyOptional({ nullable: true }) @IsOptional() @IsString() @MaxLength(10_000) bio?: string | null;
  @ApiPropertyOptional({ type: [String] }) @IsOptional() @IsArray() @IsString({ each: true }) genres?: string[];
  @ApiPropertyOptional({ nullable: true }) @IsOptional() @IsString() @MaxLength(300) sortName?: string | null;
}

class VideoPatchDto {
  @ApiPropertyOptional() @IsOptional() @IsString() @Length(1, 500) title?: string;
  @ApiPropertyOptional({ nullable: true }) @IsOptional() @IsString() @MaxLength(10_000) description?: string | null;
  @ApiPropertyOptional({ nullable: true }) @IsOptional() @IsUUID() trackId?: string | null;
  @ApiPropertyOptional() @IsOptional() @IsString() @Length(1, 300) artistName?: string;
  @ApiPropertyOptional({ type: [String] }) @IsOptional() @IsArray() @IsString({ each: true }) genres?: string[];
  @ApiPropertyOptional() @IsOptional() @IsBoolean() explicit?: boolean;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() downloadable?: boolean;
}

class SubtitlePatchDto {
  @ApiPropertyOptional() @IsOptional() @IsString() @Length(1, 100) label?: string;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() isDefault?: boolean;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() forced?: boolean;
}

class UserPatchDto {
  @ApiPropertyOptional({ enum: ['user', 'editor', 'admin'] }) @IsOptional() @IsIn(['user', 'editor', 'admin']) role?: 'user' | 'editor' | 'admin';
  @ApiPropertyOptional() @IsOptional() @IsBoolean() disabled?: boolean;
  @ApiPropertyOptional() @IsOptional() @IsEmail() @MaxLength(254) email?: string;
  @ApiPropertyOptional() @IsOptional() @IsString() @Length(1, 80) displayName?: string;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() emailVerified?: boolean;
}

class CreateUserDto {
  @ApiProperty() @IsEmail() @MaxLength(254) email: string;
  @ApiProperty() @IsString() @Length(1, 80) displayName: string;
  @ApiProperty({ enum: ['user', 'editor', 'admin'] }) @IsIn(['user', 'editor', 'admin']) role: 'user' | 'editor' | 'admin';
  @ApiPropertyOptional({ minLength: 10, description: 'Omit to email the user a link to choose their own password' })
  @IsOptional()
  @IsString()
  @Matches(PASSWORD_RULE, { message: PASSWORD_MSG })
  password?: string;
  @ApiPropertyOptional({ description: 'Also email a set-password link when a password is given' }) @IsOptional() @IsBoolean() sendInvite?: boolean;
}

class SetPasswordDto {
  @ApiProperty({ minLength: 10 }) @IsString() @Matches(PASSWORD_RULE, { message: PASSWORD_MSG }) password: string;
}

class AdminUserDto {
  @ApiProperty() id: string;
  @ApiProperty() email: string;
  @ApiProperty() displayName: string;
  @ApiProperty({ enum: ['user', 'editor', 'admin'] }) role: string;
  @ApiProperty() disabled: boolean;
  @ApiProperty() emailVerified: boolean;
  @ApiProperty() createdAt: string;
  @ApiProperty({ nullable: true, type: String }) lastActiveAt: string | null;
  @ApiProperty({ nullable: true, type: String }) lastPlayedAt: string | null;
}

class HomeSectionDto {
  @ApiPropertyOptional() @IsOptional() @IsUUID() id?: string;
  @ApiProperty() @IsString() @Length(1, 60) kind: string;
  @ApiProperty() @IsString() @Length(1, 100) title: string;
  @ApiProperty() @IsBoolean() enabled: boolean;
  @ApiPropertyOptional() @IsOptional() @IsObject() config?: object;
}

class HomeSectionsDto {
  @ApiProperty({ type: [HomeSectionDto] })
  @IsArray()
  @ArrayMaxSize(50)
  @ValidateNested({ each: true })
  @Type(() => HomeSectionDto)
  sections: HomeSectionDto[];
}

/** Catalog operations need at least the editor role; user/role management and system config need admin. */
@ApiTags('admin')
@ApiBearerAuth()
@RequireRole('editor')
@Controller('v1/admin')
export class AdminController {
  constructor(
    private readonly admin: AdminService,
    private readonly uploads: UploadsService,
    private readonly jobs: JobsService,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
  ) {}

  @Get('overview')
  overview() {
    return this.admin.overview();
  }

  @Get('activity')
  activity(@Query('days') days?: string) {
    return this.admin.activity(Math.min(365, Math.max(1, Number(days) || 30)));
  }

  @Get('storage')
  storage() {
    return this.admin.storageUsage();
  }

  // ------------------------------------------------ uploads & imports
  @Post('uploads')
  createUpload(@CurrentUser() user: AuthUser, @Body() dto: CreateUploadDto) {
    return this.uploads.create(user.id, dto);
  }

  @Get('uploads/:id')
  upload(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.uploads.status(id, user.id);
  }

  @Put('uploads/:id/chunks/:index')
  @ApiConsumes('application/octet-stream')
  @ApiBody({ schema: { type: 'string', format: 'binary' } })
  chunk(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Param('index', ParseIntPipe) index: number, @Req() req: Request) {
    if (!Buffer.isBuffer(req.body)) throw badRequest('invalid_body', 'Send the chunk as application/octet-stream');
    return this.uploads.putChunk(id, user.id, index, req.body);
  }

  @Post('uploads/:id/complete')
  @HttpCode(200)
  complete(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.uploads.complete(id, user.id);
  }

  @Delete('uploads/:id')
  @HttpCode(204)
  async abort(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    await this.uploads.abort(id, user.id);
  }

  @Post('imports/url')
  importUrl(@CurrentUser() user: AuthUser, @Body() dto: UrlImportDto) {
    // Validate synchronously so policy errors (blocked host, YouTube) are reported immediately.
    try {
      validateImportUrl(dto.url, { allowedHosts: this.config.IMPORT_ALLOWED_HOSTS, allowPrivateNetworks: this.config.IMPORT_ALLOW_PRIVATE_NETWORKS });
    } catch (err: any) {
      throw badRequest('import_not_allowed', err.message);
    }
    return this.jobs.create('import_url', { url: dto.url, overrides: dto.overrides ?? {}, force: !!dto.force }, user.id, {
      source: 'url',
      sourceUrl: dto.url.split('?')[0],
      authorizationNote: dto.authorizationNote,
      importedBy: user.id,
      importedAt: new Date().toISOString(),
    });
  }

  @Post('imports/path')
  @RequireRole('admin')
  importPath(@CurrentUser() user: AuthUser, @Body() dto: PathImportDto) {
    return this.jobs.create('import_path', { path: dto.path, overrides: dto.overrides ?? {}, force: !!dto.force }, user.id, {
      source: 'server_path',
      authorizationNote: dto.authorizationNote,
      importedBy: user.id,
      importedAt: new Date().toISOString(),
    });
  }

  // ------------------------------------------------ jobs
  @Get('jobs')
  jobsList(@Query() page: PageQuery, @Query('status') status?: string, @Query('type') type?: string) {
    return this.jobs.list(page, status || undefined, type || undefined);
  }

  @Get('jobs/:id')
  job(@Param('id', uuidPipe) id: string) {
    return this.jobs.get(id);
  }

  @Post('jobs/:id/retry')
  @HttpCode(200)
  retry(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.jobs.retry(id, user.id);
  }

  @Post('jobs/:id/cancel')
  @HttpCode(200)
  cancel(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.jobs.cancel(id, user.id);
  }

  @Post('reprocess')
  reprocess(@CurrentUser() user: AuthUser, @Body() dto: ReprocessDto) {
    if (!dto.trackId === !dto.videoId) throw badRequest('invalid_request', 'Provide exactly one of trackId or videoId');
    return this.jobs.create('reprocess', { ...dto }, user.id);
  }

  // ------------------------------------------------ catalog
  @Get('tracks')
  tracks(@Query() page: PageQuery, @Query('q') q?: string, @Query('status') status?: string) {
    return this.admin.tracks(page, q?.slice(0, 100), status);
  }

  @Get('tracks/:id')
  track(@Param('id', uuidPipe) id: string) {
    return this.admin.track(id);
  }

  @Patch('tracks/:id')
  updateTrack(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Body() dto: TrackPatchDto) {
    return this.admin.updateTrack(user.id, id, dto);
  }

  @Delete('tracks/:id')
  deleteTrack(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.admin.deleteTrack(user.id, id);
  }

  @Post('tracks/bulk')
  @HttpCode(200)
  bulk(@CurrentUser() user: AuthUser, @Body() dto: BulkDto) {
    return this.admin.bulkTracks(user.id, dto.ids, dto.action, dto.value);
  }

  @Put('tracks/:id/lyrics')
  lyrics(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Body() dto: LyricsDto) {
    return this.admin.setLyrics(user.id, id, dto.content, dto.source, dto.license);
  }

  @Delete('tracks/:id/lyrics')
  @HttpCode(204)
  async deleteLyrics(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    await this.admin.deleteLyrics(user.id, id);
  }

  @Get('albums')
  albums(@Query() page: PageQuery, @Query('q') q?: string) {
    return this.admin.albums(page, q?.slice(0, 100));
  }

  @Patch('albums/:id')
  updateAlbum(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Body() dto: AlbumPatchDto) {
    return this.admin.updateAlbum(user.id, id, dto);
  }

  @Delete('albums/:id')
  deleteAlbum(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Query('withTracks') withTracks?: string) {
    return this.admin.deleteAlbum(user.id, id, withTracks === 'true');
  }

  @Get('artists')
  artists(@Query() page: PageQuery, @Query('q') q?: string) {
    return this.admin.artists(page, q?.slice(0, 100));
  }

  @Patch('artists/:id')
  updateArtist(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Body() dto: ArtistPatchDto) {
    return this.admin.updateArtist(user.id, id, dto);
  }

  @Delete('artists/:id')
  deleteArtist(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.admin.deleteArtist(user.id, id);
  }

  @Get('videos')
  videos(@Query() page: PageQuery, @Query('q') q?: string) {
    return this.admin.videos(page, q?.slice(0, 100));
  }

  @Patch('videos/:id')
  updateVideo(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Body() dto: VideoPatchDto) {
    return this.admin.updateVideo(user.id, id, dto);
  }

  @Delete('videos/:id')
  deleteVideo(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    return this.admin.deleteVideo(user.id, id);
  }

  @Patch('subtitles/:id')
  updateSubtitle(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Body() dto: SubtitlePatchDto) {
    return this.admin.updateSubtitle(user.id, id, dto);
  }

  @Delete('subtitles/:id')
  @HttpCode(204)
  async deleteSubtitle(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    await this.admin.deleteSubtitle(user.id, id);
  }

  @Get('home-sections')
  home() {
    return this.admin.homeSections();
  }

  @Put('home-sections')
  saveHome(@CurrentUser() user: AuthUser, @Body() dto: HomeSectionsDto) {
    return this.admin.saveHomeSections(user.id, dto.sections);
  }

  // ------------------------------------------------ admin only
  @Get('users')
  @RequireRole('admin')
  users(@Query() page: PageQuery, @Query('q') q?: string, @Query('role') role?: string) {
    return this.admin.users(page, q?.slice(0, 100), role || undefined);
  }

  @Post('users')
  @RequireRole('admin')
  @ApiCreatedResponse({ type: AdminUserDto })
  createUser(@CurrentUser() user: AuthUser, @Body() dto: CreateUserDto, @Req() req: Request) {
    return this.admin.createUser(user.id, dto, req.ip);
  }

  @Get('users/:id')
  @RequireRole('admin')
  @ApiOkResponse({ type: AdminUserDto })
  user(@Param('id', uuidPipe) id: string) {
    return this.admin.user(id);
  }

  @Patch('users/:id')
  @RequireRole('admin')
  @ApiOkResponse({ type: AdminUserDto })
  updateUser(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Body() dto: UserPatchDto, @Req() req: Request) {
    return this.admin.updateUser(user.id, id, dto, req.ip);
  }

  @Post('users/:id/password')
  @RequireRole('admin')
  @HttpCode(204)
  @ApiNoContentResponse({ description: 'Password set; all of the user\'s sessions were revoked' })
  async setUserPassword(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Body() dto: SetPasswordDto, @Req() req: Request) {
    await this.admin.setUserPassword(user.id, id, dto.password, req.ip);
  }

  @Post('users/:id/send-reset')
  @RequireRole('admin')
  @HttpCode(202)
  async sendUserReset(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Req() req: Request) {
    await this.admin.sendUserReset(user.id, id, req.ip);
  }

  @Delete('users/:id')
  @RequireRole('admin')
  @HttpCode(204)
  @ApiNoContentResponse({ description: 'Account and personal data deleted' })
  async deleteUser(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Req() req: Request) {
    await this.admin.deleteUser(user.id, id, req.ip);
  }

  @Get('audit-logs')
  @RequireRole('admin')
  audit(@Query() page: PageQuery, @Query('action') action?: string, @Query('actor') actor?: string) {
    return this.admin.auditLogs(page, action?.slice(0, 100), actor?.slice(0, 100));
  }

  @Get('system')
  @RequireRole('admin')
  system() {
    return this.admin.system();
  }

  @Get('config')
  @RequireRole('admin')
  configSummary() {
    return this.admin.configSummary();
  }
}
