import { Body, Controller, Delete, Get, HttpCode, Param, Patch, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiProperty, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import {
  ArrayMaxSize,
  IsArray,
  IsBoolean,
  IsEmail,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Length,
  MaxLength,
  Min,
} from 'class-validator';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser, OptionalAuth, Public } from '../common/decorators.js';
import { PageQuery } from '../common/pagination.js';
import { uuidPipe } from '../common/uuid.js';
import { PlaylistsService } from './playlists.service.js';

const VIS = ['private', 'unlisted', 'public'] as const;

class CreatePlaylistDto {
  @ApiProperty() @IsString() @Length(1, 200) title: string;
  @ApiPropertyOptional() @IsOptional() @IsString() @MaxLength(2000) description?: string;
  @ApiPropertyOptional({ enum: VIS }) @IsOptional() @IsIn(VIS) visibility?: (typeof VIS)[number];
  @ApiPropertyOptional() @IsOptional() @IsBoolean() isCollaborative?: boolean;
  @ApiPropertyOptional({ description: 'Editors only: create an editorial playlist' }) @IsOptional() @IsBoolean() editorial?: boolean;
}

class UpdatePlaylistDto {
  @ApiPropertyOptional() @IsOptional() @IsString() @Length(1, 200) title?: string;
  @ApiPropertyOptional() @IsOptional() @IsString() @MaxLength(2000) description?: string;
  @ApiPropertyOptional({ enum: VIS }) @IsOptional() @IsIn(VIS) visibility?: (typeof VIS)[number];
  @ApiPropertyOptional() @IsOptional() @IsBoolean() isCollaborative?: boolean;
  @ApiPropertyOptional() @IsOptional() @IsInt() expectedVersion?: number;
}

class AddItemsDto {
  @ApiPropertyOptional({ type: [String] }) @IsOptional() @IsArray() @ArrayMaxSize(500) @IsUUID('all', { each: true }) trackIds?: string[];
  @ApiPropertyOptional({ type: [String] }) @IsOptional() @IsArray() @ArrayMaxSize(500) @IsUUID('all', { each: true }) videoIds?: string[];
  @ApiPropertyOptional({ description: 'Insert position; defaults to the end' }) @IsOptional() @IsInt() @Min(0) position?: number;
  @ApiPropertyOptional() @IsOptional() @IsInt() expectedVersion?: number;
}

class RemoveItemsDto {
  @ApiProperty({ type: [String] }) @IsArray() @ArrayMaxSize(1000) @IsUUID('all', { each: true }) itemIds: string[];
  @ApiPropertyOptional() @IsOptional() @IsInt() expectedVersion?: number;
}

class MoveItemDto {
  @ApiProperty() @IsUUID() itemId: string;
  @ApiProperty() @IsInt() @Min(0) toIndex: number;
  @ApiPropertyOptional() @IsOptional() @IsInt() expectedVersion?: number;
}

class ReorderDto {
  @ApiProperty({ type: [String] }) @IsArray() @ArrayMaxSize(10000) @IsUUID('all', { each: true }) itemIds: string[];
  @ApiPropertyOptional() @IsOptional() @IsInt() expectedVersion?: number;
}

class CollaboratorDto {
  @ApiProperty() @IsEmail() email: string;
}

@ApiTags('playlists')
@ApiBearerAuth()
@Controller('v1')
export class PlaylistsController {
  constructor(private readonly playlists: PlaylistsService) {}

  @Post('playlists')
  create(@CurrentUser() user: AuthUser, @Body() dto: CreatePlaylistDto) {
    return this.playlists.create(user, dto);
  }

  @Get('playlists/featured')
  featured(@Query() page: PageQuery) {
    return this.playlists.editorial(page);
  }

  @Get('playlists/:id')
  get(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser, @Query() page: PageQuery) {
    return this.playlists.get(id, user, page);
  }

  @Patch('playlists/:id')
  update(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser, @Body() dto: UpdatePlaylistDto) {
    const { expectedVersion, ...input } = dto;
    return this.playlists.update(id, user, input, expectedVersion);
  }

  @Delete('playlists/:id')
  @HttpCode(204)
  async remove(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser) {
    await this.playlists.remove(id, user);
  }

  @Post('playlists/:id/items')
  add(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser, @Body() dto: AddItemsDto) {
    return this.playlists.addItems(id, user, dto.trackIds ?? [], dto.videoIds ?? [], dto.position, dto.expectedVersion);
  }

  @Post('playlists/:id/items/remove')
  @HttpCode(200)
  removeItems(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser, @Body() dto: RemoveItemsDto) {
    return this.playlists.removeItems(id, user, dto.itemIds, dto.expectedVersion);
  }

  @Post('playlists/:id/items/move')
  @HttpCode(200)
  move(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser, @Body() dto: MoveItemDto) {
    return this.playlists.moveItem(id, user, dto.itemId, dto.toIndex, dto.expectedVersion);
  }

  @Post('playlists/:id/items/reorder')
  @HttpCode(200)
  reorder(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser, @Body() dto: ReorderDto) {
    return this.playlists.reorder(id, user, dto.itemIds, dto.expectedVersion);
  }

  @Post('playlists/:id/collaborators')
  collaborator(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser, @Body() dto: CollaboratorDto) {
    return this.playlists.addCollaborator(id, user, dto.email);
  }

  @Delete('playlists/:id/collaborators/:userId')
  @HttpCode(204)
  async removeCollaborator(@Param('id', uuidPipe) id: string, @Param('userId', uuidPipe) userId: string, @CurrentUser() user: AuthUser) {
    await this.playlists.removeCollaborator(id, user, userId);
  }

  /** Share links work without an account for unlisted/public playlists. */
  @Public()
  @OptionalAuth()
  @Get('share/playlists/:token')
  shared(@Param('token') token: string, @CurrentUser() user?: AuthUser) {
    return this.playlists.byShareToken(token.slice(0, 64), user ?? null);
  }
}
