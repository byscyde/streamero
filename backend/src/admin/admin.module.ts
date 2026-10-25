import { Module } from '@nestjs/common';
import { AdminController } from './admin.controller.js';
import { AdminService } from './admin.service.js';
import { MetadataController } from '../metadata/metadata.controller.js';
import { UsersModule } from '../users/users.module.js';

@Module({ imports: [UsersModule], controllers: [AdminController, MetadataController], providers: [AdminService] })
export class AdminModule {}
