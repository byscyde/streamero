import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsEmail, IsOptional, IsString, Length, Matches, MaxLength } from 'class-validator';

export const PASSWORD_RULE = /^(?=.*[A-Za-z])(?=.*\d).{10,128}$/;
export const PASSWORD_MSG = 'Password must be 10-128 characters and contain letters and digits';

export class RegisterDto {
  @ApiProperty() @IsEmail() @MaxLength(254) email: string;
  @ApiProperty({ minLength: 10 }) @IsString() @Matches(PASSWORD_RULE, { message: PASSWORD_MSG }) password: string;
  @ApiProperty() @IsString() @Length(1, 80) displayName: string;
}

export class LoginDto {
  @ApiProperty() @IsEmail() @MaxLength(254) email: string;
  @ApiProperty() @IsString() @Length(1, 128) password: string;
  @ApiPropertyOptional() @IsOptional() @IsString() @MaxLength(120) deviceName?: string;
}

export class RefreshDto {
  @ApiProperty() @IsString() @Length(20, 200) refreshToken: string;
}

export class TokenDto {
  @ApiProperty() @IsString() @Length(20, 200) token: string;
}

export class EmailDto {
  @ApiProperty() @IsEmail() @MaxLength(254) email: string;
}

export class ResetPasswordDto {
  @ApiProperty() @IsString() @Length(20, 200) token: string;
  @ApiProperty() @IsString() @Matches(PASSWORD_RULE, { message: PASSWORD_MSG }) password: string;
}

export class ChangePasswordDto {
  @ApiProperty() @IsString() @Length(1, 128) currentPassword: string;
  @ApiProperty() @IsString() @Matches(PASSWORD_RULE, { message: PASSWORD_MSG }) newPassword: string;
}

export class AppleSignInDto {
  @ApiProperty({ description: 'identityToken returned by AuthenticationServices' }) @IsString() @Length(20, 8192) identityToken: string;
  @ApiPropertyOptional({ description: 'Raw nonce whose SHA-256 was sent in the Apple request' })
  @IsOptional()
  @IsString()
  @MaxLength(200)
  nonce?: string;
  @ApiPropertyOptional() @IsOptional() @IsString() @Length(1, 80) displayName?: string;
}
