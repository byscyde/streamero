import { Body, Controller, Delete, Get, HttpCode, Param, Patch, Put, UploadedFile, UseInterceptors } from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { ApiBearerAuth, ApiBody, ApiConsumes, ApiProperty, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { IsBoolean, IsInt, IsObject, IsOptional, IsString, Length, MaxLength, Min } from 'class-validator';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser } from '../common/decorators.js';
import { badRequest } from '../common/errors.js';
import { uuidPipe } from '../common/uuid.js';
import { UsersService } from './users.service.js';

class UpdateProfileDto {
  @ApiPropertyOptional() @IsOptional() @IsString() @Length(1, 80) displayName?: string;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() allowExplicit?: boolean;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() historyEnabled?: boolean;
  @ApiPropertyOptional() @IsOptional() @IsBoolean() personalizationEnabled?: boolean;
}

class PreferencesDto {
  @ApiProperty() @IsObject() preferences: Record<string, unknown>;
  @ApiProperty() @IsInt() @Min(0) baseVersion: number;
}

class DeleteAccountDto {
  @ApiPropertyOptional() @IsOptional() @IsString() @MaxLength(128) password?: string;
}

@ApiTags('account')
@ApiBearerAuth()
@Controller('v1/me')
export class UsersController {
  constructor(private readonly users: UsersService) {}

  @Get()
  me(@CurrentUser() user: AuthUser) {
    return this.users.me(user.id);
  }

  @Patch()
  update(@CurrentUser() user: AuthUser, @Body() dto: UpdateProfileDto) {
    return this.users.update(user.id, dto);
  }

  @Put('preferences')
  preferences(@CurrentUser() user: AuthUser, @Body() dto: PreferencesDto) {
    return this.users.putPreferences(user.id, dto.preferences, dto.baseVersion);
  }

  @Put('avatar')
  @ApiConsumes('multipart/form-data')
  @ApiBody({ schema: { type: 'object', properties: { file: { type: 'string', format: 'binary' } } } })
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 5 * 1024 * 1024, files: 1 } }))
  avatar(@CurrentUser() user: AuthUser, @UploadedFile() file?: { buffer: Buffer }) {
    if (!file) throw badRequest('file_required', 'Upload an image in the "file" field');
    return this.users.setAvatar(user.id, file.buffer);
  }

  @Delete('avatar')
  @HttpCode(204)
  async removeAvatar(@CurrentUser() user: AuthUser) {
    await this.users.removeAvatar(user.id);
  }

  @Get('sessions')
  sessions(@CurrentUser() user: AuthUser) {
    return this.users.sessions(user.id);
  }

  @Delete('sessions/:id')
  @HttpCode(204)
  async revoke(@CurrentUser() user: AuthUser, @Param('id', uuidPipe) id: string) {
    await this.users.revokeSession(user.id, id);
  }

  @Get('export')
  export(@CurrentUser() user: AuthUser) {
    return this.users.export(user.id);
  }

  @Delete()
  @HttpCode(204)
  async remove(@CurrentUser() user: AuthUser, @Body() dto: DeleteAccountDto) {
    await this.users.delete(user.id, dto?.password);
  }
}
