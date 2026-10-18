import { Module } from '@nestjs/common';
import { PlaybackController } from './playback.controller.js';
import { PlaybackService } from './playback.service.js';

@Module({ controllers: [PlaybackController], providers: [PlaybackService], exports: [PlaybackService] })
export class PlaybackModule {}
