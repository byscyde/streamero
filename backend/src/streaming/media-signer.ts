import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';

export interface MediaGrant {
  /** Storage key of a single object, or a key prefix ending in "/" granting access to everything below it. */
  k: string;
  /** Expiry, unix seconds. */
  e: number;
  /** Viewer id, for audit/analytics. */
  u?: string;
  /** Video id for HLS grants (enables subtitle playlist injection). */
  v?: string;
  /** Content type hint. */
  t?: string;
}

/**
 * Stateless, expiring media grants sealed with AES-256-GCM: the token is opaque (storage keys and
 * user ids are not readable by clients) and authenticated (any modification fails decryption).
 * Tokens are embedded in the URL path so relative URLs inside HLS playlists inherit them.
 */
export class MediaSigner {
  private readonly key: Buffer;

  constructor(secret: string) {
    this.key = createHash('sha256').update(`streamero-media-v1:${secret}`).digest();
  }

  sign(grant: MediaGrant): string {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    const body = Buffer.concat([cipher.update(JSON.stringify(grant), 'utf8'), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), body]).toString('base64url');
  }

  verify(token: string, now = Date.now()): MediaGrant | null {
    if (token.length < 40 || token.length > 2048 || !/^[A-Za-z0-9_-]+$/.test(token)) return null;
    try {
      const raw = Buffer.from(token, 'base64url');
      const decipher = createDecipheriv('aes-256-gcm', this.key, raw.subarray(0, 12));
      decipher.setAuthTag(raw.subarray(12, 28));
      const json = Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString('utf8');
      const grant = JSON.parse(json) as MediaGrant;
      if (typeof grant.k !== 'string' || typeof grant.e !== 'number' || grant.e * 1000 < now) return null;
      return grant;
    } catch {
      return null;
    }
  }
}
