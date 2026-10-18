import type { Readable } from 'node:stream';

export interface ByteRange {
  start: number;
  end: number; // inclusive
}

export interface ObjectStream {
  stream: Readable;
  size: number;
  contentLength: number;
  range?: ByteRange;
}

export interface StorageDriver {
  readonly name: 'local' | 's3';
  putFile(key: string, localPath: string, contentType: string): Promise<void>;
  putBuffer(key: string, data: Buffer, contentType: string): Promise<void>;
  /** Streams an object, optionally a byte range. Returns null when the object does not exist. */
  get(key: string, range?: ByteRange): Promise<ObjectStream | null>;
  stat(key: string): Promise<{ size: number } | null>;
  downloadToFile(key: string, localPath: string): Promise<void>;
  delete(key: string): Promise<void>;
  deletePrefix(prefix: string): Promise<number>;
  /** Total bytes stored under a prefix. */
  usage(prefix: string): Promise<{ bytes: number; objects: number }>;
  /** Uploads every file under a local directory to `prefix/<relative path>`. */
  putDirectory(prefix: string, localDir: string, contentTypeFor: (file: string) => string): Promise<{ bytes: number; files: number }>;
  ping(): Promise<boolean>;
  /** Multipart uploads let resumable chunked uploads land directly in storage, on any API replica. */
  createMultipart(key: string, contentType: string): Promise<string>;
  uploadPart(key: string, uploadId: string, partNumber: number, data: Buffer): Promise<string>;
  completeMultipart(key: string, uploadId: string, parts: { partNumber: number; etag: string }[]): Promise<void>;
  abortMultipart(key: string, uploadId: string): Promise<void>;
}

const KEY_RE = /^[a-z0-9][a-z0-9_\-./]{0,511}$/i;

/** Rejects keys that could escape the storage root or contain unexpected characters. A trailing "/" (prefix) is allowed. */
export function assertSafeKey(key: string): string {
  const segments = key.replace(/\/$/, '').split('/');
  if (!KEY_RE.test(key) || segments.some((seg) => seg === '' || seg === '.' || seg === '..')) {
    throw new Error(`Unsafe storage key: ${JSON.stringify(key)}`);
  }
  return key;
}

export function contentTypeForFile(file: string): string {
  const ext = file.slice(file.lastIndexOf('.') + 1).toLowerCase();
  return (
    {
      m3u8: 'application/vnd.apple.mpegurl',
      ts: 'video/mp2t',
      m4s: 'video/iso.segment',
      mp4: 'video/mp4',
      m4a: 'audio/mp4',
      aac: 'audio/aac',
      mp3: 'audio/mpeg',
      flac: 'audio/flac',
      wav: 'audio/wav',
      vtt: 'text/vtt',
      srt: 'application/x-subrip',
      jpg: 'image/jpeg',
      jpeg: 'image/jpeg',
      png: 'image/png',
      webp: 'image/webp',
      json: 'application/json',
    } as Record<string, string>
  )[ext] ?? 'application/octet-stream';
}
