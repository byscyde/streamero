import { Global, Module } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { AssetsService } from '../media/assets.service.js';
import { MetadataService } from '../metadata/metadata.service.js';
import { MusicBrainzClient } from '../metadata/musicbrainz.js';
import { JobRunner } from './job-runner.js';
import { INGESTION_QUEUE_TOKEN, JobsService } from './jobs.service.js';
import { MediaProcessor } from './processor.js';
import { BullIngestionQueue } from './queue.js';
import { UploadsService } from './uploads.service.js';

@Global()
@Module({
  providers: [
    { provide: INGESTION_QUEUE_TOKEN, inject: [APP_CONFIG], useFactory: (c: AppConfig) => new BullIngestionQueue(c.REDIS_URL) },
    AssetsService,
    MediaProcessor,
    JobsService,
    UploadsService,
    MusicBrainzClient,
    MetadataService,
    JobRunner,
  ],
  exports: [INGESTION_QUEUE_TOKEN, AssetsService, MediaProcessor, JobsService, UploadsService, MusicBrainzClient, MetadataService, JobRunner],
})
export class IngestionModule {}
