import { Global, Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { AuthController } from './auth.controller.js';
import { AuthGuard } from './auth.guard.js';
import { AuthService } from './auth.service.js';
import { TokensService } from './tokens.service.js';

@Global()
@Module({
  controllers: [AuthController],
  providers: [TokensService, AuthService, { provide: APP_GUARD, useClass: AuthGuard }],
  exports: [TokensService, AuthService],
})
export class AuthModule {}
