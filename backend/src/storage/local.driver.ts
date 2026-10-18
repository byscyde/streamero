import { createReadStream, createWriteStream } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { copyFile, mkdir, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { assertSafeKey, type ByteRange, type StorageDriver } from './storage.driver.js';

export class LocalStorageDriver implements StorageDriver {
  readonly name = 'local' as const;
  private readonly root: string;

  constructor(root: string) {
    this.root = path.resolve(root);
  }

  /** Resolves a key to an absolute path and verifies it stays inside the root. */
  resolve(key: string): string {
    assertSafeKey(key);
    const full = path.resolve(this.root, key);
    if (full !== this.root && !full.startsWith(this.root + path.sep)) throw new Error('Path escapes storage root');
    return full;
  }

  async putFile(key: string, localPath: string) {
    const dest = this.resolve(key);
    await mkdir(path.dirname(dest), { recursive: true });
    await copyFile(localPath, dest);
  }

  async putBuffer(key: string, data: Buffer) {
    const dest = this.resolve(key);
    await mkdir(path.dirname(dest), { recursive: true });
    await writeFile(dest, data);
  }

  async get(key: string, range?: ByteRange) {
    const file = this.resolve(key);
    const info = await stat(file).catch(() => null);
    if (!info?.isFile()) return null;
    if (range) {
      const end = Math.min(range.end, info.size - 1);
      return {
        stream: createReadStream(file, { start: range.start, end }),
        size: info.size,
        contentLength: end - range.start + 1,
        range: { start: range.start, end },
      };
    }
    return { stream: createReadStream(file), size: info.size, contentLength: info.size };
  }

  async stat(key: string) {
    const info = await stat(this.resolve(key)).catch(() => null);
    return info?.isFile() ? { size: info.size } : null;
  }

  async downloadToFile(key: string, localPath: string) {
    await mkdir(path.dirname(localPath), { recursive: true });
    await copyFile(this.resolve(key), localPath);
  }

  async delete(key: string) {
    await rm(this.resolve(key), { force: true });
  }

  async deletePrefix(prefix: string) {
    const dir = this.resolve(prefix.replace(/\/$/, ''));
    const { objects } = await this.usage(prefix);
    await rm(dir, { recursive: true, force: true });
    return objects;
  }

  async usage(prefix: string) {
    const base = prefix ? this.resolve(prefix.replace(/\/$/, '')) : this.root;
    let bytes = 0;
    let objects = 0;
    const walk = async (dir: string) => {
      const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
      for (const e of entries) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) await walk(p);
        else if (e.isFile()) {
          bytes += (await stat(p)).size;
          objects++;
        }
      }
    };
    const info = await stat(base).catch(() => null);
    if (info?.isFile()) return { bytes: info.size, objects: 1 };
    await walk(base);
    return { bytes, objects };
  }

  async putDirectory(prefix: string, localDir: string) {
    let bytes = 0;
    let files = 0;
    const walk = async (dir: string) => {
      for (const e of await readdir(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) await walk(p);
        else if (e.isFile()) {
          const rel = path.relative(localDir, p).split(path.sep).join('/');
          await this.putFile(`${prefix.replace(/\/$/, '')}/${rel}`, p);
          bytes += (await stat(p)).size;
          files++;
        }
      }
    };
    await walk(localDir);
    return { bytes, files };
  }

  async ping() {
    await mkdir(this.root, { recursive: true });
    return true;
  }

  private partsDir(uploadId: string) {
    if (!/^[0-9a-f-]{36}$/.test(uploadId)) throw new Error('Invalid multipart upload id');
    return path.join(this.root, '.multipart', uploadId);
  }

  async createMultipart(key: string) {
    this.resolve(key);
    const id = randomUUID();
    await mkdir(this.partsDir(id), { recursive: true });
    return id;
  }

  async uploadPart(_key: string, uploadId: string, partNumber: number, data: Buffer) {
    const dir = this.partsDir(uploadId);
    const tmp = path.join(dir, `${partNumber}.tmp-${randomUUID()}`);
    await writeFile(tmp, data);
    await rename(tmp, path.join(dir, `${partNumber}.part`)); // atomic: a re-sent chunk replaces the old one
    return `local-${partNumber}-${data.length}`;
  }

  async completeMultipart(key: string, uploadId: string, parts: { partNumber: number; etag: string }[]) {
    const dest = this.resolve(key);
    await mkdir(path.dirname(dest), { recursive: true });
    const out = createWriteStream(dest);
    try {
      for (const p of [...parts].sort((a, b) => a.partNumber - b.partNumber)) {
        await pipeline(createReadStream(path.join(this.partsDir(uploadId), `${p.partNumber}.part`)), out, { end: false });
      }
    } finally {
      await new Promise<void>((resolve, reject) => out.end((err?: Error | null) => (err ? reject(err) : resolve())));
    }
    await rm(this.partsDir(uploadId), { recursive: true, force: true });
  }

  async abortMultipart(_key: string, uploadId: string) {
    await rm(this.partsDir(uploadId), { recursive: true, force: true });
  }
}
