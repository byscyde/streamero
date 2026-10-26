import { Body, Controller, HttpCode, Post, Req } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import type { Request } from 'express';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser, Public } from '../common/decorators.js';
import {
  GoogleSignInDto,
  ChangePasswordDto,
  EmailDto,
  LoginDto,
  RefreshDto,
  RegisterDto,
  ResetPasswordDto,
  TokenDto,
} from './auth.dto.js';
import { AuthService } from './auth.service.js';

const STRICT = { default: { limit: 10, ttl: 60_000, blockDuration: 5 * 60_000 } };

@ApiTags('auth')
@Controller('v1/auth')
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Public()
  @Throttle(STRICT)
  @Post('register')
  register(@Body() dto: RegisterDto, @Req() req: Request) {
    return this.auth.register(dto.email, dto.password, dto.displayName, req.headers['user-agent'], req.ip);
  }

  @Public()
  @Throttle(STRICT)
  @Post('login')
  @HttpCode(200)
  login(@Body() dto: LoginDto, @Req() req: Request) {
    return this.auth.login(dto.email, dto.password, dto.deviceName ?? req.headers['user-agent'], req.ip);
  }

  @Public()
  @Throttle({ default: { limit: 30, ttl: 60_000 } })
  @Post('refresh')
  @HttpCode(200)
  refresh(@Body() dto: RefreshDto, @Req() req: Request) {
    return this.auth.refresh(dto.refreshToken, req.headers['user-agent']);
  }

  @Public()
  @Post('logout')
  @HttpCode(204)
  async logout(@Body() dto: RefreshDto) {
    await this.auth.logout(dto.refreshToken);
  }

  @ApiBearerAuth()
  @Post('logout-all')
  @HttpCode(204)
  async logoutAll(@CurrentUser() user: AuthUser) {
    await this.auth.logoutAll(user.id);
  }

  @Public()
  @Throttle(STRICT)
  @Post('verify-email')
  @HttpCode(204)
  async verifyEmail(@Body() dto: TokenDto) {
    await this.auth.verifyEmail(dto.token);
  }

  @ApiBearerAuth()
  @Throttle({ default: { limit: 3, ttl: 15 * 60_000 } })
  @Post('resend-verification')
  @HttpCode(202)
  async resend(@CurrentUser() user: AuthUser) {
    await this.auth.resendVerification(user.id);
    return { status: 'sent' };
  }

  @Public()
  @Throttle({ default: { limit: 5, ttl: 15 * 60_000 } })
  @Post('forgot-password')
  @HttpCode(202)
  async forgot(@Body() dto: EmailDto, @Req() req: Request) {
    await this.auth.forgotPassword(dto.email, req.ip);
    return { status: 'If an account exists for this email, a reset link has been sent.' };
  }

  @Public()
  @Throttle(STRICT)
  @Post('reset-password')
  @HttpCode(204)
  async reset(@Body() dto: ResetPasswordDto, @Req() req: Request) {
    await this.auth.resetPassword(dto.token, dto.password, req.ip);
  }

  @ApiBearerAuth()
  @Throttle(STRICT)
  @Post('change-password')
  @HttpCode(204)
  async changePassword(@CurrentUser() user: AuthUser, @Body() dto: ChangePasswordDto) {
    await this.auth.changePassword(user.id, dto.currentPassword, dto.newPassword);
  }

  @Public()
  @Throttle(STRICT)
  @Post('google')
  @HttpCode(200)
  google(@Body() dto: GoogleSignInDto, @Req() req: Request) {
    return this.auth.signInWithGoogle(dto.idToken, dto.nonce, req.headers['user-agent']);
  }
}
