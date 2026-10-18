import { Module } from '@nestjs/common';
import { AuditModule } from './audit/audit.module.js';
import { ConfigModule } from './config/config.module.js';
import { DbModule } from './db/db.module.js';
import { IngestionModule } from './ingestion/ingestion.module.js';
import { MailModule } from './mail/mail.module.js';
import { RedisModule } from './redis/redis.module.js';
import { StorageModule } from './storage/storage.module.js';

/** Infrastructure shared by the API and the worker process. */
@Module({ imports: [ConfigModule, DbModule, RedisModule, StorageModule, AuditModule, MailModule, IngestionModule] })
export class CoreModule {}
