import { Module } from '@nestjs/common';
import { AppConfigController, AppearanceAdminController } from './appconfig.controller.js';
import { AppConfigService } from './appconfig.service.js';

@Module({ controllers: [AppConfigController, AppearanceAdminController], providers: [AppConfigService], exports: [AppConfigService] })
export class AppConfigModule {}
