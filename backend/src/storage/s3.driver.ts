import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import type { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import {
  AbortMultipartUploadCommand,
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  DeleteObjectCommand,
  DeleteObjectsCommand,
  GetObjectCommand,
  HeadBucketCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  S3Client,
  UploadPartCommand,
} from '@aws-sdk/client-s3';
import { Upload } from '@aws-sdk/lib-storage';
import { assertSafeKey, type ByteRange, type StorageDriver } from './storage.driver.js';

export interface S3Options {
  endpoint?: string;
  region: string;
  bucket: string;
  accessKeyId: string;
  secretAccessKey: string;
  forcePathStyle: boolean;
}

export class S3StorageDriver implements StorageDriver {
  readonly name = 's3' as const;
  private readonly s3: S3Client;
  private readonly bucket: string;

  constructor(opts: S3Options) {
    this.bucket = opts.bucket;
    this.s3 = new S3Client({
      endpoint: opts.endpoint || undefined,
      region: opts.region,
      forcePathStyle: opts.forcePathStyle,
      credentials: { accessKeyId: opts.accessKeyId, secretAccessKey: opts.secretAccessKey },
    });
  }

  async putFile(key: string, localPath: string, contentType: string) {
    await new Upload({
      client: this.s3,
      params: { Bucket: this.bucket, Key: assertSafeKey(key), Body: createReadStream(localPath), ContentType: contentType },
      partSize: 16 * 1024 * 1024,
      queueSize: 4,
    }).done();
  }

  async putBuffer(key: string, data: Buffer, contentType: string) {
    await new Upload({ client: this.s3, params: { Bucket: this.bucket, Key: assertSafeKey(key), Body: data, ContentType: contentType } }).done();
  }

  async get(key: string, range?: ByteRange) {
    try {
      const res = await this.s3.send(
        new GetObjectCommand({
          Bucket: this.bucket,
          Key: assertSafeKey(key),
          Range: range ? `bytes=${range.start}-${range.end}` : undefined,
        }),
      );
      const contentLength = Number(res.ContentLength ?? 0);
      let size = contentLength;
      let actual: ByteRange | undefined;
      const m = res.ContentRange?.match(/bytes (\d+)-(\d+)\/(\d+)/);
      if (m) {
        actual = { start: Number(m[1]), end: Number(m[2]) };
        size = Number(m[3]);
      }
      return { stream: res.Body as Readable, size, contentLength, range: actual };
    } catch (err: any) {
      if (err?.name === 'NoSuchKey' || err?.$metadata?.httpStatusCode === 404) return null;
      throw err;
    }
  }

  async stat(key: string) {
    try {
      const res = await this.s3.send(new HeadObjectCommand({ Bucket: this.bucket, Key: assertSafeKey(key) }));
      return { size: Number(res.ContentLength ?? 0) };
    } catch (err: any) {
      if (err?.$metadata?.httpStatusCode === 404 || err?.name === 'NotFound') return null;
      throw err;
    }
  }

  async downloadToFile(key: string, localPath: string) {
    const obj = await this.get(key);
    if (!obj) throw new Error(`Object not found: ${key}`);
    await mkdir(path.dirname(localPath), { recursive: true });
    await pipeline(obj.stream, createWriteStream(localPath));
  }

  async delete(key: string) {
    await this.s3.send(new DeleteObjectCommand({ Bucket: this.bucket, Key: assertSafeKey(key) }));
  }

  private async *list(prefix: string) {
    let token: string | undefined;
    do {
      const res = await this.s3.send(new ListObjectsV2Command({ Bucket: this.bucket, Prefix: prefix, ContinuationToken: token }));
      for (const o of res.Contents ?? []) yield o;
      token = res.IsTruncated ? res.NextContinuationToken : undefined;
    } while (token);
  }

  async deletePrefix(prefix: string) {
    assertSafeKey(prefix);
    let batch: { Key: string }[] = [];
    let count = 0;
    const flush = async () => {
      if (!batch.length) return;
      await this.s3.send(new DeleteObjectsCommand({ Bucket: this.bucket, Delete: { Objects: batch } }));
      count += batch.length;
      batch = [];
    };
    for await (const o of this.list(prefix)) {
      batch.push({ Key: o.Key! });
      if (batch.length === 1000) await flush();
    }
    await flush();
    return count;
  }

  async usage(prefix: string) {
    let bytes = 0;
    let objects = 0;
    for await (const o of this.list(prefix)) {
      bytes += Number(o.Size ?? 0);
      objects++;
    }
    return { bytes, objects };
  }

  async putDirectory(prefix: string, localDir: string, contentTypeFor: (file: string) => string) {
    let bytes = 0;
    let files = 0;
    const walk = async (dir: string) => {
      for (const e of await readdir(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) await walk(p);
        else if (e.isFile()) {
          const rel = path.relative(localDir, p).split(path.sep).join('/');
          await this.putFile(`${prefix.replace(/\/$/, '')}/${rel}`, p, contentTypeFor(p));
          bytes += (await stat(p)).size;
          files++;
        }
      }
    };
    await walk(localDir);
    return { bytes, files };
  }

  async ping() {
    try {
      await this.s3.send(new HeadBucketCommand({ Bucket: this.bucket }));
      return true;
    } catch {
      return false;
    }
  }

  async createMultipart(key: string, contentType: string) {
    const res = await this.s3.send(new CreateMultipartUploadCommand({ Bucket: this.bucket, Key: assertSafeKey(key), ContentType: contentType }));
    return res.UploadId!;
  }

  async uploadPart(key: string, uploadId: string, partNumber: number, data: Buffer) {
    const res = await this.s3.send(
      new UploadPartCommand({ Bucket: this.bucket, Key: assertSafeKey(key), UploadId: uploadId, PartNumber: partNumber, Body: data }),
    );
    return res.ETag!;
  }

  async completeMultipart(key: string, uploadId: string, parts: { partNumber: number; etag: string }[]) {
    await this.s3.send(
      new CompleteMultipartUploadCommand({
        Bucket: this.bucket,
        Key: assertSafeKey(key),
        UploadId: uploadId,
        MultipartUpload: { Parts: [...parts].sort((a, b) => a.partNumber - b.partNumber).map((p) => ({ PartNumber: p.partNumber, ETag: p.etag })) },
      }),
    );
  }

  async abortMultipart(key: string, uploadId: string) {
    await this.s3.send(new AbortMultipartUploadCommand({ Bucket: this.bucket, Key: assertSafeKey(key), UploadId: uploadId }));
  }
}
