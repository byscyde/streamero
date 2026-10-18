import { createWriteStream } from 'node:fs';
import { realpath, readdir, stat } from 'node:fs/promises';
import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import path from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { Agent } from 'undici';
import { JobFailure } from './processor.js';

/**
 * Hosts whose media must never be downloaded by the generic importer. YouTube content is only
 * available through the official discovery API and embedded player (see youtube module).
 */
const BLOCKED_HOSTS = [/(^|\.)youtube\.com$/i, /(^|\.)youtu\.be$/i, /(^|\.)googlevideo\.com$/i, /(^|\.)youtube-nocookie\.com$/i, /(^|\.)ytimg\.com$/i];

export const MEDIA_EXTENSIONS = new Set(['.mp3', '.m4a', '.aac', '.flac', '.wav', '.aif', '.aiff', '.alac', '.ogg', '.opus', '.wv', '.ape', '.caf', '.mp4', '.m4v', '.mov', '.mkv', '.webm', '.avi', '.ts']);

export function isPrivateAddress(ip: string): boolean {
  if (ip.startsWith('::ffff:')) return isPrivateAddress(ip.slice(7));
  if (isIP(ip) === 4) {
    const [a, b] = ip.split('.').map(Number);
    return (
      a === 0 || a === 10 || a === 127 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 198 && (b === 18 || b === 19)) || a >= 224
    );
  }
  const l = ip.toLowerCase();
  return l === '::' || l === '::1' || l.startsWith('fc') || l.startsWith('fd') || l.startsWith('fe80') || l.startsWith('ff');
}

export function hostAllowed(host: string, allowlist: string[]): boolean {
  const h = host.toLowerCase().replace(/\.$/, '');
  return allowlist.some((entry) => {
    const e = entry.toLowerCase();
    return e.startsWith('.') ? h.endsWith(e) || h === e.slice(1) : h === e;
  });
}

export interface UrlImportOptions {
  allowedHosts: string[];
  allowPrivateNetworks: boolean;
  maxBytes: number;
  timeoutMs?: number;
}

export function validateImportUrl(raw: string, opts: Pick<UrlImportOptions, 'allowedHosts' | 'allowPrivateNetworks'>): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new JobFailure('Invalid URL');
  }
  if (url.protocol !== 'https:' && !(opts.allowPrivateNetworks && url.protocol === 'http:')) throw new JobFailure('Only https:// URLs can be imported');
  if (url.username || url.password) throw new JobFailure('URLs with embedded credentials are not accepted; configure an authenticated source instead');
  if (BLOCKED_HOSTS.some((re) => re.test(url.hostname))) {
    throw new JobFailure('YouTube media cannot be downloaded. Use the YouTube discovery integration, or import a file you own from another source.');
  }
  if (opts.allowedHosts.length === 0) throw new JobFailure('URL import is disabled: configure IMPORT_ALLOWED_HOSTS');
  if (!hostAllowed(url.hostname, opts.allowedHosts)) throw new JobFailure(`Host ${url.hostname} is not in IMPORT_ALLOWED_HOSTS`);
  return url;
}

/**
 * Downloads an authorised direct-download URL with SSRF protection: allowlisted hosts only, every
 * redirect re-validated, and the resolved IP checked *at connect time* (defeats DNS rebinding).
 */
export async function downloadUrl(raw: string, dest: string, opts: UrlImportOptions, headers: Record<string, string> = {}) {
  const dispatcher = new Agent({
    connect: {
      lookup: (hostname, options, cb) => {
        lookup(hostname, { all: true })
          .then((addrs) => {
            const bad = addrs.find((a) => isPrivateAddress(a.address));
            if (bad && !opts.allowPrivateNetworks) return cb(new Error(`Refusing to connect to private address ${bad.address}`), '', 4);
            const first = addrs[0];
            if ((options as any).all) return (cb as any)(null, addrs);
            cb(null, first.address, first.family);
          })
          .catch((err) => cb(err, '', 4));
      },
    },
  });
  try {
    let url = validateImportUrl(raw, opts);
    for (let hop = 0; hop <= 3; hop++) {
      if (isIP(url.hostname) && isPrivateAddress(url.hostname) && !opts.allowPrivateNetworks) throw new JobFailure('Private addresses are not allowed');
      const res = await fetch(url, {
        redirect: 'manual',
        headers: { 'user-agent': 'STREAMERO-Importer/1.0', ...headers },
        signal: AbortSignal.timeout(opts.timeoutMs ?? 30 * 60_000),
        dispatcher,
      }).catch((err) => {
        throw new JobFailure(`Download failed: ${err.cause?.message ?? err.message}`, false);
      });
      if (res.status >= 300 && res.status < 400) {
        const loc = res.headers.get('location');
        if (!loc) throw new JobFailure('Redirect without location');
        url = validateImportUrl(new URL(loc, url).toString(), opts);
        continue;
      }
      if (!res.ok || !res.body) throw new JobFailure(`Source responded with HTTP ${res.status}`, res.status >= 500);
      const declared = Number(res.headers.get('content-length') ?? 0);
      if (declared > opts.maxBytes) throw new JobFailure(`File exceeds the ${opts.maxBytes} byte limit`);
      let received = 0;
      const body = Readable.fromWeb(res.body as any);
      body.on('data', (chunk: Buffer) => {
        received += chunk.length;
        if (received > opts.maxBytes) body.destroy(new JobFailure(`File exceeds the ${opts.maxBytes} byte limit`));
      });
      await pipeline(body, createWriteStream(dest));
      const disposition = res.headers.get('content-disposition');
      const fromHeader = disposition?.match(/filename\*?=(?:UTF-8'')?"?([^";]+)"?/i)?.[1];
      return {
        finalUrl: url.toString(),
        bytes: received,
        contentType: res.headers.get('content-type'),
        filename: decodeURIComponent(fromHeader ?? path.basename(url.pathname)) || 'download',
      };
    }
    throw new JobFailure('Too many redirects');
  } finally {
    await dispatcher.close().catch(() => undefined);
  }
}

/**
 * Resolves a path under one of IMPORT_ALLOWED_DIRS. Symlinks are resolved first, so a link
 * pointing outside the allowed directory is rejected.
 */
export async function resolveAllowedPath(requested: string, allowedDirs: string[]): Promise<string> {
  if (allowedDirs.length === 0) throw new JobFailure('Server folder import is disabled: configure IMPORT_ALLOWED_DIRS');
  if (!path.isAbsolute(requested)) throw new JobFailure('Path must be absolute');
  const real = await realpath(requested).catch(() => {
    throw new JobFailure('Path does not exist');
  });
  for (const dir of allowedDirs) {
    const root = await realpath(dir).catch(() => null);
    if (root && (real === root || real.startsWith(root + path.sep))) return real;
  }
  throw new JobFailure('Path is outside the allowed import directories');
}

export async function listMediaFiles(dir: string, limit = 5000): Promise<string[]> {
  const out: string[] = [];
  const walk = async (d: string) => {
    for (const e of await readdir(d, { withFileTypes: true })) {
      if (out.length >= limit) return;
      if (e.name.startsWith('.')) continue;
      const p = path.join(d, e.name);
      if (e.isDirectory()) await walk(p);
      else if (e.isFile() && MEDIA_EXTENSIONS.has(path.extname(e.name).toLowerCase())) out.push(p);
    }
  };
  if ((await stat(dir)).isDirectory()) await walk(dir);
  else out.push(dir);
  return out.sort();
}
