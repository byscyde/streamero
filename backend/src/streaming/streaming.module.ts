import { Global, Module } from '@nestjs/common';
import { MediaController, StreamingController } from './streaming.controller.js';
import { StreamingService } from './streaming.service.js';

@Global()
@Module({ controllers: [StreamingController, MediaController], providers: [StreamingService], exports: [StreamingService] })
export class StreamingModule {}
