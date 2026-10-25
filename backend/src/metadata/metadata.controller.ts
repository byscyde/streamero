import { Body, Controller, Get, HttpCode, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiOkResponse, ApiOperation, ApiProperty, ApiPropertyOptional, ApiQuery, ApiResponse, ApiTags } from '@nestjs/swagger';
import { IsBoolean, IsOptional, IsUUID } from 'class-validator';
import { AdminService } from '../admin/admin.service.js';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser, RequireRole } from '../common/decorators.js';
import { MetadataService } from './metadata.service.js';

class MetadataResultDto {
  @ApiProperty({ description: 'MusicBrainz recording id (MBID)' }) id: string;
  @ApiProperty() title: string;
  @ApiProperty() artist: string;
  @ApiProperty({ nullable: true, type: String }) album: string | null;
  @ApiProperty({ nullable: true, type: String, description: 'MusicBrainz release id' }) albumId: string | null;
  @ApiProperty({ nullable: true, type: Number }) year: number | null;
  @ApiProperty({ nullable: true, type: Number }) durationMs: number | null;
  @ApiProperty({ type: [String] }) genres: string[];
  @ApiProperty({ nullable: true, type: String, description: 'Cover Art Archive front cover (250 px)' }) coverUrl: string | null;
  @ApiProperty({ description: 'MusicBrainz relevance 0..100' }) score: number;
}

class MetadataSearchDto {
  @ApiProperty({ type: [MetadataResultDto] }) items: MetadataResultDto[];
}

class ApplyMetadataDto {
  @ApiProperty() @IsUUID() trackId: string;
  @ApiProperty({ description: 'MusicBrainz recording id' }) @IsUUID() recordingId: string;
  @ApiPropertyOptional({ description: 'MusicBrainz release id (default: best release of the recording)' }) @IsOptional() @IsUUID() releaseId?: string;
  @ApiPropertyOptional({ description: 'Replace existing values (default: only fill empty/placeholder fields and missing artwork)' })
  @IsOptional()
  @IsBoolean()
  overwrite?: boolean;
}

/** Metadata lookup for files you own (MusicBrainz + Cover Art Archive). No audio is downloaded from anywhere. */
@ApiTags('admin')
@ApiBearerAuth()
@RequireRole('editor')
@Controller('v1/admin/metadata')
export class MetadataController {
  constructor(
    private readonly metadata: MetadataService,
    private readonly admin: AdminService,
  ) {}

  @Get('search')
  @ApiOperation({ summary: 'Search MusicBrainz recordings (up to 25). 503 metadata_unavailable when MusicBrainz is unreachable.' })
  @ApiQuery({ name: 'q', description: 'Artist and/or title ("Artist - Title" searches the fields separately)' })
  @ApiOkResponse({ type: MetadataSearchDto })
  @ApiResponse({ status: 503, description: 'MusicBrainz unreachable' })
  async search(@Query('q') q?: string) {
    return { items: await this.metadata.search(String(q ?? '')) };
  }

  @Post('apply')
  @HttpCode(200)
  @ApiOperation({ summary: 'Fill title/artist/album/year/genres/track number from MusicBrainz and store the Cover Art Archive front cover; returns the updated track' })
  async apply(@CurrentUser() user: AuthUser, @Body() dto: ApplyMetadataDto) {
    const applied = await this.metadata.apply(user.id, dto);
    return { ...(await this.admin.track(dto.trackId)), applied };
  }
}
