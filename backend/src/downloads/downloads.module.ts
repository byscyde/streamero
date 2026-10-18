import { Body, Controller, Delete, Get, HttpCode, Module, Param, Post } from '@nestjs/common';
import { ApiBearerAuth, ApiProperty, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { ArrayMaxSize, IsArray, IsIn, IsOptional, IsUUID } from 'class-validator';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser } from '../common/decorators.js';
import { badRequest } from '../common/errors.js';
import { uuidPipe } from '../common/uuid.js';
import { STREAM_PROFILES, type StreamProfile } from '../media/profiles.js';
import { DownloadsService } from './downloads.service.js';

class DownloadRequestDto {
  @ApiPropertyOptional() @IsOptional() @IsUUID() trackId?: string;
  @ApiPropertyOptional() @IsOptional() @IsUUID() videoId?: string;
  @ApiPropertyOptional({ enum: STREAM_PROFILES }) @IsOptional() @IsIn(STREAM_PROFILES) profile?: StreamProfile;
}

class ValidateDto {
  @ApiProperty({ type: [String] }) @IsArray() @ArrayMaxSize(5000) @IsUUID('all', { each: true }) grantIds: string[];
}

@ApiTags('downloads')
@ApiBearerAuth()
@Controller('v1/me/downloads')
export class DownloadsController {
  constructor(private readonly downloads: DownloadsService) {}

  @Post()
  request(@CurrentUser() user: AuthUser, @Body() dto: DownloadRequestDto) {
    if (!dto.trackId === !dto.videoId) throw badRequest('invalid_request', 'Provide exactly one of trackId or videoId');
    return dto.trackId
      ? this.downloads.requestTrack(user.id, dto.trackId, dto.profile ?? 'high')
      : this.downloads.requestVideo(user.id, dto.videoId!);
  }

  @Get()
  list(@CurrentUser() user: AuthUser) {
    return this.downloads.list(user.id);
  }

  @Post('validate')
  @HttpCode(200)
  validate(@CurrentUser() user: AuthUser, @Body() dto: ValidateDto) {
    return this.downloads.validate(user.id, dto.grantIds);
  }

  @Delete(':id')
  @HttpCode(204)
  async revoke(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    await this.downloads.revoke(user.id, id);
  }
}

@Module({ controllers: [DownloadsController], providers: [DownloadsService] })
export class DownloadsModule {}
