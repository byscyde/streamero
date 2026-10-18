import { Body, Controller, Delete, Get, HttpCode, Param, Post, Put, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiProperty, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsBoolean,
  IsInt,
  IsISO8601,
  IsObject,
  IsOptional,
  IsString,
  IsUUID,
  Length,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser } from '../common/decorators.js';
import { PageQuery } from '../common/pagination.js';
import { uuidPipe } from '../common/uuid.js';
import { PlaybackService } from './playback.service.js';

class PlaybackEventDto {
  @ApiProperty() @IsString() @Length(8, 100) clientEventId: string;
  @ApiPropertyOptional() @IsOptional() @IsUUID() trackId?: string;
  @ApiPropertyOptional() @IsOptional() @IsUUID() videoId?: string;
  @ApiProperty() @IsISO8601() playedAt: string;
  @ApiProperty() @IsInt() @Min(0) durationPlayedMs: number;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() completed?: boolean;
  @ApiPropertyOptional() @IsOptional() @IsString() @MaxLength(20) contextType?: string;
  @ApiPropertyOptional() @IsOptional() @IsUUID() contextId?: string;
  @ApiPropertyOptional() @IsOptional() @IsString() @MaxLength(100) deviceId?: string;
}

class PlaybackEventsDto {
  @ApiProperty({ type: [PlaybackEventDto] })
  @IsArray()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => PlaybackEventDto)
  events: PlaybackEventDto[];
}

class VideoProgressDto {
  @ApiProperty() @IsInt() @Min(0) positionMs: number;
  @ApiProperty() @IsInt() @Min(0) durationMs: number;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() completed?: boolean;
  @ApiPropertyOptional() @IsOptional() @IsISO8601() updatedAt?: string;
}

class TrackProgressDto {
  @ApiProperty() @IsInt() @Min(0) positionMs: number;
}

class PlaybackStateDto {
  @ApiProperty({ description: 'Opaque client state: queue, index, position, shuffle, repeat' }) @IsObject() state: Record<string, unknown>;
  @ApiProperty({ description: 'Version the client last received (0 when none)' }) @IsInt() @Min(0) baseVersion: number;
  @ApiPropertyOptional() @IsOptional() @IsString() @MaxLength(100) deviceId?: string;
}

@ApiTags('playback')
@ApiBearerAuth()
@Controller('v1/me')
export class PlaybackController {
  constructor(private readonly playback: PlaybackService) {}

  @Post('playback/events')
  @HttpCode(200)
  events(@CurrentUser() user: AuthUser, @Body() dto: PlaybackEventsDto) {
    return this.playback.recordEvents(user.id, dto.events);
  }

  @Get('recently-played')
  recent(@CurrentUser() user: AuthUser, @Query() page: PageQuery) {
    return this.playback.recentTracks(user.id, page);
  }

  @Get('recently-played/contexts')
  contexts(@CurrentUser() user: AuthUser) {
    return this.playback.recentContexts(user.id).then((items) => ({ items }));
  }

  @Get('history')
  history(@CurrentUser() user: AuthUser, @Query() page: PageQuery) {
    return this.playback.history(user.id, page);
  }

  @Delete('history')
  @HttpCode(204)
  async clear(@CurrentUser() user: AuthUser) {
    await this.playback.clearHistory(user.id);
  }

  @Put('progress/videos/:id')
  videoProgress(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Body() dto: VideoProgressDto) {
    return this.playback.saveVideoProgress(user.id, id, dto.positionMs, dto.durationMs, dto.completed, dto.updatedAt);
  }

  @Get('progress/videos')
  continueWatching(@CurrentUser() user: AuthUser) {
    return this.playback.continueWatching(user.id).then((items) => ({ items }));
  }

  @Put('progress/tracks/:id')
  @HttpCode(204)
  async trackProgress(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string, @Body() dto: TrackProgressDto) {
    await this.playback.saveTrackProgress(user.id, id, dto.positionMs);
  }

  @Get('playback-state')
  state(@CurrentUser() user: AuthUser) {
    return this.playback.getState(user.id);
  }

  @Put('playback-state')
  putState(@CurrentUser() user: AuthUser, @Body() dto: PlaybackStateDto) {
    return this.playback.putState(user.id, dto.state, dto.baseVersion, dto.deviceId);
  }
}
