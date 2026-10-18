import { Global, Module } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { LocalStorageDriver } from './local.driver.js';
import { S3StorageDriver } from './s3.driver.js';

export const STORAGE = Symbol('STORAGE');

export function createStorage(config: AppConfig) {
  if (config.STORAGE_DRIVER === 's3') {
    return new S3StorageDriver({
      endpoint: config.S3_ENDPOINT,
      region: config.S3_REGION,
      bucket: config.S3_BUCKET,
      accessKeyId: config.S3_ACCESS_KEY_ID!,
      secretAccessKey: config.S3_SECRET_ACCESS_KEY!,
      forcePathStyle: config.S3_FORCE_PATH_STYLE,
    });
  }
  return new LocalStorageDriver(config.STORAGE_LOCAL_ROOT);
}

@Global()
@Module({
  providers: [{ provide: STORAGE, inject: [APP_CONFIG], useFactory: createStorage }],
  exports: [STORAGE],
})
export class StorageModule {}
