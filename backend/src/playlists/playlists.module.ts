import { Module } from '@nestjs/common';
import { PlaylistsController } from './playlists.controller.js';
import { PlaylistsService } from './playlists.service.js';

@Module({ controllers: [PlaylistsController], providers: [PlaylistsService], exports: [PlaylistsService] })
export class PlaylistsModule {}
