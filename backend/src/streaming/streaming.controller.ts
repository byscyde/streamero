import { Controller, Get, Inject, Param, Query, Req, Res } from '@nestjs/common';
import { ApiBearerAuth, ApiQuery, ApiTags } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import type { Request, Response } from 'express';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser, Public } from '../common/decorators.js';
import { AppError, notFound, unauthorized } from '../common/errors.js';
import { uuidPipe, UUID_RE } from '../common/uuid.js';
import { STREAM_PROFILES, type StreamProfile } from '../media/profiles.js';
import { STORAGE } from '../storage/storage.module.js';
import { contentTypeForFile, type ByteRange, type StorageDriver } from '../storage/storage.driver.js';
import { withTimestampMap } from '../subtitles/subtitle-format.js';
import type { MediaGrant } from './media-signer.js';
import { StreamingService } from './streaming.service.js';

export function parseRange(header: string | undefined, size: number): ByteRange | 'invalid' | undefined {
  if (!header) return undefined;
  const m = header.match(/^bytes=(\d*)-(\d*)$/);
  if (!m || (m[1] === '' && m[2] === '')) return 'invalid';
  let start: number;
  let end: number;
  if (m[1] === '') {
    const suffix = Number(m[2]);
    if (suffix === 0) return 'invalid';
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(m[1]);
    end = m[2] === '' ? size - 1 : Math.min(Number(m[2]), size - 1);
  }
  if (start >= size || start > end) return 'invalid';
  return { start, end };
}

@ApiTags('streaming')
@ApiBearerAuth()
@Controller('v1')
export class StreamingController {
  constructor(private readonly streaming: StreamingService) {}

  @Get('tracks/:id/stream')
  @ApiQuery({ name: 'profile', required: false, enum: STREAM_PROFILES })
  trackStream(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser, @Query('profile') profile?: string) {
    const p = (STREAM_PROFILES as string[]).includes(profile ?? '') ? (profile as StreamProfile) : 'standard';
    return this.streaming.trackStream(id, user.id, p);
  }

  @Get('videos/:id/stream')
  videoStream(@Param('id', uuidPipe) id: string, @CurrentUser() user: AuthUser) {
    return this.streaming.videoStream(id, user.id);
  }
}

/**
 * Serves media bytes for signed grants. Authentication is the signed, expiring token in the path, so
 * AVPlayer/AirPlay receivers can fetch segments without bearer headers. Storage keys never leave the server.
 */
@ApiTags('streaming')
@Controller('v1/media')
export class MediaController {
  constructor(
    private readonly streaming: StreamingService,
    @Inject(STORAGE) private readonly storage: StorageDriver,
  ) {}

  private grant(token: string): MediaGrant {
    const grant = this.streaming.signer.verify(token);
    if (!grant) throw unauthorized('invalid_media_token', 'Media link is invalid or expired');
    return grant;
  }

  @Public()
  @Throttle({ default: { limit: 2000, ttl: 60_000 } })
  @Get(':token')
  async file(@Param('token') token: string, @Req() req: Request, @Res() res: Response) {
    const grant = this.grant(token);
    if (grant.k.endsWith('/')) throw notFound('Media');
    await this.send(grant.k, grant.t ?? contentTypeForFile(grant.k), req, res);
  }

  @Public()
  @Throttle({ default: { limit: 4000, ttl: 60_000 } })
  @Get(':token/*path')
  async nested(@Param('token') token: string, @Param('path') pathParam: string | string[], @Req() req: Request, @Res() res: Response) {
    const grant = this.grant(token);
    if (!grant.k.endsWith('/')) throw notFound('Media');
    const rel = (Array.isArray(pathParam) ? pathParam.join('/') : pathParam).replace(/^\/+/, '');
    if (!/^[a-zA-Z0-9_\-./]{1,200}$/.test(rel) || rel.split('/').some((s) => s === '..' || s === '.' || s === '')) {
      throw notFound('Media');
    }

    // Virtual subtitle renditions for HLS: subs/<id>.m3u8 and subs/<id>.vtt
    const sub = rel.match(/^subs\/([0-9a-f-]{36})\.(m3u8|vtt)$/);
    if (sub && grant.v && UUID_RE.test(sub[1])) {
      const s = await this.streaming.subtitleForHls(grant.v, sub[1]);
      if (!s) throw notFound('Subtitle');
      res.setHeader('Cache-Control', 'private, max-age=300');
      if (sub[2] === 'm3u8') {
        const seconds = Math.max(1, Math.ceil(s.duration_ms / 1000));
        res.type('application/vnd.apple.mpegurl').send(
          ['#EXTM3U', '#EXT-X-VERSION:3', `#EXT-X-TARGETDURATION:${seconds}`, '#EXT-X-MEDIA-SEQUENCE:0', '#EXT-X-PLAYLIST-TYPE:VOD',
            `#EXTINF:${seconds}.0,`, `${sub[1]}.vtt`, '#EXT-X-ENDLIST', ''].join('\n'),
        );
        return;
      }
      const obj = await this.storage.get(s.storage_key);
      if (!obj) throw notFound('Subtitle');
      const vtt = await streamToString(obj.stream);
      res.type('text/vtt').send(withTimestampMap(vtt, Number(s.hls_meta?.mpegtsStart ?? 126000)));
      return;
    }

    const key = `${grant.k}${rel}`;
    if (rel === 'master.m3u8' && grant.v) {
      const obj = await this.storage.get(key);
      if (!obj) throw notFound('Media');
      const master = await this.streaming.rewriteMaster(await streamToString(obj.stream), grant.v);
      res.setHeader('Cache-Control', 'private, max-age=60');
      res.type('application/vnd.apple.mpegurl').send(master);
      return;
    }
    await this.send(key, contentTypeForFile(key), req, res);
  }

  private async send(key: string, contentType: string, req: Request, res: Response) {
    const info = await this.storage.stat(key);
    if (!info) throw notFound('Media');
    const range = parseRange(req.headers.range, info.size);
    if (range === 'invalid') {
      res.setHeader('Content-Range', `bytes */${info.size}`);
      throw new AppError(416, 'range_not_satisfiable', 'Requested range is not satisfiable');
    }
    const obj = await this.storage.get(key, range);
    if (!obj) throw notFound('Media');
    res.status(range ? 206 : 200);
    res.setHeader('Content-Type', contentType);
    res.setHeader('Accept-Ranges', 'bytes');
    res.setHeader('Content-Length', String(obj.contentLength));
    res.setHeader('Cache-Control', key.endsWith('.m3u8') ? 'private, max-age=60' : 'private, max-age=86400');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    if (range) res.setHeader('Content-Range', `bytes ${range.start}-${range.end}/${info.size}`);
    if (req.method === 'HEAD') {
      obj.stream.destroy();
      res.end();
      return;
    }
    obj.stream.on('error', () => res.destroy());
    req.on('close', () => obj.stream.destroy());
    obj.stream.pipe(res);
  }
}

async function streamToString(stream: NodeJS.ReadableStream): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const c of stream) chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c));
  return Buffer.concat(chunks).toString('utf8');
}
